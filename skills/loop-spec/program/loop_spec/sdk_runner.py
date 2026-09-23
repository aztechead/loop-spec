"""Runs one step.json-shaped request through the real Claude Agent SDK.

Grounded from the installed package's source (claude-agent-sdk 0.2.157, bundled CLI
2.1.277) and its docs, NOT run live: nothing in this repository has SDK credentials.
`claude_agent_sdk` is imported lazily inside each function so the plugin stays
stdlib-only until an operator actually calls this module.

Use `run_step_sdk` to dispatch one step and get back a `StepRun`; `event_from_message`
to turn one SDK message (or, for an AssistantMessage, one of its content blocks) into
a ledger event dict; `policy` as the `can_use_tool` callback both this runner and
`examples/supervisor/supervisor.py` wire into `ClaudeAgentOptions`.
"""
import asyncio
import re
from dataclasses import dataclass
from pathlib import Path

from loop_spec.errors import LoopSpecError
from loop_spec.ids import digest_bytes, now_iso
from loop_spec.jsonio import atomic_write_json
from loop_spec.state import StateStore

_ASK_USER_QUESTION_MESSAGE = "questions go through loop-spec question.json"
# The two patterns team lead named as never auto-approved, regardless of permission_mode.
_RM_RF = re.compile(r"\brm\s+-rf\b")
_FORCE_PUSH = re.compile(r"\bgit\s+push\b.*--force\b")


@dataclass
class StepRun:
    ok: bool
    reason: str | None
    session_id: str | None
    events: list[dict]
    result_digest: str | None
    unverifiedLive: bool = True  # noqa: N815 -- matches the submission field name verbatim


def _import_sdk():
    try:
        import claude_agent_sdk
    except ImportError as exc:
        raise LoopSpecError(
            "claude-agent-sdk is not installed",
            repair="pip install claude-agent-sdk==0.2.157",
        ) from exc
    return claude_agent_sdk


def event_from_message(msg) -> dict | None:
    """One SDK message, or one AssistantMessage content block, to a ledger event.

    `run_step_sdk` unwraps an AssistantMessage's `content` list itself and calls
    this once per block, so a TextBlock/ToolUseBlock argument here is exactly what
    an AssistantMessage's own content held; ResultMessage arrives as the top-level
    message, unwrapped by nothing.
    """
    name = type(msg).__name__
    if name == "TextBlock":
        return {"kind": "worker_text", "text": msg.text}
    if name == "ToolUseBlock":
        return {"kind": "worker_tool_use", "name": msg.name}
    if name == "ResultMessage":
        return {
            "kind": "worker_result", "subtype": msg.subtype, "is_error": msg.is_error,
            "num_turns": msg.num_turns, "total_cost_usd": msg.total_cost_usd,
            "permission_denials": msg.permission_denials,
        }
    return None


async def policy(tool_name: str, input: dict, context):
    """The `can_use_tool` callback: deny AskUserQuestion and two Bash patterns,
    allow everything else. Never a catch-all approval of a destructive Bash command,
    regardless of `permission_mode`."""
    sdk = _import_sdk()
    if tool_name == "AskUserQuestion":
        return sdk.PermissionResultDeny(message=_ASK_USER_QUESTION_MESSAGE)
    if tool_name == "Bash":
        command = input.get("command", "")
        if _RM_RF.search(command):
            return sdk.PermissionResultDeny(message="rm -rf is never auto-approved; a worker has no human to confirm it")
        if _FORCE_PUSH.search(command):
            return sdk.PermissionResultDeny(message="a forced git push is never auto-approved; a worker has no human to confirm it")
    return sdk.PermissionResultAllow()


def _state_home_denial(paths, tool_name: str, input: dict):
    # R2: the run's own state directory (receipts, step/result records) is the
    # program's alone to write; a worker able to reach it with Write/Edit/
    # NotebookEdit or a Bash command naming it could author its own evidence
    # (the exact fabricated-receipt path this finding is about).
    sdk = _import_sdk()
    root = Path(paths.root)
    root_resolved = root.resolve()
    if tool_name in ("Write", "Edit", "NotebookEdit"):
        target = input.get("file_path")
        if target and Path(target).resolve().is_relative_to(root_resolved):
            return sdk.PermissionResultDeny(
                message=f"{tool_name} may not touch the run's own state directory ({root}); "
                        "a worker cannot author its own provenance")
    elif tool_name == "Bash":
        # A command is raw text, not a path this process can resolve on the
        # worker's behalf; matching both the exact string the program always
        # hands out and its resolved form (a symlinked /tmp, say) catches the
        # realistic case without pretending to parse an arbitrary shell command.
        command = input.get("command", "")
        if str(root) in command or str(root_resolved) in command:
            return sdk.PermissionResultDeny(
                message=f"Bash may not name a path under the run's own state directory ({root}); "
                        "a worker cannot author its own provenance")
    return None


