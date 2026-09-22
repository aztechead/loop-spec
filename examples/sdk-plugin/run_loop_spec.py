#!/usr/bin/env python3
"""Run one loop-spec entry inside a Claude Agent SDK session, with loop-spec loaded
as a local plugin.

This is the SDK equivalent of `claude -p "/loop-spec:cycle <request>"`: the session
invokes the plugin's own skill, and the skill drives the loop-spec program exactly
as it does in Claude Code (the lead runs `loop-spec`, dispatches workers with the
Agent tool, and asks questions with AskUserQuestion). Nothing from loop-spec is
imported here. Every SDK call follows the Agent SDK docs
(https://code.claude.com/docs/en/agent-sdk/): plugins, ClaudeSDKClient,
can_use_tool for approvals and AskUserQuestion, sessions, and message types.

Three modules:
- RunWatch decides when the session is finished and where loop-spec's terminal
  result is. It is the only stateful logic here, and its interface
  (`observe`, `idle`, `result_path`) is what test_run_loop_spec.py exercises.
- An Answerer answers one AskUserQuestion question, or returns None when it
  cannot. Two adapters sit at that seam: `answer_from_stdin` (the default; a
  terminal or piped input) and `answer_first_option` (only with --auto).
- `render` prints a message: the lead's text to stdout; thinking, tool calls,
  worker output, and the program's progress lines to stderr, prefixed.

Usage:
    python3 run_loop_spec.py --project-root DIR "<request>"
        [--entry cycle|micro|debug|revise] [--auto] [--model sonnet]
        [--resume SESSION_ID] [--max-budget-usd N]

Auth is the SDK's own: a Claude subscription login (`claude` then `/login`), or
CLAUDE_CODE_OAUTH_TOKEN from `claude setup-token`, or ANTHROPIC_API_KEY, or a
cloud provider's variables. Requires Python >= 3.10 and
`pip install claude-agent-sdk`; loop-spec itself needs git, python3 >= 3.11, and
for DELIVER an authenticated `gh` with an `origin` remote.

Exit code: 0 when loop-spec's terminal result has status "completed", 1 otherwise,
2 when the session ended without a terminal result: an SDK error (its reason is
printed), a question stdin could not answer, or a quiet stop (resume it with --resume).
"""
from __future__ import annotations

import argparse
import asyncio
import json
import sys
from pathlib import Path
from typing import Awaitable, Callable

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
NEXT_PREFIX = "LOOP_SPEC_NEXT "
IDLE_SECONDS = 60  # how long a finished turn waits for a task's follow-up turn


def err(line: str) -> None:
    print(line, file=sys.stderr, flush=True)


def tool_result_lines(block: ToolResultBlock) -> list[str]:
    content = block.content
    text = content if isinstance(content, str) else "\n".join(
        part.get("text", "") for part in (content or []) if isinstance(part, dict)
    )
    return text.splitlines()


class RunWatch:
    """When is a loop-spec session finished, and where is its result?

    The lead runs workers as background tasks, so a turn can end (ResultMessage)
    while they still run, and the CLI starts a new turn (a fresh init message)
    when one finishes. A resumed session also replays its stopped tasks and
    reports a successful zero-turn result before it takes the new prompt. Feed
    every message to `observe`; it returns True once a turn has ended with no task
    active and the terminal result already printed, or at once when a result
    reports an SDK error (`error` keeps its reason; running tasks do not keep a
    failed session open). `idle` is True while a turn has ended with no task active
    and no result: the caller waits IDLE_SECONDS for a follow-up turn, and stops if
    none comes.
    """

    def __init__(self) -> None:
        self.active_tasks: set[str] = set()
        self.turn_ended = False
        self.result_path: str | None = None
        self.last_result: ResultMessage | None = None
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
        elif isinstance(message, UserMessage) and isinstance(message.content, list):
            for block in message.content:
                if isinstance(block, ToolResultBlock):
                    for line in tool_result_lines(block):
                        if line.startswith(NEXT_PREFIX):
                            next_ = json.loads(line[len(NEXT_PREFIX):])
                            if next_["kind"] == "result":
                                self.result_path = next_["path"]
        elif isinstance(message, ResultMessage):
            self.last_result = message
            if message.is_error:
                self.error = "; ".join([message.subtype, *(message.errors or [])])
                return True
            if message.num_turns > 0:  # a successful zero-turn result is a resume replay
                self.turn_ended = True
        return self.idle and self.result_path is not None


# The question seam: one AskUserQuestion question in, the answer's text out, or
# None when this adapter cannot answer it.
Answerer = Callable[[dict], Awaitable["str | None"]]


async def answer_first_option(question: dict) -> str | None:
    options = question.get("options") or []
    return options[0]["label"] if options else None


async def answer_from_stdin(question: dict) -> str | None:
    """One line of stdin per attempt, a terminal or piped input. A number picks
    that option (1-based) and is re-asked when out of range; other text is a free
    answer; end of input returns None."""
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


def choose_answerer(auto: bool) -> Answerer:
    # Only an explicit --auto answers for the operator; stdin that is not a
    # terminal still supplies answers, it never turns on a policy.
    return answer_first_option if auto else answer_from_stdin


