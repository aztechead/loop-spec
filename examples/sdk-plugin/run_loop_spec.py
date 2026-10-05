#!/usr/bin/env python3
"""Run one loop-spec entry inside a Claude Agent SDK session, with loop-spec loaded
as a local plugin.

This is the SDK equivalent of `claude -p "/loop-spec:cycle <request>"`: the session
invokes the plugin's skill, and the skill drives the run as it does in Claude Code.
Nothing from loop-spec is imported here. Every SDK call follows the Agent SDK docs
(https://code.claude.com/docs/en/agent-sdk/).

- RunWatch decides when the session is finished and where loop-spec's result is.
  It is the only stateful logic here, and test_run_loop_spec.py tests it.
- Questions: with --autonomous the session's environment carries
  LOOP_SPEC_MODE=autonomous, so loop-spec runs without asking, and any
  AskUserQuestion is declined with the instruction to choose a default; with
  --supervised it carries LOOP_SPEC_MODE=supervised (the lead asks the spec's
  questions, skips the approval step, and may stop to ask later) and each question
  is answered from stdin, as without either flag.
- `render` prints the lead's text to stdout, and thinking, tool calls, workers'
  output, and loop-spec's markers to stderr.

Usage:
    python3 run_loop_spec.py --project-root DIR "<request>"
        [--entry cycle|micro|debug|revise] [--autonomous | --supervised] [--model opus]
        [--plugin DIR ...] [--resume SESSION_ID] [--max-budget-usd N]

Exit code: 0 when loop-spec's result has status "completed", 1 for another status,
2 when the session ended without a result (resume it with --resume).
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import sys
import time
from pathlib import Path

from claude_agent_sdk import (
    TERMINAL_TASK_STATUSES,
    AssistantMessage,
    ClaudeAgentOptions,
    ClaudeSDKClient,
    Message,
    PermissionResultAllow,
    PermissionResultDeny,
    ResultMessage,
    SystemMessage,
    TaskNotificationMessage,
    TaskStartedMessage,
    TaskUpdatedMessage,
    TextBlock,
    ThinkingBlock,
    ToolPermissionContext,
    ToolResultBlock,
    ToolUseBlock,
    UserMessage,
)

PLUGIN_ROOT = Path(__file__).resolve().parents[2]  # the loop-spec repository root
PLUGIN_NAME = "loop-spec"
NEXT_PREFIX = "LOOP_SPEC_NEXT "  # kind "result" names the result file, as in 7.x
IDLE_SECONDS = 60  # how long a finished turn waits for a background task's follow-up turn
NO_ONE_TO_ASK = ("This is an autonomous run and no one will answer. Choose the reasonable default, "
                 "record it in the spec's assumptions, and continue.")

OUT = logging.getLogger("run_loop_spec.stdout")  # the lead's own text
ERR = logging.getLogger("run_loop_spec.stderr")  # progress, thinking, workers, tool calls


def configure_logging() -> None:
    for logger, stream in ((OUT, sys.stdout), (ERR, sys.stderr)):
        handler = logging.StreamHandler(stream)
        handler.setFormatter(logging.Formatter("%(message)s"))
        logger.addHandler(handler)
        logger.setLevel(logging.INFO)
        logger.propagate = False


def err(line: str) -> None:
    ERR.info(line)


def marker_lines(message: Message):
    """The `LOOP_SPEC_*` lines in a message's tool results: the loop-spec program's output."""
    if not (isinstance(message, UserMessage) and isinstance(message.content, list)):
        return
    for block in message.content:
        if isinstance(block, ToolResultBlock):
            content = block.content
            text = content if isinstance(content, str) else "\n".join(
                part.get("text", "") for part in (content or []) if isinstance(part, dict))
            yield from (line for line in text.splitlines() if line.startswith("LOOP_SPEC_"))


class RunWatch:
    """When is a loop-spec session finished, and where is its result?

    The lead runs workers as background tasks, so a turn can end while they still run,
    and a new turn starts when one finishes. Feed every message to `observe`; it returns
    True once a turn has ended with no task active and the result's `LOOP_SPEC_NEXT` already seen,
    or at once on an SDK error (`error` keeps the reason). `idle` is True while a turn
    has ended with no task active and no result: the caller waits IDLE_SECONDS for a
    follow-up turn and stops if none comes. A resumed session replays its stopped tasks
    and a zero-turn result first; that result is not a turn end.
    """

    def __init__(self) -> None:
        self.active_tasks: set[str] = set()
        self.turn_ended = False
        self.result_path: str | None = None
        self.session_id: str | None = None
        self.error: str | None = None

    @property
    def idle(self) -> bool:
        return self.turn_ended and not self.active_tasks

    def observe(self, message: Message) -> bool:
        if isinstance(message, TaskStartedMessage):
            self.active_tasks.add(message.task_id)
        elif isinstance(message, (TaskNotificationMessage, TaskUpdatedMessage)):
            if message.status in TERMINAL_TASK_STATUSES:
                self.active_tasks.discard(message.task_id)
        elif isinstance(message, SystemMessage) and message.subtype == "init":
            self.turn_ended = False
        elif isinstance(message, UserMessage):
            for line in marker_lines(message):
                if not line.startswith(NEXT_PREFIX):
                    continue
                try:
                    nxt = json.loads(line[len(NEXT_PREFIX):])
                except json.JSONDecodeError:
                    continue  # the lead cut the line in its own command; result_file() finds the result
                if nxt.get("kind") == "result":
                    self.result_path = nxt["path"]
        elif isinstance(message, ResultMessage):
            self.session_id = message.session_id
            if message.is_error:
                self.error = "; ".join([message.subtype, *(message.errors or [])])
                return True
            if message.num_turns > 0:
                self.turn_ended = True
        return self.idle and self.result_path is not None


async def answer_from_stdin(question: dict) -> str | None:
    """One line of stdin per attempt. A number picks that option (1-based) and is asked
    again when out of range; other text is a free answer; end of input returns None."""
    options = question.get("options") or []
    while True:
        err(f"  choose 1-{len(options)}, or type an answer:" if options else "  type an answer:")
        line = await asyncio.to_thread(sys.stdin.readline)
        if not line:
            return None
        raw = line.strip()
        if raw.isdigit() and options:
            if 1 <= int(raw) <= len(options):
                return options[int(raw) - 1]["label"]
            err(f"  {raw} is not an option")
        elif raw:
            return raw


def make_can_use_tool(autonomous: bool):
    """Allow and log every tool; handle AskUserQuestion. The docs' contract for an
    answer: PermissionResultAllow with updated_input carrying the original `questions`
    plus `answers` keyed by each question's text."""

    async def can_use_tool(tool_name: str, input_data: dict, context: ToolPermissionContext):
        if tool_name != "AskUserQuestion":
            err(f"  [allow] {tool_name}")
            return PermissionResultAllow()
        if autonomous:
            err("  [question declined: autonomous run]")
            return PermissionResultDeny(message=NO_ONE_TO_ASK)
        answers = {}
        for question in input_data.get("questions", []):
            err(f"\n[question] {question['question']}")
            for i, option in enumerate(question.get("options") or [], 1):
                err(f"  {i}. {option['label']}: {option.get('description', '')}")
            answer = await answer_from_stdin(question)
            if answer is None:
                return PermissionResultDeny(message="stdin ended with no answer; resume the session once you have one.",
                                            interrupt=True)
            answers[question["question"]] = answer
        return PermissionResultAllow(updated_input={**input_data, "answers": answers})

    return can_use_tool


