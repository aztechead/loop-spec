#!/usr/bin/env python3
"""
loop.py — bounded autonomous agent loop for Claude Code, OpenCode, and Google ADK.
Layer 1 of loop-runner.

A loop is cron plus a decision-maker in the body. This harness is everything wrapped
around the decision so it halts safely: it repeatedly invokes one supported headless
agent protocol, normalizes the response, runs a verifier, measures real progress, and
stops on any guardrail.

Trust anchors, in order of importance:
  1. VERIFIER INTEGRITY — the verify command's inputs (tests, the script itself,
     any --protected paths) are hashed at start; if the agent touches them the loop
     halts immediately with halt_reason=verifier_integrity. A loop that can edit its
     own exam is not verified, it's grading itself.
  2. HARD STOPS — max iterations (the loop's iterate rounds), wall-clock timeout,
     stall detection, and an optional cumulative spend cap (--max-budget-usd).
  3. REAL PROGRESS, not motion — stall counts both "no file changes" AND "verifier
     failing with the same fingerprint", so an agent churning files in circles still
     halts. Pass/fail oscillation (with --judge) halts as verifier_thrash.
  4. FEEDBACK — full verifier output is saved per iteration and its tail is fed into
     the next prompt; fresh mode re-anchors a PROGRESS.md the agent maintains, so
     ralph-style context resets don't mean amnesia.
  5. MACHINE CONTRACT — a stable result.json (halt_reason, iterations, verifier
     state, start/end commit) so supervisors act on *why* the loop stopped, never by
     scraping stdout. Exit 0 only on verified completion.

Use as a CLI (`loop.py "task" --verify ... --config loop.json`) or as a library:
    from loop import LoopConfig, run_loop
    result = run_loop(LoopConfig(task=..., verify=...))
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import time
from dataclasses import dataclass, asdict, field
from pathlib import Path
from typing import Optional

# Halt reasons — the supervisor's policy switch. Keep these stable.
HALT_COMPLETE = "complete"
HALT_MAX_ITER = "max_iterations"
HALT_TIMEOUT = "timeout"
HALT_STALL = "no_progress"
HALT_INTEGRITY = "verifier_integrity"
HALT_THRASH = "verifier_thrash"
HALT_AGENT_ERROR = "agent_error"
HALT_BUDGET = "budget_exhausted"

MIN_TICK_TIMEOUT = 60.0  # minimum per-tick subprocess timeout; tests may lower this

# Values `claude --permission-mode` accepts (verified against the shipped CLI).
# This set is deliberately NOT the Agent SDK's PermissionMode literal: the SDK
# accepts "default" — which the CLI rejects — and has no "manual". Copying a
# permission_mode out of SDK code into a CLI flag is the trap this guards, since
# the CLI's rejection surfaces only as a nonzero exit on every single tick.
CLAUDE_PERMISSION_MODES = ("default", "acceptEdits", "auto", "bypassPermissions",
                           "manual", "dontAsk", "plan")

# The portable selector. `feature.models.<role>` carries it when no operator route
# applies, and every backend must translate it to "pass no --model at all" rather
# than forwarding a model no catalog contains.
INHERIT = "inherit"


def model_args(model, consumable=None, flag="--model"):
    """Model-selection argv for an explicit selector, or [] to inherit.

    `consumable` is the backend's own acceptance test for a value that survived
    the inherit check — opencode, for one, must not forward a Claude alias. It is
    a per-backend rule layered on ONE definition of inheritance, so a new backend
    cannot accidentally re-answer "is this inherit?" a fourth way.

    `flag` is the backend's spelling of the option (ADK names it
    `--default_llm_model`). Inheritance stays one rule; only the spelling moves.
    """
    if not model or model == INHERIT:
        return []
    if consumable is not None and not consumable(model):
        return []
    return [flag, model]


PROGRESS_BANNER = (
    "# Loop progress notes\n\n"
    "Maintained by the agent across iterations. Each iteration: append what you "
    "tried, what the verifier said, what you learned, and the concrete next step. "
    "Keep it terse — this file is your only memory between iterations.\n"
)


# =============================================================================
# Config and result — the public contract
# =============================================================================
@dataclass
class LoopConfig:
    task: str
    task_id: str = ""                 # stable id; decouples state from prompt text edits
    verify: str = ""                  # shell cmd, exit 0 == done. Strongly recommended.
    protected: list = field(default_factory=list)  # paths the agent must not modify
    max_iterations: int = 10
    max_turns: int = 0                  # per claude tick; 0 leaves the CLI default
    timeout_s: int = 3600
    no_progress: int = 3
    verify_timeout_s: int = 600
    mode: str = "fresh"               # fresh: ralph-style anchor reset; continue: --resume
    permission_mode: str = "acceptEdits"
    allowed_tools: str = ""
    model: str = ""
    effort: str = ""                  # low|medium|high|xhigh|max; claude-only
    fallback_model: str = ""          # --fallback-model: on overload / model-unavailable
                                      # the headless tick falls back to this model instead
                                      # of dying — matters for unattended fleet loops
    retry_watchdog: str = ""          # CLAUDE_CODE_RETRY_WATCHDOG for the child: the
                                      # recommended unattended-session retry mechanism
                                      # (CC 2.1.186). Empty = leave the env as inherited.
    max_budget_usd: float = 0.0       # 0 = unbounded. Cumulative spend cap for the
                                      # whole loop: halts budget_exhausted when the
                                      # summed tick cost reaches it, and each tick is
                                      # additionally capped at the REMAINING budget via
                                      # `claude -p --max-budget-usd` so one runaway tick
                                      # cannot overshoot. Iterations and wall clock do
                                      # not bound spend on their own. Judge calls bill
                                      # to the same total. The per-tick cap is a claude
                                      # flag. OpenCode reports cost for cumulative
                                      # enforcement; ADK does not report money, so a
                                      # requested cap is rejected instead of silently
                                      # running unbounded.
    judge: bool = False
    judge_model: str = ""             # empty inherits the selected harness model
    state_dir: str = ""               # default .loop/<task_id>
    commit: bool = False              # scoped git commit per productive iteration
    claude_bin: str = "claude"
    agent_cli: str = ""               # "claude" | "opencode" | "adk" | "codex" | "" (auto: named
                                      # after the binary). Selects the headless protocol:
                                      # claude -p JSON object vs opencode run --format
                                      # json events vs adk run --jsonl events vs
                                      # codex exec --json events.
    adk_agent_dir: str = ""           # ADK dispatches at a mounted agent DIRECTORY, not a
                                      # bare prompt. Written by lib/adk-install.sh and
                                      # passed through LOOP_SPEC_ADK_AGENT_DIR.
    reset: bool = False
    extra_args: list = field(default_factory=list)

    # Per-backend protocol descriptions, used by auto-detection and the
    # transport-conflict message (a new backend adds one entry here).
    KNOWN_CLIS = {
        "claude": "-p --output-format json (single JSON object)",
        "opencode": "run --format json (one event per line)",
        "adk": "run <agent-dir> --jsonl (one event per line)",
        "codex": "exec --json (one event per line)",
    }

    def resolved_agent_cli(self) -> str:
        if self.agent_cli in self.KNOWN_CLIS:
            return self.agent_cli
        name = Path(self.claude_bin).name
        return name if name in self.KNOWN_CLIS else "claude"

    def resolved_agent_bin(self) -> str:
        # A non-claude --agent-cli with claude_bin left at its default means
        # "that harness's own binary" (--agent-cli adk -> `adk`, opencode -> `opencode`).
        cli = self.resolved_agent_cli()
        if cli != "claude" and self.claude_bin == "claude":
            return cli
        return self.claude_bin

    def transport_conflict(self) -> Optional[str]:
        """Detect a binary that is certainly the wrong protocol for the selected
        backend. Without this, `--agent-cli adk --claude-bin /path/to/claude`
        spawns `claude run <dir> --jsonl ...`, which claude rejects — and the loop
        halts agent_error every tick with no hint the two flags fought.
        Returns a human-readable message, or None when consistent."""
        cli = self.resolved_agent_cli()
        name = Path(self.resolved_agent_bin()).name
        if name in self.KNOWN_CLIS and name != cli:
            return (f"--agent-cli {cli} but the binary is `{self.resolved_agent_bin()}`: "
                    f"{name} does not speak {cli}'s {self.KNOWN_CLIS[cli]} protocol. "
                    f"Point --claude-bin at the {cli} binary or drop --agent-cli.")
        return None

    def permission_conflict(self) -> Optional[str]:
        """Detect a permission mode the claude CLI will reject. Without this,
        a typo makes claude exit nonzero on EVERY tick, so the loop burns its
        whole iteration budget on agent_error with nothing naming the real cause.
        Same failure shape as transport_conflict(), same fail-fast treatment.
        Returns a human-readable message, or None when the mode is accepted.

        Only the claude backend is checked: opencode and ADK give special meaning
        to "plan" alone and pass other values through their own surfaces."""
        if self.resolved_agent_cli() != "claude":
            return None
        mode = self.permission_mode
        if mode in CLAUDE_PERMISSION_MODES:
            return None
        return (f"--permission-mode {mode!r} is not accepted by `claude "
                f"--permission-mode` (valid: {', '.join(CLAUDE_PERMISSION_MODES)}).")

    def bounds_conflict(self) -> Optional[str]:
        """Reject limit values whose runtime meaning contradicts the CLI contract."""
        checks = (
            ("max_iterations", self.max_iterations, 1, "positive"),
            ("max_turns", self.max_turns, 0, "non-negative"),
            ("timeout_s", self.timeout_s, 1, "positive"),
            ("no_progress", self.no_progress, 0, "non-negative"),
            ("verify_timeout_s", self.verify_timeout_s, 1, "positive"),
        )
        for name, value, minimum, wording in checks:
            if not isinstance(value, int) or isinstance(value, bool) or value < minimum:
                return f"{name} must be a {wording} integer"
        if (not isinstance(self.max_budget_usd, (int, float))
                or isinstance(self.max_budget_usd, bool)
                or self.max_budget_usd < 0):
            return "max_budget_usd must be a non-negative number"
        if self.resolved_agent_cli() in ("adk", "codex") and self.max_budget_usd > 0:
            return ("max_budget_usd cannot be enforced by the "
                    f"{self.resolved_agent_cli()} backend because it reports "
                    "tokens, not monetary cost; omit the cap or use a backend "
                    "that reports cost")
        return None

    def resolved_task_id(self) -> str:
        if self.task_id:
            return re.sub(r"[^a-z0-9-]+", "-", self.task_id.lower()).strip("-") or "task"
        return "t-" + hashlib.sha256(self.task.encode()).hexdigest()[:10]

    def resolved_state_dir(self) -> Path:
        return Path(self.state_dir) if self.state_dir else Path(".loop") / self.resolved_task_id()


@dataclass
class LoopState:
    task_id: str
    spec_hash: str
    iteration: int = 0
    total_turns: int = 0
    total_cost_usd: Optional[float] = None  # summed claude -p total_cost_usd; None when never reported
    session_id: Optional[str] = None
    start_sha: str = ""
    protected_hash: str = ""
    last_workspace_hash: str = ""
    last_fail_fp: str = ""            # fingerprint of last failing verifier output
    stale_streak: int = 0
    verdicts: list = field(default_factory=list)   # recent True/False verifier verdicts
    started_at: float = field(default_factory=time.time)
    history: list = field(default_factory=list)

    @classmethod
    def load(cls, path: Path, task_id: str, spec_hash: str) -> "LoopState":
        if path.exists():
            try:
                data = json.loads(path.read_text())
            except json.JSONDecodeError:
                data = {}
            if data.get("task_id") == task_id:
                st = cls(**{k: v for k, v in data.items() if k in cls.__dataclass_fields__})
                if st.spec_hash != spec_hash:
                    print("↻ Task text changed since last run; keeping state under the "
                          "same task_id (iteration counts carry over).")
                    st.spec_hash = spec_hash
                return st
        return cls(task_id=task_id, spec_hash=spec_hash)

    def save(self, path: Path) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(asdict(self), indent=2))


# =============================================================================
# Small process helpers
# =============================================================================
def sh(cmd: list[str], timeout: int = 60) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


# Warn-once: prints a warning the first time a given key is seen.
_warned: set = set()

def warn_once(key: str, msg: str) -> None:
    if key not in _warned:
        _warned.add(key)
        print(f"⚠ {msg}")


def git_sha() -> str:
    try:
        r = sh(["git", "rev-parse", "HEAD"])
        if r.returncode != 0:
            warn_once("git_sha", f"git rev-parse failed (rc={r.returncode}); start/end SHA unavailable")
            return ""
        return r.stdout.strip()
    except Exception as e:
        warn_once("git_sha", f"git rev-parse failed ({e}); start/end SHA unavailable")
        return ""


def workspace_hash(ignore_dir: str) -> str:
    """Fingerprint of the git working tree, excluding the loop's own state dir
    (which changes every tick and would otherwise mask real stalls).

    Returns "" when git is unavailable or failing — a falsy value that lets
    `bool(new_hash)` correctly disable file-change stall detection (the documented
    no-git degrade path). Previously a non-git dir returned rc=128 with empty stdout
    which hashed to a non-empty constant, so `files_changed` was permanently False
    instead of correctly disabled."""
    excl = ignore_dir.rstrip("/")
    try:
        r_status = sh(["git", "status", "--porcelain"], 30)
        r_diff = sh(["git", "diff", "HEAD", "--", ".", f":(exclude){excl}/**"], 30)
        if r_status.returncode != 0 or r_diff.returncode != 0:
            warn_once("workspace_hash",
                      f"git unavailable or failing (status rc={r_status.returncode}, "
                      f"diff rc={r_diff.returncode}); file-change stall detection degraded "
                      "— verifier-fingerprint and hard caps still bound the loop")
            return ""
        lines = [ln for ln in r_status.stdout.splitlines() if excl not in ln]
        return hashlib.sha256(("\n".join(lines) + r_diff.stdout).encode()).hexdigest()[:16]
    except Exception as e:
        warn_once("workspace_hash",
                  f"git unavailable or failing ({e}); file-change stall detection degraded "
                  "— verifier-fingerprint and hard caps still bound the loop")
        return ""  # no git: file-change stall detection degrades; other caps still bound


def verifier_fingerprint(output: str) -> str:
    """Fingerprint of a verifier failure, stable across timestamps/durations/line
    numbers: digits are normalized so 'same failure' compares equal across runs."""
    return hashlib.sha256(re.sub(r"\d+", "N", output).encode()).hexdigest()[:12]


# =============================================================================
# Verifier integrity — the loop must not be able to edit its own exam
# =============================================================================
def integrity_targets(cfg: LoopConfig) -> list[Path]:
    """Explicit --protected paths, plus any token in the verify command that exists
    on disk (auto-protects test dirs/scripts referenced by the command)."""
    targets: dict[str, Path] = {}
    for p in cfg.protected:
        targets[str(Path(p))] = Path(p)
    if cfg.verify:
        try:
            tokens = shlex.split(cfg.verify)
        except ValueError:
            tokens = cfg.verify.split()
        for tok in tokens:
            p = Path(tok)
            if p.exists():
                targets[str(p)] = p
    return list(targets.values())


def hash_paths(paths: list[Path], ignore_dir: str) -> str:
    h = hashlib.sha256()
    for root in sorted(paths, key=str):
        files = [root] if root.is_file() else sorted(
            (f for f in root.rglob("*") if f.is_file()), key=str
        ) if root.is_dir() else []
        for f in files:
            sf = str(f)
            if ignore_dir and ignore_dir in sf:
                continue
            h.update(sf.encode())
            try:
                h.update(f.read_bytes())
            except OSError:
                h.update(b"<unreadable>")
    return h.hexdigest()[:16]


# =============================================================================
# Agent invocation (headless) — claude -p, adk run --jsonl, and
# opencode run --format json behind one contract
# =============================================================================
def _spawn_agent(cmd: list, *, bin_label: str, env: Optional[dict],
                 resume: Optional[str], raw_log: Optional[Path],
                 timeout: Optional[float]):
    """Shared transport scaffold for every backend: run the subprocess, persist
    the raw log (+ stderr sidecar), and map spawn/timeout/exit failures onto the
    common error-dict shape. Returns (proc, None) on a zero-exit run, else
    (None, error_dict) — response parsing is the only per-backend part."""
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=timeout)
    except FileNotFoundError:
        return None, {"ok": False, "error": f"`{bin_label}` not found on PATH",
                      "turns": 0, "session_id": resume, "result": ""}
    except subprocess.TimeoutExpired as e:
        if raw_log is not None:
            raw_log.parent.mkdir(parents=True, exist_ok=True)
            raw_log.write_text(e.stdout or "")
        return None, {"ok": False, "error": f"agent tick timed out after {int(timeout)}s",
                      "turns": 0, "session_id": resume, "result": ""}

    if raw_log is not None:  # capture everything: unattended, the only record is what you kept
        raw_log.parent.mkdir(parents=True, exist_ok=True)
        raw_log.write_text(proc.stdout or "")
        if proc.stderr.strip():
            raw_log.with_suffix(".stderr.txt").write_text(proc.stderr)

    if proc.returncode != 0:
        return None, {"ok": False, "error": (proc.stderr.strip() or f"exit {proc.returncode}")[:500],
                      "turns": 0, "session_id": resume,
                      "result": proc.stdout.strip()[:1000]}
    return proc, None


def run_claude(prompt: str, cfg: LoopConfig, *, resume: Optional[str],
               permission_mode: Optional[str] = None, raw_log: Optional[Path] = None,
               timeout: Optional[float] = None,
               budget_usd: Optional[float] = None) -> dict:
    if cfg.resolved_agent_cli() == "adk":
        return run_adk(prompt, cfg, resume=resume, permission_mode=permission_mode,
                       raw_log=raw_log, timeout=timeout)
    if cfg.resolved_agent_cli() == "opencode":
        return run_opencode(prompt, cfg, resume=resume, permission_mode=permission_mode,
                            raw_log=raw_log, timeout=timeout)
    if cfg.resolved_agent_cli() == "codex":
        return run_codex(prompt, cfg, resume=resume, permission_mode=permission_mode,
                         raw_log=raw_log, timeout=timeout)
    cmd = [cfg.claude_bin, "-p", prompt, "--output-format", "json",
           "--permission-mode", permission_mode or cfg.permission_mode]
    if cfg.allowed_tools:
        cmd += ["--allowedTools", cfg.allowed_tools]
    if resume:
        cmd += ["--resume", resume]
    cmd += model_args(cfg.model)
    if cfg.effort:
        cmd += ["--effort", cfg.effort]
    if cfg.fallback_model:
        cmd += ["--fallback-model", cfg.fallback_model]
    if cfg.max_turns > 0:
        cmd += ["--max-turns", str(cfg.max_turns)]
    if budget_usd is not None and budget_usd > 0:
        # --max-budget-usd is print-mode only, which is exactly this call. Caps THIS
        # tick at the loop's remaining budget so a single runaway turn cannot
        # overshoot the cumulative cap enforced in run_loop().
        cmd += ["--max-budget-usd", f"{budget_usd:.6f}"]
    cmd += list(cfg.extra_args)

    env = None
    if cfg.retry_watchdog:
        env = dict(os.environ)
        env["CLAUDE_CODE_RETRY_WATCHDOG"] = cfg.retry_watchdog

    proc, err = _spawn_agent(cmd, bin_label=cfg.claude_bin, env=env, resume=resume,
                             raw_log=raw_log, timeout=timeout)
    if err:
        return err
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return {"ok": False, "error": "non-JSON output from claude",
                "turns": 0, "session_id": resume, "result": proc.stdout.strip()[:1000]}
    cost = data.get("total_cost_usd")
    return {
        "ok": not data.get("is_error", False),
        "error": None if not data.get("is_error", False) else str(data.get("subtype", "agent error")),
        "turns": int(data.get("num_turns") or 0),
        "session_id": data.get("session_id") or resume,
        "result": data.get("result", "") or "",
        # cost accounting: None when the CLI did not report a number (older CLIs,
        # error paths) so callers can distinguish "free" from "unknown".
        "cost_usd": float(cost) if isinstance(cost, (int, float)) else None,
    }


def parse_jsonl(text: str) -> list[dict]:
    """Return JSON objects from a mixed JSONL stream, ignoring other lines."""
    events = []
    for line in text.splitlines():
        try:
            event = json.loads(line.strip())
        except json.JSONDecodeError:
            continue
        if isinstance(event, dict):
            events.append(event)
    return events


def _run_jsonl_agent(cmd: list, *, backend: str, bin_label: str,
                     env: Optional[dict], resume: Optional[str],
                     raw_log: Optional[Path], timeout: Optional[float]):
    """Spawn a JSONL backend and normalize transport and parse failures."""
    proc, err = _spawn_agent(cmd, bin_label=bin_label, env=env, resume=resume,
                             raw_log=raw_log, timeout=timeout)
    if err:
        return [], err
    events = parse_jsonl(proc.stdout or "")
    if not events:
        return [], {"ok": False, "error": f"non-JSON output from {backend}",
                    "turns": 0, "session_id": resume,
                    "result": proc.stdout.strip()[:1000]}
    return events, None


def run_adk(prompt: str, cfg: LoopConfig, *, resume: Optional[str],
            permission_mode: Optional[str] = None, raw_log: Optional[Path] = None,
            timeout: Optional[float] = None) -> dict:
    """Google ADK (https://google.github.io/adk-docs/) headless backend, normalized
    to run_claude's result contract.

    `adk run <agent-dir> "<prompt>" --jsonl` emits one JSON Event per line. Each
    line carries {author, session_id, node_path, id} followed by the rest of the
    event, where assistant text lives at content.parts[].text and token counts at
    usage_metadata. Mapping to the claude -p JSON-object contract:
      - result:     text parts of the LAST event authored by a non-user agent
      - turns:      count of events carrying assistant text (ADK has no turn_end
                    event; one model response per turn is the closest true analogue)
      - session_id: the events' `session_id`; continuation passes it back through
                    ADK's one-shot `--session_id` option
      - cost_usd:   None — ADK reports token usage, not money, and the price
                    depends on a model/provider pairing this process cannot see.
                    None already means "unknown" to callers, never "free".

    ADK dispatches at a mounted agent DIRECTORY rather than a bare prompt, so
    cfg.adk_agent_dir must be set (lib/adk-install.sh writes it and exports
    LOOP_SPEC_ADK_AGENT_DIR). A missing directory is a prerequisite failure, not
    a fallback.

    RESUME: current ADK one-shot runs restore or create the session named by
    `--session_id`. That is distinct from interactive `--resume <file>`, which
    loads an exported session file. Continue mode uses the former.

    Claude-only knobs are ignored here: allowed_tools, fallback_model,
    retry_watchdog, and the per-tick budget cap. ADK-specific flags go through
    extra_args verbatim.
    """
    bin_ = cfg.resolved_agent_bin()
    mode = permission_mode or cfg.permission_mode
    agent_dir = cfg.adk_agent_dir or os.environ.get("LOOP_SPEC_ADK_AGENT_DIR", "")
    if not agent_dir:
        return {"ok": False,
                "error": "adk backend requires --adk-agent-dir or LOOP_SPEC_ADK_AGENT_DIR "
                         "(run: bash lib/adk-install.sh install --project <dir>)",
                "turns": 0, "session_id": resume, "result": ""}
    # Read-only ticks (judge / compiler) select the sibling agent the installer
    # generates with only the read/glob/grep tools attached — the ADK analogue of
    # opencode's loop-spec-readonly agent. Falling back to the writable agent
    # would hand a judge the edit tools it is defined not to have.
    if mode == "plan":
        readonly = Path(agent_dir).parent / (Path(agent_dir).name + "_readonly")
        if not readonly.is_dir():
            return {"ok": False,
                    "error": f"read-only ADK agent {readonly} is not installed "
                             "(re-run: bash lib/adk-install.sh install)",
                    "turns": 0, "session_id": resume, "result": ""}
        agent_dir = str(readonly)
    if not Path(agent_dir).is_dir():
        return {"ok": False, "error": f"ADK agent directory {agent_dir} does not exist",
                "turns": 0, "session_id": resume, "result": ""}

    cmd = [bin_, "run", agent_dir]
    # ADK ids are `gemini-*` natively or `provider/model` through LiteLLM. Claude
    # aliases from feature.models are invalid here; omit them to inherit the
    # model the mounted agent declares.
    cmd += model_args(cfg.model,
                      consumable=lambda m: m.startswith("gemini") or "/" in m,
                      flag="--default_llm_model")
    if resume:
        cmd += ["--session_id", resume]
    cmd += list(cfg.extra_args)
    cmd += [prompt, "--jsonl"]

    env = dict(os.environ)
    env["LOOP_SPEC_NON_INTERACTIVE"] = "1"
    events, err = _run_jsonl_agent(cmd, backend="adk", bin_label=bin_, env=env,
                                   resume=resume, raw_log=raw_log, timeout=timeout)
    if err:
        return err

    session_id = resume
    v = events[0].get("session_id")
    if isinstance(v, str) and v:
        session_id = v

    def event_text(ev: dict) -> str:
        content = ev.get("content") or {}
        parts = content.get("parts")
        if not isinstance(parts, list):
            return ""
        texts = [p.get("text", "") for p in parts
                 if isinstance(p, dict) and isinstance(p.get("text"), str)]
        return "\n".join(t for t in texts if t)

    turns = 0
    result_text = ""
    error_msg: Optional[str] = None
    for ev in events:
        if ev.get("author") == "user":
            continue
        code = ev.get("error_code")
        if code:
            error_msg = str(ev.get("error_message") or code)[:500]
        text = event_text(ev)
        if text.strip():
            turns += 1
            result_text = text

    if error_msg and not result_text:
        return {"ok": False, "error": error_msg,
                "turns": turns, "session_id": session_id, "result": ""}
    if not result_text:
        return {"ok": False, "error": "no assistant text in adk output",
                "turns": turns, "session_id": session_id, "result": ""}
    return {"ok": True, "error": None, "turns": turns,
            "session_id": session_id, "result": result_text, "cost_usd": None}


def run_opencode(prompt: str, cfg: LoopConfig, *, resume: Optional[str],
                 permission_mode: Optional[str] = None, raw_log: Optional[Path] = None,
                 timeout: Optional[float] = None) -> dict:
    """opencode (https://opencode.ai) headless backend, normalized to
    run_claude's result contract.

    `opencode run --format json "<prompt>"` emits one JSON event per line,
    every event carrying {type, timestamp, sessionID} (the run command's
    `emit()`); the types this parser consumes are `text` (a message part —
    the LAST one is the result), `step_finish` (an assistant step; its part
    carries `cost` and `tokens` per the SDK's StepFinishPart), and `error`.
    Mapping to the claude -p JSON-object contract:
      - result:     part.text of the last `text` event
      - turns:      count of `step_finish` events
      - session_id: `sessionID` of the first event; resume passes --session <id>
      - cost_usd:   summed step_finish part.cost, else None (callers already
                    treat None as "unknown", not "free")
      - permission_mode "plan" (read-only judge / compiler) selects the
        installer-provided loop-spec-readonly agent, which denies every tool
        except read/glob/grep. Work ticks do not pass --auto: ordinary in-tree
        edits remain allowed by the build agent, while permission asks fail
        closed instead of approving external-directory or other sensitive work.
      - claude-only knobs are ignored here: allowed_tools, fallback_model,
        retry_watchdog. Models must be OpenCode ids (`provider/model`).
        OpenCode-specific flags go through
        extra_args verbatim.
    """
    bin_ = cfg.resolved_agent_bin()
    mode = permission_mode or cfg.permission_mode
    if mode == "plan":
        try:
            probe = subprocess.run(
                [bin_, "debug", "agent", "loop-spec-readonly"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
                timeout=30,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            return {"ok": False,
                    "error": f"cannot validate required loop-spec-readonly agent: {exc}",
                    "turns": 0, "session_id": resume, "result": ""}
        if probe.returncode != 0:
            detail = (probe.stderr or "").strip()
            suffix = f": {detail[:500]}" if detail else ""
            return {"ok": False,
                    "error": "required OpenCode agent loop-spec-readonly is not installed" + suffix,
                    "turns": 0, "session_id": resume, "result": ""}
    cmd = [bin_, "run", "--format", "json"]
    if resume:
        cmd += ["--session", str(resume)]
    # OpenCode IDs are provider/model. Claude aliases from feature.models are
    # invalid here; omit them to inherit the configured session/default model.
    cmd += model_args(cfg.model, consumable=lambda m: "/" in m)
    if mode == "plan":
        cmd += ["--agent", "loop-spec-readonly"]
    cmd += list(cfg.extra_args)
    cmd += [prompt]

    events, err = _run_jsonl_agent(cmd, backend="opencode", bin_label=bin_, env=None,
                                   resume=resume, raw_log=raw_log, timeout=timeout)
    if err:
        return err

    session_id = resume
    v = events[0].get("sessionID")
    if isinstance(v, str) and v:
        session_id = v

    turns = sum(1 for ev in events if ev.get("type") == "step_finish")

    result_text = ""
    cost: Optional[float] = None
    error_msg: Optional[str] = None
    for ev in events:
        etype = ev.get("type")
        part = ev.get("part") or {}
        if etype == "text":
            t = part.get("text")
            if isinstance(t, str) and t.strip():
                result_text = t
        elif etype == "step_finish":
            c = part.get("cost")
            if isinstance(c, (int, float)):
                cost = (cost or 0.0) + float(c)
        elif etype == "error":
            e = ev.get("error")
            error_msg = e if isinstance(e, str) else json.dumps(e)[:500]

    if error_msg and not result_text:
        return {"ok": False, "error": error_msg,
                "turns": turns, "session_id": session_id, "result": ""}
    if not result_text:
        return {"ok": False, "error": "no assistant text in opencode output",
                "turns": turns, "session_id": session_id, "result": ""}
    return {"ok": True, "error": None, "turns": turns,
            "session_id": session_id, "result": result_text, "cost_usd": cost}


def run_codex(prompt: str, cfg: LoopConfig, *, resume: Optional[str],
              permission_mode: Optional[str] = None, raw_log: Optional[Path] = None,
              timeout: Optional[float] = None) -> dict:
    """Codex (https://developers.openai.com/codex/noninteractive) headless
    backend, normalized to run_claude's result contract.

    `codex exec --json "<prompt>"` emits one JSON event per line. Documented
    types include thread.started, turn.started, turn.completed, turn.failed,
    item.*, and error. Mapping to the claude -p JSON-object contract:
      - result:     text of the last agent_message / item with assistant text
      - turns:      count of turn.completed events (else item completions)
      - session_id: thread_id from thread.started; resume is
                    `codex exec resume <id> --json`
      - cost_usd:   None — the JSONL stream reports tokens, not money
      - permission_mode "plan" (read-only judge / compiler) selects
        `--sandbox read-only`. Work ticks use `--sandbox workspace-write`
        and never `--dangerously-bypass-approvals-and-sandbox`.
      - claude-only knobs are ignored here: allowed_tools, fallback_model,
        retry_watchdog. Models must be Codex slugs. Codex-specific flags go
        through extra_args verbatim.
    """
    bin_ = cfg.resolved_agent_bin()
    mode = permission_mode or cfg.permission_mode
    sandbox = "read-only" if mode == "plan" else "workspace-write"
    cmd = [bin_, "exec", "--json", "--sandbox", sandbox]
    if resume:
        cmd += ["resume", str(resume)]
    claude_aliases = {"sonnet", "opus", "haiku", "fable"}
    cmd += model_args(cfg.model, consumable=lambda m: m not in claude_aliases)
    cmd += list(cfg.extra_args)
    cmd += [prompt]

    env = dict(os.environ)
    env["LOOP_SPEC_NON_INTERACTIVE"] = "1"
    events, err = _run_jsonl_agent(cmd, backend="codex", bin_label=bin_, env=env,
                                   resume=resume, raw_log=raw_log, timeout=timeout)
    if err:
        return err

    session_id = resume
    turns = 0
    result_text = ""
    error_msg: Optional[str] = None

    def take_text(value) -> str:
        if isinstance(value, str) and value.strip():
            return value
        if isinstance(value, dict):
            for key in ("text", "message", "content"):
                got = take_text(value.get(key))
                if got:
                    return got
            parts = value.get("parts")
            if isinstance(parts, list):
                bits = [take_text(p) for p in parts]
                return "\n".join(b for b in bits if b)
        return ""

    for ev in events:
        etype = ev.get("type") or ev.get("event") or ""
        thread = ev.get("thread_id") or (ev.get("thread") or {}).get("id")
        if isinstance(thread, str) and thread:
            session_id = thread
        if etype in ("turn.completed", "turn_completed"):
            turns += 1
        if etype in ("turn.failed", "turn_failed", "error"):
            err_obj = ev.get("error") or ev.get("message") or ev
            error_msg = take_text(err_obj) or str(err_obj)[:500]
        item = ev.get("item") if isinstance(ev.get("item"), dict) else ev
        item_type = item.get("type") if isinstance(item, dict) else ""
        if item_type in ("agent_message", "agent-message", "message") or etype in (
            "item.completed", "item_completed", "agent.message",
        ):
            text = take_text(item) or take_text(ev.get("text"))
            if text.strip():
                result_text = text
                if etype not in ("turn.completed", "turn_completed") and item_type:
                    turns = max(turns, 1)

    if error_msg and not result_text:
        return {"ok": False, "error": error_msg,
                "turns": turns, "session_id": session_id, "result": ""}
    if not result_text:
        return {"ok": False, "error": "no assistant text in codex output",
                "turns": turns, "session_id": session_id, "result": ""}
    return {"ok": True, "error": None, "turns": turns,
            "session_id": session_id, "result": result_text, "cost_usd": None}


def run_verifier(cmd: str, timeout: int, out_file: Path) -> tuple[bool, str]:
    """Exit 0 == done. Full output saved to disk; the (informative) tail is what gets
    fed back into the next prompt — this feedback is what makes the loop converge."""
    try:
        proc = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        output = (proc.stdout + "\n" + proc.stderr).strip()
        ok = proc.returncode == 0
    except subprocess.TimeoutExpired:
        output, ok = f"[verifier timed out after {timeout}s]", False
    out_file.parent.mkdir(parents=True, exist_ok=True)
    out_file.write_text(output)
    return ok, output


def judge_done(cfg: LoopConfig, verifier_output: str, start_sha: str, *,
               budget_usd: Optional[float] = None) -> tuple[bool, Optional[float]]:
    """Optional cheap second opinion AFTER the verifier passes. The judge sees the
    actual diff of the work, not just the verifier's say-so — otherwise it is
    rubber-stamping the verifier rather than validating the work.

    Returns (done, cost_usd). The cost is reported rather than swallowed so the
    caller can bill it to the loop's cumulative spend: a judge call is a real
    priced invocation, and a total that silently omits it is wrong."""
    diff_stat = diff_full = ""
    if start_sha:
        try:
            r_stat = sh(["git", "diff", "--stat", start_sha], 60)
            r_full = sh(["git", "diff", start_sha], 120)
            if r_stat.returncode != 0 or r_full.returncode != 0:
                print(f"⚠ judge: git diff unavailable (stat rc={r_stat.returncode}, "
                      f"diff rc={r_full.returncode}); judging on verifier output only")
            else:
                diff_stat = r_stat.stdout[-1500:]
                diff_full = r_full.stdout[-6000:]
        except Exception as e:
            print(f"⚠ judge: git diff unavailable ({e}); judging on verifier output only")
    prompt = (
        "You are a strict completion validator. Answer with a single word: DONE or NOT_DONE.\n\n"
        f"Task:\n{cfg.task}\n\nVerifier output (it passed):\n{verifier_output[-2000:]}\n\n"
        f"Diff stat since loop start:\n{diff_stat}\n\nDiff (tail):\n{diff_full}\n\n"
        "Answer DONE only if the diff plausibly fulfils the task as stated, not merely "
        "if the verifier passed."
    )
    jcfg = LoopConfig(task="", claude_bin=cfg.claude_bin, agent_cli=cfg.agent_cli,
                      model=cfg.judge_model, allowed_tools="",
                      adk_agent_dir=cfg.adk_agent_dir)
    res = run_claude(prompt, jcfg, resume=None, permission_mode="plan", timeout=600,
                     budget_usd=budget_usd)
    cost = res.get("cost_usd")
    if not res["ok"]:
        print(f"⚠ judge run failed ({res['error']}); treating as NOT_DONE")
        return False, cost
    up = res["result"].upper()
    return ("DONE" in up and "NOT_DONE" not in up), cost


def git_commit_scoped(message: str, ignore_dir: str) -> str:
    """Commit the agent's work, never the loop's own state (or anything under it).

    Returns:
        "committed" — a new commit was created.
        "nothing"   — nothing to commit (clean tree after add).
        "failed"    — add or commit failed; warning printed (non-fatal — the loop
                      continues; durability is best-effort, never crash on a commit).
    """
    try:
        r_add = sh(["git", "add", "-A", "--", ".", f":(exclude){ignore_dir}/**",
                    f":(exclude){ignore_dir}"], 60)
        if r_add.returncode != 0:
            detail = (r_add.stderr.strip().splitlines() or ["(no stderr)"])[0]
            print(f"⚠ commit failed (non-fatal): git add rc={r_add.returncode}: {detail}")
            return "failed"
        r_commit = sh(["git", "commit", "-m", message, "--no-verify"], 60)
        if r_commit.returncode != 0:
            out = (r_commit.stdout + r_commit.stderr).strip()
            if "nothing to commit" in out:
                return "nothing"
            detail = (r_commit.stderr.strip().splitlines() or
                      r_commit.stdout.strip().splitlines() or ["(no output)"])[0]
            print(f"⚠ commit failed (non-fatal): {detail}")
            return "failed"
        return "committed"
    except Exception as e:
        print(f"⚠ commit failed (non-fatal): {e}")
        return "failed"


# =============================================================================
# The loop
# =============================================================================
def run_loop(cfg: LoopConfig) -> dict:
    conflict = cfg.transport_conflict()
    if conflict:  # CLI paths catch this in build_config; guard library callers too
        raise ValueError(f"loop.py transport conflict: {conflict}")
    bad_mode = cfg.permission_conflict()
    if bad_mode:
        raise ValueError(f"loop.py permission mode: {bad_mode}")
    task_id = cfg.resolved_task_id()
    state_dir = cfg.resolved_state_dir()
    state_path = state_dir / "state.json"
    progress_path = state_dir / "PROGRESS.md"
    spec_hash = hashlib.sha256(cfg.task.encode()).hexdigest()[:16]

    if cfg.reset and state_dir.exists():
        for f in sorted(state_dir.rglob("*"), reverse=True):
            f.unlink() if f.is_file() else f.rmdir()

    state = LoopState.load(state_path, task_id, spec_hash)
    if state.iteration:
        print(f"↻ Resuming '{task_id}' from iteration {state.iteration}. "
              f"Raise --max-iterations to extend a halted run; --reset to start clean.")

    if not cfg.verify:
        print("⚠  No --verify command. The loop cannot detect completion or verifier-"
              "level stalls; it will run to --max-iterations/--timeout. "
              "Feedback is what makes a loop trustworthy — add one if at all possible.")

    state_dir.mkdir(parents=True, exist_ok=True)
    if not progress_path.exists():
        progress_path.write_text(PROGRESS_BANNER)

    ignore_dir = str(state_dir.parts[0]) if state_dir.parts else ".loop"
    targets = integrity_targets(cfg)
    if targets and not state.protected_hash:
        state.protected_hash = hash_paths(targets, ignore_dir)
        print(f"🔒 Verifier integrity locked over {len(targets)} path(s): "
              + ", ".join(str(t) for t in targets[:6])
              + ("…" if len(targets) > 6 else ""))
    if not state.start_sha:
        state.start_sha = git_sha()
    if not state.last_workspace_hash:
        state.last_workspace_hash = workspace_hash(ignore_dir)

    status = "running"

    while True:
        # --- Hard stops, checked before each tick -----------------------------
        if state.iteration >= cfg.max_iterations:
            status = HALT_MAX_ITER; break
        if time.time() - state.started_at >= cfg.timeout_s:
            status = HALT_TIMEOUT; break
        if cfg.no_progress and state.stale_streak >= cfg.no_progress:
            status = HALT_STALL; break
        # Spend is its own axis: a loop can stay well inside its iteration and
        # wall-clock caps and still run up an unbounded bill unattended.
        if cfg.max_budget_usd > 0 and (state.total_cost_usd or 0.0) >= cfg.max_budget_usd:
            status = HALT_BUDGET; break
        # Thrash: pass→fail flapping (possible when a judge sends passes back to work)
        if len(state.verdicts) >= 4 and sum(
                1 for a, b in zip(state.verdicts, state.verdicts[1:]) if a and not b) >= 2:
            status = HALT_THRASH; break

        state.iteration += 1
        elapsed = time.time() - state.started_at
        print(f"\n── {task_id} · iter {state.iteration}/{cfg.max_iterations} "
              f"· {elapsed:.0f}s ──")

        # --- Build the prompt -------------------------------------------------
        last = state.history[-1] if state.history else {}
        last_verifier = last.get("verifier_tail", "")
        progress_notes = progress_path.read_text()[-4000:]
        protected_note = (
            "\nDo NOT modify these protected paths (the loop verifies their integrity "
            "and will halt the run if they change): "
            + ", ".join(str(t) for t in targets) + "\n") if targets else ""

        if cfg.mode == "fresh" or not state.session_id:
            prompt = (
                f"{cfg.task}\n{protected_note}\n"
                f"--- Your progress notes from previous iterations ({progress_path}) ---\n"
                f"{progress_notes}\n"
                f"--- Latest verifier output (`{cfg.verify or 'none configured'}`) ---\n"
                f"{last_verifier or '(not yet run)'}\n\n"
                f"Work toward completion now. Before finishing this turn, update "
                f"{progress_path} with what you did, what you learned, and the next step."
            )
            resume = None
        else:
            prompt = (
                f"Keep going until the task is complete and the verifier passes."
                f"{protected_note}\n--- Latest verifier output ---\n"
                f"{last_verifier or '(not yet run)'}\n\n"
                f"Update {progress_path} with progress notes before finishing this turn."
            )
            resume = state.session_id

        # --- Invoke the agent --------------------------------------------------
        budget_left = (cfg.max_budget_usd - (state.total_cost_usd or 0.0)
                       if cfg.max_budget_usd > 0 else None)
        res = run_claude(prompt, cfg, resume=resume,
                         raw_log=state_dir / f"iter-{state.iteration:03d}.raw.json",
                         timeout=max(MIN_TICK_TIMEOUT, cfg.timeout_s - (time.time() - state.started_at)),
                         budget_usd=budget_left)
        state.total_turns += res["turns"]
        if res.get("cost_usd") is not None:
            state.total_cost_usd = (state.total_cost_usd or 0.0) + res["cost_usd"]
        if res["session_id"]:
            state.session_id = res["session_id"]
        if not res["ok"]:
            print(f"   agent run failed: {res['error']}")

        # --- Verifier integrity BEFORE trusting any verdict ---------------------
        if targets:
            now_hash = hash_paths(targets, ignore_dir)
            if now_hash != state.protected_hash:
                state.history.append({"iteration": state.iteration,
                                      "agent_ok": res["ok"], "event": "integrity_violation"})
                state.save(state_path)
                print("⛔ Protected paths were modified — the verifier can no longer be "
                      "trusted. Halting. Inspect the diff; nothing here counts as verified.")
                status = HALT_INTEGRITY
                break

        # --- Verify -------------------------------------------------------------
        verified, verifier_output = False, ""
        if cfg.verify:
            verified, verifier_output = run_verifier(
                cfg.verify, cfg.verify_timeout_s,
                state_dir / f"verifier-{state.iteration:03d}.txt")
            print(f"   verifier: {'PASS' if verified else 'fail'}")
        state.verdicts = (state.verdicts + [verified])[-8:]

        # --- Progress: file changes OR a different verifier failure --------------
        new_hash = workspace_hash(ignore_dir)
        files_changed = bool(new_hash) and new_hash != state.last_workspace_hash
        state.last_workspace_hash = new_hash
        fail_fp = "" if verified or not cfg.verify else verifier_fingerprint(verifier_output)
        verifier_moved = bool(cfg.verify) and not verified and fail_fp != state.last_fail_fp
        if not verified and fail_fp:
            state.last_fail_fp = fail_fp
        made_progress = verified or files_changed or verifier_moved
        state.stale_streak = 0 if made_progress else state.stale_streak + 1
        if not made_progress:
            print(f"   no progress ({state.stale_streak}/{cfg.no_progress}): "
                  f"no file changes and the same verifier failure")

        state.history.append({
            "iteration": state.iteration,
            "turns": res["turns"],
            "agent_ok": res["ok"],
            "agent_summary": res["result"][:600],
            "verified": verified,
            "files_changed": files_changed,
            "fail_fingerprint": fail_fp,
            "verifier_tail": verifier_output[-2500:],
        })
        state.save(state_path)
        if cfg.commit and files_changed:
            commit_status = git_commit_scoped(
                f"loop({task_id}): iteration {state.iteration} [autonomous]", ignore_dir)
            if commit_status == "failed":
                state.history[-1]["commit_failed"] = True
                state.save(state_path)

        # --- Completion ----------------------------------------------------------
        if verified:
            judge_ok = True
            if cfg.judge:
                judge_budget = None
                if cfg.max_budget_usd > 0:
                    judge_budget = cfg.max_budget_usd - (state.total_cost_usd or 0.0)
                    if judge_budget <= 0:
                        # With --judge on, "verified" means verifier AND judge. We
                        # cannot afford the second half, so completion is unproven —
                        # halt on budget rather than claim a completion we did not
                        # validate. verifier.passed is still recorded in the result.
                        print("   verifier passed but no budget left for the judge "
                              "— halting; completion is unvalidated.")
                        status = HALT_BUDGET
                        break
                judge_ok, judge_cost = judge_done(cfg, verifier_output, state.start_sha,
                                                  budget_usd=judge_budget)
                if judge_cost is not None:
                    state.total_cost_usd = (state.total_cost_usd or 0.0) + judge_cost
                    state.save(state_path)
            if judge_ok:
                status = HALT_COMPLETE
                break
            print("   verifier passed but judge said NOT_DONE — continuing.")

    # -------------------------------------------------------------------------
    # Machine-readable result — the supervisor contract
    # -------------------------------------------------------------------------
    elapsed = time.time() - state.started_at
    last = state.history[-1] if state.history else {}
    result = {
        "task_id": task_id,
        "status": "complete" if status == HALT_COMPLETE else "halted",
        "halt_reason": status,
        "iterations": state.iteration,
        "total_turns": state.total_turns,
        "max_turns_per_tick": cfg.max_turns or None,
        "effort": cfg.effort or None,
        "total_cost_usd": round(state.total_cost_usd, 6) if state.total_cost_usd is not None else None,
        "max_budget_usd": cfg.max_budget_usd or None,
        "wall_clock_seconds": round(elapsed, 1),
        "verifier": {
            "command": cfg.verify or None,
            "passed": bool(last.get("verified", False)),
            "last_output_file": str(state_dir / f"verifier-{state.iteration:03d}.txt")
                                if cfg.verify and state.iteration else None,
            "last_fail_fingerprint": state.last_fail_fp or None,
            "integrity_targets": [str(t) for t in targets],
        },
        "start_sha": state.start_sha or None,
        "end_sha": git_sha() or None,
        "session_id": state.session_id,
        "state_dir": str(state_dir),
        "progress_notes": str(progress_path),
    }
    (state_dir / "result.json").write_text(json.dumps(result, indent=2))
    state.save(state_path)

    print("\n" + "=" * 62)
    print(f"  {status.upper()}  ({result['status']})")
    print(f"  iterations : {state.iteration}   turns: {state.total_turns}")
    print(f"  wall clock : {elapsed:.0f}s of {cfg.timeout_s}s")
    print(f"  result     : {state_dir / 'result.json'}")
    print("=" * 62)
    return result


# =============================================================================
# CLI
# =============================================================================
def build_config(argv: Optional[list[str]] = None) -> LoopConfig:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    src = p.add_mutually_exclusive_group()
    src.add_argument("task", nargs="?", help="Task prompt for the agent.")
    src.add_argument("--prompt-file", help="Read the prompt from a file (anchor file).")
    p.add_argument("--config", help="JSON file of LoopConfig fields; CLI flags override.")
    p.add_argument("--task-id", default=None)
    p.add_argument("--verify", default=None)
    p.add_argument("--protected", action="append", default=None,
                   help="Path the agent must not modify (repeatable). Tokens in the "
                        "verify command that exist on disk are auto-protected too.")
    p.add_argument("--max-iterations", type=int, default=None)
    p.add_argument("--max-turns", type=int, default=None,
                   help="maximum agentic turns in each claude tick (0/unset = CLI default)")
    p.add_argument("--timeout", type=int, default=None, dest="timeout_s")
    p.add_argument("--no-progress", type=int, default=None)
    p.add_argument("--verify-timeout", type=int, default=None, dest="verify_timeout_s")
    p.add_argument("--mode", choices=["fresh", "continue"], default=None)
    p.add_argument("--permission-mode", default=None,
                   help="claude: one of " + "|".join(CLAUDE_PERMISSION_MODES))
    p.add_argument("--max-budget-usd", type=float, default=None, dest="max_budget_usd",
                   help="cumulative USD cap for the whole loop; halts "
                        "budget_exhausted and caps each tick at what is left "
                        "(0/unset = unbounded)")
    p.add_argument("--allowed-tools", default=None)
    p.add_argument("--model", default=None)
    p.add_argument("--effort", choices=["low", "medium", "high", "xhigh", "max"],
                   default=None)
    p.add_argument("--fallback-model", default=None, dest="fallback_model")
    p.add_argument("--retry-watchdog", default=None, dest="retry_watchdog")
    p.add_argument("--judge", action="store_true", default=None)
    p.add_argument("--judge-model", default=None)
    p.add_argument("--state-dir", default=None)
    p.add_argument("--commit", action="store_true", default=None)
    p.add_argument("--claude-bin", default=None,
                   help="agent binary (default `claude`; with --agent-cli opencode/adk/codex, "
                        "that harness's own binary)")
    p.add_argument("--agent-cli", choices=["claude", "opencode", "adk", "codex"], default=None,
                   dest="agent_cli",
                   help="headless protocol: claude -p JSON vs adk run --jsonl vs "
                        "opencode run --format json vs codex exec --json events "
                        "(default: auto — named after the binary)")
    p.add_argument("--adk-agent-dir", default=None, dest="adk_agent_dir",
                   help="mounted ADK agent directory for --agent-cli adk "
                        "(default: $LOOP_SPEC_ADK_AGENT_DIR)")
    p.add_argument("--reset", action="store_true", default=None)
    args, extra = p.parse_known_args(argv)
    if extra[:1] == ["--"]:
        extra = extra[1:]

    base: dict = {}
    if args.config:
        base = json.loads(Path(args.config).read_text())
    if args.prompt_file:
        base["task"] = Path(args.prompt_file).read_text()
    elif args.task:
        base["task"] = args.task

    overrides = {k: v for k, v in vars(args).items()
                 if v is not None and k not in ("task", "prompt_file", "config")}
    base.update(overrides)
    base["extra_args"] = base.get("extra_args", []) + extra

    known = set(LoopConfig.__dataclass_fields__)
    unknown = [k for k in base if k not in known]
    if unknown:
        p.error(f"unknown config keys: {unknown}")
    if not base.get("task"):
        p.error("a task is required (positional, --prompt-file, or 'task' in --config)")
    cfg = LoopConfig(**base)
    conflict = cfg.transport_conflict()
    if conflict:
        p.error(conflict)
    bad_mode = cfg.permission_conflict()
    if bad_mode:
        p.error(bad_mode)
    bad_bounds = cfg.bounds_conflict()
    if bad_bounds:
        p.error(bad_bounds)
    return cfg


def main() -> int:
    result = run_loop(build_config())
    return 0 if result["status"] == "complete" else 1


if __name__ == "__main__":
    sys.exit(main())