def make_can_use_tool(answer: Answerer):
    """can_use_tool runs for every tool call the permission rules would ask about.

    AskUserQuestion is how the loop-spec lead asks for requirements approval and
    other decisions. The docs' contract: return PermissionResultAllow with
    updated_input carrying the original `questions` plus an `answers` dict keyed by
    each question's text. Every other tool is allowed and logged, since the session
    runs in the repository the operator named.
    """

    async def can_use_tool(tool_name: str, input_data: dict, context: ToolPermissionContext):
        if tool_name != "AskUserQuestion":
            err(f"  [allow] {tool_name}")
            return PermissionResultAllow()
        answers = {}
        for question in input_data.get("questions", []):
            err(f"\n[question] {question['question']}")
            for i, option in enumerate(question.get("options") or [], 1):
                err(f"  {i}. {option['label']}: {option.get('description', '')}")
            answer_text = await answer(question)
            if answer_text is None:
                return PermissionResultDeny(
                    message="no answer for this question: stdin ended, or --auto found no option to "
                            "choose. Answer at a terminal or on piped stdin, then resume.",
                    interrupt=True,
                )
            answers[question["question"]] = answer_text
            err(f"  [answer] {answer_text}")
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
            if isinstance(block, ThinkingBlock):
                err(f"  [{who}thinking] {block.thinking}")
            elif isinstance(block, TextBlock) and who:
                err(f"  [worker] {block.text}")
            elif isinstance(block, TextBlock):
                print(block.text, flush=True)
            elif isinstance(block, ToolUseBlock):
                summary = block.input.get("command") or block.input.get("description") or ""
                err(f"  [{who}tool] {block.name} {str(summary)[:200]}")
    elif isinstance(message, UserMessage) and isinstance(message.content, list):
        for block in message.content:
            if isinstance(block, ToolResultBlock):
                for line in tool_result_lines(block):
                    if line.startswith("[") or line.startswith("LOOP_SPEC_"):
                        err(f"  {line}")
    elif isinstance(message, ResultMessage):
        err(f"[turn] {message.subtype} turns={message.num_turns} cost=${message.total_cost_usd}")


async def run(args: argparse.Namespace) -> int:
    options = ClaudeAgentOptions(
        cwd=str(args.project_root),
        plugins=[{"type": "local", "path": str(PLUGIN_ROOT)}],
        # Project settings and CLAUDE.md only: the operator's personal
        # ~/.claude settings and hooks stay out of an unattended run.
        setting_sources=["project"],
        permission_mode="acceptEdits",
        can_use_tool=make_can_use_tool(choose_answerer(args.auto)),
        model=args.model,
        thinking={"type": "adaptive", "display": "summarized"},
        # Workers are Agent-tool subagents; forward their text and thinking too.
        forward_subagent_text=True,
        resume=args.resume,
        max_budget_usd=args.max_budget_usd,
    )
    prompt = (
        f"/{PLUGIN_NAME}:{args.entry} {args.request}" if args.request else
        "Continue the loop-spec run from where it stopped: run the loop-spec status command "
        "for this run's slug, act on its open step or question, and follow LOOP_SPEC_NEXT until the run ends."
    )

    watch = RunWatch()
    async with ClaudeSDKClient(options=options) as client:
        await client.query(prompt)
        # receive_messages, not receive_response: receive_response stops at the
        # first ResultMessage, and a turn can end while workers still run.
        messages = client.receive_messages().__aiter__()
        while True:
            try:
                message = await asyncio.wait_for(messages.__anext__(), IDLE_SECONDS if watch.idle else None)
            except (asyncio.TimeoutError, StopAsyncIteration):
                break
            if isinstance(message, SystemMessage) and message.subtype == "init":
                plugins = [p.get("name") for p in message.data.get("plugins", [])]
                err(f"[session] {message.data.get('session_id')} plugins={plugins}")
                if f"{PLUGIN_NAME}:{args.entry}" not in message.data.get("slash_commands", []):
                    err(f"{PLUGIN_NAME}:{args.entry} is not loaded; check --entry and the plugin path")
                    return 1
            render(message)
            if watch.observe(message):
                break

    session_id = watch.last_result.session_id if watch.last_result else "<session id>"
    if watch.result_path is None:
        if watch.error:
            err(f"the SDK session failed: {watch.error}")
        err(f"no terminal loop-spec result in this session; resume it with --resume {session_id}")
        return 2
    result = json.loads(Path(watch.result_path).read_text())
    err(json.dumps({k: result.get(k) for k in ("status", "result", "reason", "prUrl", "phaseReached")}, indent=2))
    return 0 if result.get("status") == "completed" else 1


def main() -> int:
    ap = argparse.ArgumentParser(description="Run one loop-spec entry in a Claude Agent SDK session.")
    ap.add_argument("request", nargs="?", help="the entry's argument: request text, spec path, error report, or PR")
    ap.add_argument("--project-root", required=True, type=Path)
    ap.add_argument("--entry", default="cycle", choices=["cycle", "micro", "debug", "revise"])
    ap.add_argument("--auto", action="store_true", help="answer every question with its first option")
    ap.add_argument("--model", help="the lead's model; workers follow each step's own model")
    ap.add_argument("--resume", help="continue an earlier session by its id")
    ap.add_argument("--max-budget-usd", type=float)
    args = ap.parse_args()
    if not args.request and not args.resume:
        ap.error("pass a request, or --resume SESSION_ID")
    args.project_root = args.project_root.resolve()
    return asyncio.run(run(args))


if __name__ == "__main__":
    sys.exit(main())