def make_step_policy(paths):
    """`can_use_tool` for a real role-step dispatch: the state-home guard above,
    then the general `policy` above it. A bare `policy()` import (tests, or any
    caller with no run to protect) is unaffected."""
    async def _policy(tool_name: str, input: dict, context):
        denial = _state_home_denial(paths, tool_name, input)
        if denial is not None:
            return denial
        return await policy(tool_name, input, context)
    return _policy


async def _run_step_sdk_async(step: dict, *, paths, plugin_path: Path, model: str | None, permission_mode: str) -> StepRun:
    # R2: a receipt is only ever evidence of an SDK-launched run when the run's
    # own state SAYS so, recorded here (the one place that actually launches an
    # SDK session) before the session runs, not inferred later from a file's mere
    # presence. Idempotent: a later step in the same run just confirms the flag.
    store = StateStore.open(paths)
    if store.state["run"].get("runner") != "sdk":
        store.state["run"]["runner"] = "sdk"
        store.save()

    sdk = _import_sdk()
    options = sdk.ClaudeAgentOptions(
        cwd=step["cwd"], model=model, permission_mode=permission_mode,
        plugins=[{"type": "local", "path": str(plugin_path)}],
        setting_sources=["user", "project", "local"],
        output_format={"type": "json_schema", "schema": step["schema"]},
        can_use_tool=make_step_policy(paths),
    )

    events: list[dict] = []
    session_id: str | None = None
    result_msg = None
    async for msg in sdk.query(prompt=step["prompt"], options=options):
        if type(msg).__name__ == "AssistantMessage":
            for block in msg.content:
                event = event_from_message(block)
                if event is not None:
                    events.append(event)
            continue
        event = event_from_message(msg)
        if event is not None:
            events.append(event)
        if type(msg).__name__ == "ResultMessage":
            result_msg = msg
            session_id = msg.session_id

    # Fail closed: no structured output, or a subtype other than "success", writes
    # no result file at all -- an absent or malformed result is never mistaken for
    # a real one downstream.
    if result_msg is None:
        return StepRun(ok=False, reason="no result message", session_id=session_id, events=events, result_digest=None)
    if result_msg.subtype != "success" or not isinstance(result_msg.structured_output, dict):
        return StepRun(ok=False, reason=result_msg.subtype, session_id=session_id, events=events, result_digest=None)

    result_path = Path(step["resultPath"])
    atomic_write_json(result_path, result_msg.structured_output)
    result_digest = digest_bytes(result_path.read_bytes())

    # steps.submit reads this to grant "controller-observed" evidence: this
    # process watched the SDK session end successfully, even though no host
    # attests it the way a real Claude Code dispatch would. Written under the
    # state home (paths.steps_dir), never beside the worker-writable result
    # (R2): a result author has no path to a directory only the program itself
    # controls, so it cannot fabricate this the way a sidecar next to its own
    # output could be fabricated.
    from claude_agent_sdk import _cli_version
    receipt_path = paths.steps_dir / step["stepAttemptId"] / "receipt.json"
    atomic_write_json(receipt_path, {
        "stepAttemptId": step["stepAttemptId"], "sessionId": session_id, "resultDigest": result_digest,
        "sdkVersion": sdk.__version__, "cliVersion": _cli_version.__cli_version__,
        "finishedAt": now_iso(), "unverifiedLive": True,
    })
    return StepRun(ok=True, reason=None, session_id=session_id, events=events, result_digest=result_digest)


def run_step_sdk(step: dict, *, paths, plugin_path: Path, model: str | None, permission_mode: str = "acceptEdits") -> StepRun:
    return asyncio.run(_run_step_sdk_async(step, paths=paths, plugin_path=plugin_path, model=model, permission_mode=permission_mode))
