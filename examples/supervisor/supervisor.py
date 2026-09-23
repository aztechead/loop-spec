#!/usr/bin/env python3
"""Reference supervisor for loop-spec 7.x on the Claude Agent SDK.

Drives one `loop-spec cycle` run to completion by reading the `LOOP_SPEC_NEXT`
protocol (skills/loop-spec/SKILL.md) off the CLI's stdout: a `role` step goes
through `loop_spec.sdk_runner.run_step_sdk`, a `lead` step is driven here with the
same output_format/structured_output contract but a `can_use_tool` that answers
`AskUserQuestion` instead of denying it, and a `question` is answered by a fixed
policy (this run's default option, never a person).

**This is a reference supervisor, not a supported product surface.** Nothing here
is imported by loop-spec itself. Run live on 7.0.2 with claude-agent-sdk 0.2.157
(bundled CLI 2.1.277) and a Claude subscription login: one cycle converged and
delivered PR live-7#8 (docs/loop-spec/live-runs-7.0.md). Limits: a question with no
default and no options raises; an `external` step stops the run; role-step thinking
is not shown.

Usage:
    python3 supervisor.py --project-root DIR --request "<text>"
        [--slug SLUG] [--state-home DIR] [--model haiku]

Prerequisites: Python >= 3.10, `pip install claude-agent-sdk==0.2.157` (bundles the
Claude Code CLI), and the SDK's own auth (a subscription login, CLAUDE_CODE_OAUTH_TOKEN,
ANTHROPIC_API_KEY, or a cloud provider). DELIVER additionally needs `gh auth status`
and an `origin` remote.

Exit codes: 0 when the terminal result's status is "completed", 1 otherwise.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PROGRAM_ROOT = REPO_ROOT / "skills" / "loop-spec" / "program"
LAUNCHER = PROGRAM_ROOT / "loop-spec"
sys.path.insert(0, str(PROGRAM_ROOT))

from loop_spec import log  # noqa: E402
from loop_spec.jsonio import atomic_write_json  # noqa: E402
from loop_spec.paths import FeaturePaths, feature_dir, repo_id  # noqa: E402
from loop_spec.paths import state_home as resolve_state_home  # noqa: E402
from loop_spec.sdk_runner import run_step_sdk  # noqa: E402


def run_cli(*args: str) -> str:
    """One `loop-spec` subprocess call. stderr (the `[PHASE] summary` progress lines
    and any error with its repair hint) passes straight through as it is written;
    stdout (the markers) is captured for parsing and echoed. Raises on a non-zero
    exit, matching how a human running the same command would see it."""
    proc = subprocess.run([str(LAUNCHER), *args], stdout=subprocess.PIPE, text=True)
    if proc.stdout:
        log.stdout.info(proc.stdout.rstrip("\n"))
    if proc.returncode != 0:
        raise SystemExit(proc.returncode)
    return proc.stdout


def parse_next(stdout: str) -> list[dict]:
    """Every `LOOP_SPEC_NEXT` line in one call's output, in order. A
    `LOOP_SPEC_WAIT` line prints no `LOOP_SPEC_NEXT` at all."""
    prefix = "LOOP_SPEC_NEXT "
    return [json.loads(line[len(prefix):]) for line in stdout.splitlines() if line.startswith(prefix)]


class StepQueue:
    """Which `LOOP_SPEC_NEXT` to act on next, across calls.

    Feed each launcher call's stdout to `add`; `take` returns the next line to act
    on, in order. A wave's steps arrive together, and every call re-announces each
    step still open, including steps already taken; those re-announcements are
    dropped here, so each step is dispatched and submitted once.
    """

    def __init__(self) -> None:
        self._pending: list[dict] = []
        self._taken: set[str] = set()

    def add(self, output: str) -> None:
        for n in parse_next(output):
            if n["kind"] == "step" and (n["path"] in self._taken or n in self._pending):
                continue
            self._pending.append(n)

    def take(self) -> dict:
        if not self._pending:
            raise RuntimeError("loop-spec printed no LOOP_SPEC_NEXT line and no step is left to dispatch")
        n = self._pending.pop(0)
        if n["kind"] == "step":
            self._taken.add(n["path"])
        return n


def log_worker_events(role: str | None, events: list[dict]) -> None:
    """A role step's own transcript, as run_step_sdk recorded it: its text and the
    tools it called, on stderr after the step ends."""
    for event in events:
        if event["kind"] == "worker_text":
            log.stderr.info(f"  [{role}] {event['text']}")
        elif event["kind"] == "worker_tool_use":
            log.stderr.info(f"  [{role}] tool: {event['name']}")


def answer_by_policy(question: dict) -> str:
    """This reference supervisor's whole policy: the question's own default, else
    its first option. A "text"-kind question with neither is not something a fixed
    policy can answer; a real supervisor puts its own logic here."""
    if question.get("defaultValue"):
        return question["defaultValue"]
    options = question.get("options") or []
    if options:
        return options[0]["value"]
    raise RuntimeError(f"question {question['questionId']} has no default or options to answer automatically")


async def run_lead_step(step: dict, *, plugin_path: Path, model: str | None) -> None:
    """Drive one lead step through query(): the same output_format/structured_output
    contract run_step_sdk uses for a role step, but can_use_tool answers
    AskUserQuestion instead of denying it -- a lead step is meant to interact with
    a human (here, this file's fixed policy stands in for one)."""
    from claude_agent_sdk import ClaudeAgentOptions, query
    from claude_agent_sdk.types import HookMatcher, PermissionResultAllow

    async def can_use_tool(tool_name, input_data, context):
        if tool_name != "AskUserQuestion":
            return PermissionResultAllow()
        # Shape confirmed against docs.claude.com/en/agent-sdk/user-input ("Handle
        # approvals and user input"): updated_input carries the original questions
        # array plus an "answers" dict keyed by each question's own text.
        answers = {}
        for question in input_data.get("questions", []):
            options = question.get("options") or []
            answers[question["question"]] = options[0]["label"] if options else ""
        return PermissionResultAllow(updated_input={**input_data, "answers": answers})

    async def keep_stream_open(input_data, tool_use_id, context):
        # Same docs page: a finite prompt stream can close before can_use_tool
        # fires unless a PreToolUse hook keeps it open.
        return {"continue_": True}

    async def prompt_stream():
        yield {"type": "user", "message": {"role": "user", "content": step["prompt"]}}

    options = ClaudeAgentOptions(
        cwd=step["cwd"], model=model, permission_mode="acceptEdits",
        plugins=[{"type": "local", "path": str(plugin_path)}],
        setting_sources=["user", "project", "local"],
        output_format={"type": "json_schema", "schema": step["schema"]},
        can_use_tool=can_use_tool,
        hooks={"PreToolUse": [HookMatcher(matcher=None, hooks=[keep_stream_open])]},
    )

    result_msg = None
    async for msg in query(prompt=prompt_stream(), options=options):
        if type(msg).__name__ == "AssistantMessage":
            # Stream the lead's own reasoning and text to stderr as it arrives.
            for block in msg.content:
                text = getattr(block, "thinking", None) or getattr(block, "text", None)
                if text:
                    log.stderr.info(f"  [lead] {text}")
        if type(msg).__name__ == "ResultMessage":
            result_msg = msg

    if result_msg is None or result_msg.subtype != "success" or not isinstance(result_msg.structured_output, dict):
        reason = getattr(result_msg, "subtype", None) or "no result message"
        raise SystemExit(f"lead step ({step.get('role')}) failed: {reason}")
    atomic_write_json(Path(step["resultPath"]), result_msg.structured_output)


def drive(project_root: Path, state_home: str | None, slug: str | None, request: str | None, model: str | None) -> int:
    home_args = ["--state-home", state_home] if state_home else []
    args = ["cycle", "--project-root", str(project_root), *home_args]
    args += ["--slug", slug] if slug else ["--request", request]
    queue = StepQueue()
    queue.add(run_cli(*args))

    while True:
        next_ = queue.take()
        if next_["kind"] == "result":
            break
        # LOOP_SPEC_NEXT is the only place a stub is told the run's slug (SKILL.md);
        # every submit/answer call after the first needs it.
        run_slug = next_["slug"]
        common = ["--project-root", str(project_root), *home_args, "--slug", run_slug]

        if next_["kind"] == "step":
            step = json.loads(Path(next_["path"]).read_text())
            if step["kind"] == "role":
                # run_step_sdk needs this run's own FeaturePaths (not just its
                # slug) to record store.state["run"]["runner"] = "sdk" and to
                # write the receipt under the state home, never beside the
                # worker-writable result (R2).
                run_paths = FeaturePaths(root=feature_dir(resolve_state_home(state_home), repo_id(project_root), run_slug))
                run = run_step_sdk(step, paths=run_paths, plugin_path=REPO_ROOT, model=step.get("model") or model)
                if not run.ok:
                    log.stderr.error(f"role step ({step.get('role')}) failed: {run.reason}")
                    return 1
                log_worker_events(step.get("role"), run.events)
                # steps.submit reads the receipt run_step_sdk wrote and grants
                # "controller-observed" evidence with no host needed. --dispatch
                # is passed anyway for protocol fidelity with the role-dispatch
                # shape SKILL.md describes.
                stdout = run_cli("submit", *common, "--step", step["stepAttemptId"], "--dispatch", step["stepAttemptId"])
            elif step["kind"] == "lead":
                asyncio.run(run_lead_step(step, plugin_path=REPO_ROOT, model=step.get("model") or model))
                stdout = run_cli("submit", *common, "--step", step["stepAttemptId"])
            else:
                log.stderr.error(f"external step at {next_['path']}: an operator must produce the product and submit it")
                return 1
        elif next_["kind"] == "question":
            question = json.loads(Path(next_["path"]).read_text())
            answer = answer_by_policy(question)
            stdout = run_cli("answer", *common, "--question", question["questionId"], "--answer", answer, "--scope", "run")
        else:
            raise RuntimeError(f"unknown LOOP_SPEC_NEXT kind: {next_['kind']}")
        # An SDK-run step is controller-observed, so the unattested re-dispatch a
        # Claude Code host can trigger does not arise here.
        queue.add(stdout)

    result = json.loads(Path(next_["path"]).read_text())
    log.stdout.info(json.dumps({k: result.get(k) for k in ("status", "outcome", "reason", "phaseReached")}, indent=2))
    return 0 if result.get("status") == "completed" else 1


def main() -> int:
    ap = argparse.ArgumentParser(description="Drive one loop-spec cycle run through the Claude Agent SDK.")
    ap.add_argument("--project-root", required=True, type=Path)
    ap.add_argument("--request", help="a new run's request text; omit when resuming with --slug")
    ap.add_argument("--slug", help="resume an existing run instead of starting one")
    ap.add_argument("--state-home", help="defaults to loop-spec's own default (LOOP_SPEC_HOME, else ~/.loop-spec)")
    ap.add_argument("--model", help="passed to the SDK when a step names no model of its own")
    args = ap.parse_args()
    if not args.slug and not args.request:
        ap.error("pass --request for a new run, or --slug to resume one")
    return drive(args.project_root.resolve(), args.state_home, args.slug, args.request, args.model)


if __name__ == "__main__":
    sys.exit(main())
