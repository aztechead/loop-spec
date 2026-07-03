#!/usr/bin/env python3
"""
loop.py — bounded autonomous agent loop for Claude Code. Layer 1 of loop-runner.

A loop is cron plus a decision-maker in the body. This harness is everything wrapped
around the decision so it halts safely: it repeatedly invokes `claude -p` (verified
headless primitive, JSON output with total_cost_usd / is_error / session_id), runs a
verifier, measures real progress, and stops on any guardrail.

Trust anchors, in order of importance:
  1. VERIFIER INTEGRITY — the verify command's inputs (tests, the script itself,
     any --protected paths) are hashed at start; if the agent touches them the loop
     halts immediately with halt_reason=verifier_integrity. A loop that can edit its
     own exam is not verified, it's grading itself.
  2. HARD STOPS — max iterations, cumulative dollar budget (from Claude Code's own
     cost report; falls back loudly to turn accounting if cost reads zero),
     wall-clock timeout, and stall detection.
  3. REAL PROGRESS, not motion — stall counts both "no file changes" AND "verifier
     failing with the same fingerprint", so an agent churning files in circles still
     halts. Pass/fail oscillation (with --judge) halts as verifier_thrash.
  4. FEEDBACK — full verifier output is saved per iteration and its tail is fed into
     the next prompt; fresh mode re-anchors a PROGRESS.md the agent maintains, so
     ralph-style context resets don't mean amnesia.
  5. MACHINE CONTRACT — a stable result.json (halt_reason, cost, cost_reliable,
     iterations, verifier state, start/end commit) so supervisors act on *why* the
     loop stopped, never by scraping stdout. Exit 0 only on verified completion.

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
HALT_BUDGET = "budget"
HALT_TIMEOUT = "timeout"
HALT_STALL = "no_progress"
HALT_INTEGRITY = "verifier_integrity"
HALT_THRASH = "verifier_thrash"
HALT_AGENT_ERROR = "agent_error"

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
    budget_usd: float = 5.0
    max_iterations: int = 10
    timeout_s: int = 3600
    no_progress: int = 3
    verify_timeout_s: int = 600
    mode: str = "fresh"               # fresh: ralph-style anchor reset; continue: --resume
    permission_mode: str = "acceptEdits"
    allowed_tools: str = ""
    model: str = ""
    fallback_model: str = ""          # --fallback-model: on overload / model-unavailable
                                      # the headless tick falls back to this model instead
                                      # of dying — matters for unattended fleet loops
    retry_watchdog: str = ""          # CLAUDE_CODE_RETRY_WATCHDOG for the child: the
                                      # recommended unattended-session retry mechanism
                                      # (CC 2.1.186). Empty = leave the env as inherited.
    max_turns: int = 30               # per-iteration turn cap (0 disables) — bounds a
                                      # single invocation so one tick can't eat the budget
    judge: bool = False
    judge_model: str = "claude-haiku-4-5-20251001"
    state_dir: str = ""               # default .loop/<task_id>
    commit: bool = False              # scoped git commit per productive iteration
    claude_bin: str = "claude"
    reset: bool = False
    extra_args: list = field(default_factory=list)

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
    cumulative_cost_usd: float = 0.0
    cost_reliable: bool = True
    total_turns: int = 0
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
                          "same task_id (cost and iteration counts carry over).")
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
# Claude Code invocation (headless)
# =============================================================================
def run_claude(prompt: str, cfg: LoopConfig, *, resume: Optional[str],
               permission_mode: Optional[str] = None, raw_log: Optional[Path] = None) -> dict:
    cmd = [cfg.claude_bin, "-p", prompt, "--output-format", "json",
           "--permission-mode", permission_mode or cfg.permission_mode]
    if cfg.allowed_tools:
        cmd += ["--allowedTools", cfg.allowed_tools]
    if resume:
        cmd += ["--resume", resume]
    if cfg.model:
        cmd += ["--model", cfg.model]
    if cfg.fallback_model:
        cmd += ["--fallback-model", cfg.fallback_model]
    if cfg.max_turns and not resume:
        cmd += ["--max-turns", str(cfg.max_turns)]
    cmd += list(cfg.extra_args)

    env = None
    if cfg.retry_watchdog:
        env = dict(os.environ)
        env["CLAUDE_CODE_RETRY_WATCHDOG"] = cfg.retry_watchdog

    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, env=env)
    except FileNotFoundError:
        return {"ok": False, "error": f"`{cfg.claude_bin}` not found on PATH",
                "cost": 0.0, "turns": 0, "session_id": resume, "result": ""}

    if raw_log is not None:  # capture everything: unattended, the only record is what you kept
        raw_log.parent.mkdir(parents=True, exist_ok=True)
        raw_log.write_text(proc.stdout or "")
        if proc.stderr.strip():
            raw_log.with_suffix(".stderr.txt").write_text(proc.stderr)

    if proc.returncode != 0:
        return {"ok": False, "error": (proc.stderr.strip() or f"exit {proc.returncode}")[:500],
                "cost": 0.0, "turns": 0, "session_id": resume,
                "result": proc.stdout.strip()[:1000]}
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return {"ok": False, "error": "non-JSON output from claude", "cost": 0.0,
                "turns": 0, "session_id": resume, "result": proc.stdout.strip()[:1000]}
    return {
        "ok": not data.get("is_error", False),
        "error": None if not data.get("is_error", False) else str(data.get("subtype", "agent error")),
        "cost": float(data.get("total_cost_usd") or 0.0),
        "turns": int(data.get("num_turns") or 0),
        "session_id": data.get("session_id") or resume,
        "result": data.get("result", "") or "",
    }


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


def judge_done(cfg: LoopConfig, verifier_output: str, start_sha: str) -> bool:
    """Optional cheap second opinion AFTER the verifier passes. The judge sees the
    actual diff of the work, not just the verifier's say-so — otherwise it is
    rubber-stamping the verifier rather than validating the work."""
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
    jcfg = LoopConfig(task="", claude_bin=cfg.claude_bin, model=cfg.judge_model,
                      allowed_tools="", max_turns=0)
    res = run_claude(prompt, jcfg, resume=None, permission_mode="plan")
    up = res["result"].upper()
    return res["ok"] and "DONE" in up and "NOT_DONE" not in up


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
        print(f"↻ Resuming '{task_id}' from iteration {state.iteration} "
              f"(${state.cumulative_cost_usd:.2f} spent). Raise --budget to extend a "
              f"budget-halted run; --reset to start clean.")

    if not cfg.verify:
        print("⚠  No --verify command. The loop cannot detect completion or verifier-"
              "level stalls; it will run to --max-iterations/--budget/--timeout. "
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
    warned_cost = not state.cost_reliable

    while True:
        # --- Hard stops, checked before spending anything --------------------
        if state.iteration >= cfg.max_iterations:
            status = HALT_MAX_ITER; break
        if state.cumulative_cost_usd >= cfg.budget_usd:
            status = HALT_BUDGET; break
        if time.time() - state.started_at >= cfg.timeout_s:
            status = HALT_TIMEOUT; break
        if cfg.no_progress and state.stale_streak >= cfg.no_progress:
            status = HALT_STALL; break
        # Thrash: pass→fail flapping (possible when a judge sends passes back to work)
        if len(state.verdicts) >= 4 and sum(
                1 for a, b in zip(state.verdicts, state.verdicts[1:]) if a and not b) >= 2:
            status = HALT_THRASH; break

        state.iteration += 1
        elapsed = time.time() - state.started_at
        print(f"\n── {task_id} · iter {state.iteration}/{cfg.max_iterations} "
              f"· ${state.cumulative_cost_usd:.2f}/${cfg.budget_usd:.2f} · {elapsed:.0f}s ──")

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
        res = run_claude(prompt, cfg, resume=resume,
                         raw_log=state_dir / f"iter-{state.iteration:03d}.raw.json")
        state.cumulative_cost_usd += res["cost"]
        state.total_turns += res["turns"]
        if res["session_id"]:
            state.session_id = res["session_id"]
        if res["ok"] and res["cost"] == 0.0 and res["turns"] > 0 and not warned_cost:
            warned_cost = True
            state.cost_reliable = False
            print("⚠  Claude Code reported $0.00 for a real run (common on subscription "
                  "plans). The dollar budget guard is blind — iteration, turn, and "
                  "timeout caps are now your only spend bounds. result.json will carry "
                  "cost_reliable=false.")
        if not res["ok"]:
            print(f"   agent run failed: {res['error']}")

        # --- Verifier integrity BEFORE trusting any verdict ---------------------
        if targets:
            now_hash = hash_paths(targets, ignore_dir)
            if now_hash != state.protected_hash:
                state.history.append({"iteration": state.iteration, "cost": round(res["cost"], 4),
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
            "cost": round(res["cost"], 4),
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
            if cfg.judge and not judge_done(cfg, verifier_output, state.start_sha):
                print("   verifier passed but judge said NOT_DONE — continuing.")
            else:
                status = HALT_COMPLETE
                break

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
        "cost_usd": round(state.cumulative_cost_usd, 4),
        "cost_reliable": state.cost_reliable,
        "total_turns": state.total_turns,
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
    print(f"  cost       : ${state.cumulative_cost_usd:.2f} of ${cfg.budget_usd:.2f}"
          + ("" if state.cost_reliable else "   (UNRELIABLE — see warning)"))
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
    p.add_argument("--budget", type=float, default=None, dest="budget_usd")
    p.add_argument("--max-iterations", type=int, default=None)
    p.add_argument("--timeout", type=int, default=None, dest="timeout_s")
    p.add_argument("--no-progress", type=int, default=None)
    p.add_argument("--verify-timeout", type=int, default=None, dest="verify_timeout_s")
    p.add_argument("--mode", choices=["fresh", "continue"], default=None)
    p.add_argument("--permission-mode", default=None)
    p.add_argument("--allowed-tools", default=None)
    p.add_argument("--model", default=None)
    p.add_argument("--fallback-model", default=None, dest="fallback_model")
    p.add_argument("--retry-watchdog", default=None, dest="retry_watchdog")
    p.add_argument("--max-turns", type=int, default=None)
    p.add_argument("--judge", action="store_true", default=None)
    p.add_argument("--judge-model", default=None)
    p.add_argument("--state-dir", default=None)
    p.add_argument("--commit", action="store_true", default=None)
    p.add_argument("--claude-bin", default=None)
    p.add_argument("--reset", action="store_true", default=None)
    args, extra = p.parse_known_args(argv)

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
    return LoopConfig(**base)


def main() -> int:
    result = run_loop(build_config())
    return 0 if result["status"] == "complete" else 1


if __name__ == "__main__":
    sys.exit(main())