def render(message: Message) -> None:
    if isinstance(message, TaskStartedMessage):
        err(f"  [task started] {message.description}")
    elif isinstance(message, TaskNotificationMessage):
        err(f"  [task {message.status}] {message.summary}")
    elif isinstance(message, AssistantMessage):
        who = "worker " if message.parent_tool_use_id is not None else ""
        for block in message.content:
            if isinstance(block, ThinkingBlock) and block.thinking:
                err(f"  [{who}thinking] {block.thinking}")
            elif isinstance(block, TextBlock) and who:
                err(f"  [worker] {block.text}")
            elif isinstance(block, TextBlock):
                OUT.info(block.text)
            elif isinstance(block, ToolUseBlock):
                summary = block.input.get("command") or block.input.get("description") or ""
                err(f"  [{who}tool {message.model}] {block.name} {str(summary)[:200]}")
    elif isinstance(message, UserMessage):
        for line in marker_lines(message):
            err(f"  {line}")
    elif isinstance(message, ResultMessage):
        err(f"[turn] {message.subtype} turns={message.num_turns} cost=${message.total_cost_usd}")


def prompt_for(args: argparse.Namespace) -> str:
    if not args.request:
        return ("Continue the loop-spec run from where it stopped: run the loop-spec status command, "
                "then follow the loop-spec skill from its next step until the run ends.")
    return f"/{PLUGIN_NAME}:{args.entry} {args.request}"


PHASES = ("spec", "plan", "execute", "verify", "iterate", "deliver")


def model_for(phase: str | None, phase_model: dict[str, str]) -> str | None:
    """The model for `phase`: that of the latest phase at or before it that `--phase-model` names, so
    `execute=sonnet` holds through deliver, and a resumed session lands on the right model."""
    if phase not in PHASES:
        return None
    named = [phase_model[p] for p in PHASES[: PHASES.index(phase) + 1] if p in phase_model]
    return named[-1] if named else None


def current_phase(project_root: Path) -> str | None:
    """The phase the newest run in the project is in, from its events.jsonl (`phase_start` records,
    and a `result` record once it is over): the lead may cut the LOOP_SPEC_PHASE_START lines out
    of its own command output, but not out of the file."""
    logs = sorted(project_root.glob(".loop-spec/runs/*/events.jsonl"), key=lambda p: p.stat().st_mtime)
    phase = None
    try:
        for line in logs[-1].read_text().splitlines() if logs else []:
            event = json.loads(line)
            if event.get("event") == "result":
                return "done"
            if event.get("event") == "phase_start":
                phase = event.get("phase")
    except (OSError, ValueError, AttributeError):
        return None
    return phase


