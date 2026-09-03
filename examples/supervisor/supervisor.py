#!/usr/bin/env python3
"""Reference supervisor for loop-spec on the Claude Agent SDK.

A worked, end-to-end example of the supervisor interface
(docs/loop-spec/supervisor-interface.md) on the harness's own seams:

* profile   -> ``ClaudeAgentOptions.env`` carries ``lib/profile.sh resolve``
* store     -> ``LOOP_SPEC_STORE`` points at ``lib/supervisor/store-mirror.sh``
* sink      -> ``LOOP_SPEC_EVENT_SINK`` points at ``append-sink.sh``, and a
               ``PostToolUse`` hook reads the same phase markers natively
* oracle    -> ``can_use_tool`` answers every ``AskUserQuestion`` the supervised
               path asks, taking the option labeled ``(Recommended)``
* lifecycle -> the loop below reissues the cycle after each ``phase-handoff``
               result and stops on a terminal one

**This is a reference supervisor, not a supported product surface.** It answers
every question with the recommendation so the example stays readable; a real
supervisor would put its own policy in ``answer_question``. Nothing here is
imported by loop-spec itself, and it carries no compatibility guarantee.

Usage:
    python3 supervisor.py --project DIR --task "<description>" [--model haiku]
        [--preset supervised] [--mirror DIR] [--events FILE] [--max-rounds N]
        [--budget-usd X]

Prerequisites: ``pip install claude-agent-sdk`` (the SDK bundles the Claude Code
CLI), a Claude login or ``ANTHROPIC_API_KEY``, and ``git`` initialized in DIR.
DELIVER additionally needs ``gh auth status`` and an ``origin`` remote; without
them the run ends at delivery with ``gh_missing`` and everything before it is
still on disk.

Exit codes: 0 when the terminal result is ``completed``, 1 otherwise.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import subprocess
import sys
from pathlib import Path

from claude_agent_sdk import (
    AssistantMessage,
    ClaudeAgentOptions,
    ResultMessage,
    SystemMessage,
    TextBlock,
    query,
)
from claude_agent_sdk.types import HookMatcher, PermissionResultAllow

PLUGIN_ROOT = Path(__file__).resolve().parents[2]
SINK = Path(__file__).resolve().parent / "append-sink.sh"
MARKERS = ("LOOP_SPEC_PHASE_START", "LOOP_SPEC_PHASE_END", "LOOP_SPEC_RESULT")


def bash(*args: str, cwd: Path, env: dict[str, str]) -> str:
    return subprocess.run(
        ["bash", *args], cwd=cwd, env=env, capture_output=True, text=True, check=True
    ).stdout


def write_profile(project: Path, preset: str, mirror: Path) -> None:
    """Project policy lives in the file, not in this process: a later run from a
    terminal sees the same store and sink."""
    profile = {
        "preset": preset,
        "env": {
            "LOOP_SPEC_STORE": str(PLUGIN_ROOT / "lib" / "supervisor" / "store-mirror.sh"),
            "LOOP_SPEC_STORE_DIR": str(mirror),
            "LOOP_SPEC_EVENT_SINK": str(SINK),
        },
    }
    (project / ".loop-spec").mkdir(parents=True, exist_ok=True)
    (project / ".loop-spec" / "profile.json").write_text(json.dumps(profile, indent=2) + "\n")


def resolved_env(project: Path, events_file: Path) -> dict[str, str]:
    base = {**os.environ, "CLAUDE_PROJECT_DIR": str(project)}
    resolved = json.loads(bash(str(PLUGIN_ROOT / "lib" / "profile.sh"), "resolve", cwd=project, env=base))
    env = {k: v for k, v in resolved["env"].items() if k not in os.environ}
    env["LOOP_SPEC_EVENT_SINK_FILE"] = str(events_file)
    return env


def answer_question(question: dict) -> str:
    """The supervisor's policy. The reference policy is the plugin's recommendation."""
    options = question.get("options") or []
    for option in options:
        if "(Recommended)" in option.get("label", ""):
            return option["label"]
    return options[0]["label"] if options else ""


def make_can_use_tool(decision_log: Path):
    async def can_use_tool(tool_name: str, input_data: dict, context):
        if tool_name != "AskUserQuestion":
            return PermissionResultAllow(updated_input=input_data)
        answers = {}
        for question in input_data.get("questions", []):
            answers[question["question"]] = answer_question(question)
            with decision_log.open("a") as fh:
                fh.write(json.dumps({"question": question["question"],
                                     "header": question.get("header"),
                                     "answer": answers[question["question"]]}) + "\n")
            print(f"[oracle] {question.get('header')}: {answers[question['question']]}", flush=True)
        return PermissionResultAllow(
            updated_input={"questions": input_data.get("questions", []), "answers": answers}
        )
    return can_use_tool


async def keep_stream_open(input_data, tool_use_id, context):
    # The Python SDK closes a finite prompt stream before can_use_tool can fire
    # unless a hook keeps it open (Agent SDK guide, "Handle approvals and user input").
    return {"continue_": True}


async def phase_markers(input_data, tool_use_id, context):
    """Native event consumption: the same markers the sink receives, read from the
    Bash tool's response through PostToolUse."""
    response = input_data.get("tool_response")
    text = response if isinstance(response, str) else json.dumps(response)
    for line in text.splitlines():
        if line.startswith(MARKERS):
            print(f"[hook] {line[:160]}", flush=True)
    return {}