def result_file(project_root: Path, since: float) -> str | None:
    """The newest result a run in the project wrote since `since`: the program keeps a copy in
    the run's directory, for when the lead's own command hid its LOOP_SPEC_NEXT line."""
    found = [p for p in project_root.glob(".loop-spec/runs/*/result.json") if p.stat().st_mtime >= since]
    return str(max(found, key=lambda p: p.stat().st_mtime)) if found else None


async def run(args: argparse.Namespace) -> int:
    options = ClaudeAgentOptions(
        cwd=str(args.project_root),
        plugins=[{"type": "local", "path": str(p)} for p in [PLUGIN_ROOT, *args.plugin]],
        # Project settings and CLAUDE.md only: personal ~/.claude settings stay out of the run.
        setting_sources=["project"],
        permission_mode="acceptEdits",
        can_use_tool=make_can_use_tool(args.autonomous),
        model=args.model,
        env={"LOOP_SPEC_MODE": "autonomous" if args.autonomous else "supervised"} if args.autonomous or args.supervised else {},
        thinking={"type": "adaptive", "display": "summarized"},
        forward_subagent_text=True,
        resume=args.resume,
        max_budget_usd=args.max_budget_usd,
    )
    watch = RunWatch()
    started = time.time()
    model = args.model
    async with ClaudeSDKClient(options=options) as client:
        await client.query(prompt_for(args))
        # receive_messages, not receive_response: a turn can end while workers still run.
        messages = client.receive_messages().__aiter__()
        while True:
            try:
                message = await asyncio.wait_for(messages.__anext__(), IDLE_SECONDS if watch.idle else None)
            except (asyncio.TimeoutError, StopAsyncIteration):
                break
            if isinstance(message, SystemMessage) and message.subtype == "init":
                err(f"[session] {message.data.get('session_id')}")
                if f"{PLUGIN_NAME}:{args.entry}" not in message.data.get("slash_commands", []):
                    err(f"{PLUGIN_NAME}:{args.entry} is not loaded; check --entry and the plugin path")
                    return 1
            render(message)
            if args.phase_model and isinstance(message, UserMessage):
                want = model_for(current_phase(args.project_root), args.phase_model)
                if want and want != model:
                    await client.set_model(want)
                    err(f"[model] {model or 'default'} -> {want}")
                    model = want
            if watch.observe(message):
                break

    if watch.result_path is None:
        watch.result_path = result_file(args.project_root, started)
    if watch.result_path is None:
        if watch.error:
            err(f"the SDK session failed: {watch.error}")
        err(f"no loop-spec result in this session; resume it with --resume {watch.session_id or '<session id>'}")
        return 2
    result = json.loads(Path(watch.result_path).read_text())
    err(json.dumps({k: result.get(k) for k in ("status", "outcome", "summary", "prUrl", "verifiedSha")}, indent=2))
    return 0 if result.get("status") == "completed" else 1


def main() -> int:
    ap = argparse.ArgumentParser(description="Run one loop-spec entry in a Claude Agent SDK session.")
    ap.add_argument("request", nargs="?", help="the entry's argument: request text, spec path, error report, or PR")
    ap.add_argument("--project-root", required=True, type=Path)
    ap.add_argument("--entry", default="cycle", choices=["cycle", "micro", "debug", "revise"])
    modes = ap.add_mutually_exclusive_group()
    modes.add_argument("--autonomous", action="store_true", help="no one answers questions; the run picks defaults")
    modes.add_argument("--supervised", action="store_true",
                       help="questions are answered from stdin; the spec's questions, no approval step")
    ap.add_argument("--model", help="the lead's model, e.g. opus; workers use the plugin agents' own models")
    ap.add_argument("--phase-model", action="append", default=[], metavar="PHASE=MODEL",
                    help="switch the lead to MODEL when the run enters PHASE (spec, plan, execute, verify, "
                         "iterate, deliver); repeatable")
    ap.add_argument("--plugin", action="append", type=Path, default=[], metavar="DIR",
                    help="another plugin to load in the session; repeatable")
    ap.add_argument("--resume", help="continue an earlier session by its id")
    ap.add_argument("--max-budget-usd", type=float)
    args = ap.parse_args()
    if not args.request and not args.resume:
        ap.error("pass a request, or --resume SESSION_ID")
    args.project_root = args.project_root.resolve()
    args.plugin = [p.resolve() for p in args.plugin]
    args.phase_model = dict(pair.split("=", 1) for pair in args.phase_model)
    configure_logging()
    return asyncio.run(run(args))


if __name__ == "__main__":
    sys.exit(main())