def stream(prompt: str):
    async def gen():
        yield {"type": "user", "message": {"role": "user", "content": prompt}}
    return gen()


async def run_once(prompt: str, options: ClaudeAgentOptions) -> ResultMessage | None:
    result = None
    async for message in query(prompt=stream(prompt), options=options):
        if isinstance(message, SystemMessage) and message.subtype == "init":
            print(f"[init] session={message.data.get('session_id')} plugins={message.data.get('plugins')}", flush=True)
        elif isinstance(message, AssistantMessage):
            for block in message.content:
                if isinstance(block, TextBlock) and block.text.strip():
                    print(f"[agent] {block.text.strip()[:200]}", flush=True)
        elif isinstance(message, ResultMessage):
            result = message
    return result


async def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--project", required=True, type=Path)
    ap.add_argument("--task", required=True)
    ap.add_argument("--model", default="haiku")
    ap.add_argument("--preset", default="supervised")
    ap.add_argument("--mirror", type=Path)
    ap.add_argument("--events", type=Path)
    ap.add_argument("--max-rounds", type=int, default=12)
    ap.add_argument("--budget-usd", type=float, default=None)
    args = ap.parse_args()

    project = args.project.resolve()
    mirror = (args.mirror or project.parent / f"{project.name}-mirror").resolve()
    events = (args.events or project.parent / f"{project.name}-events.jsonl").resolve()
    decisions = project.parent / f"{project.name}-oracle.jsonl"
    write_profile(project, args.preset, mirror)
    env = resolved_env(project, events)
    print(f"[profile] preset={args.preset} env={sorted(env)}", flush=True)

    options = ClaudeAgentOptions(
        cwd=str(project),
        model=args.model,
        env=env,
        plugins=[{"type": "local", "path": str(PLUGIN_ROOT)}],
        permission_mode="acceptEdits",
        can_use_tool=make_can_use_tool(decisions),
        hooks={
            "PreToolUse": [HookMatcher(matcher=None, hooks=[keep_stream_open])],
            "PostToolUse": [HookMatcher(matcher="Bash", hooks=[phase_markers])],
        },
        max_budget_usd=args.budget_usd,
        stderr=lambda line: None,
    )

    prompt = f"/loop-spec:auto {args.task}"
    for round_no in range(1, args.max_rounds + 1):
        print(f"[round {round_no}] {prompt}", flush=True)
        message = await run_once(prompt, options)
        result_path = project / ".loop-spec" / "last-result.json"
        result = json.loads(result_path.read_text()) if result_path.is_file() else None
        cost = getattr(message, "total_cost_usd", None)
        print(f"[round {round_no}] sdk={getattr(message, 'subtype', None)} cost={cost} "
              f"result={json.dumps({k: result.get(k) for k in ('status', 'outcome', 'reason', 'phaseReached')}) if result else None}",
              flush=True)
        if result is None:
            print("no terminal result was published; run lib/cycle-reconcile.sh in the project", file=sys.stderr)
            return 1
        if result.get("status") == "paused" and result.get("reason") == "phase-handoff":
            # Lifecycle: the plugin returned after one durable phase; a fresh context resumes it.
            prompt = "/loop-spec:cycle autonomous"
            continue
        # "completed" alone is not done: the first live run published status
        # "completed" from SPEC with outcome "completed-with-gaps". The outcome and
        # the converged flag are the contract's word on whether work was delivered.
        done = result.get("outcome") in ("delivered", "no-change-needed") and result.get("converged") is True
        if not done:
            print(f"not delivered: outcome={result.get('outcome')} phaseReached={result.get('phaseReached')} "
                  f"converged={result.get('converged')}", file=sys.stderr)
        return 0 if done else 1
    print(f"gave up after {args.max_rounds} rounds", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
