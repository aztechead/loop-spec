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

from .errors import LoopSpecError
from .ids import digest_bytes, now_iso
from .jsonio import atomic_write_json

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


async def _run_step_sdk_async(step: dict, *, plugin_path: Path, model: str | None, permission_mode: str) -> StepRun:
    sdk = _import_sdk()
    options = sdk.ClaudeAgentOptions(
        cwd=step["cwd"], model=model, permission_mode=permission_mode,
        plugins=[{"type": "local", "path": str(plugin_path)}],
        setting_sources=["user", "project", "local"],
        output_format={"type": "json_schema", "schema": step["schema"]},
        can_use_tool=policy,
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

    # steps.submit reads this beside the result to grant "controller-observed"
    # evidence: this process watched the SDK session end successfully, even though
    # no host attests it the way a real Claude Code dispatch would.
    from claude_agent_sdk import _cli_version
    atomic_write_json(result_path.with_name("sdk-receipt.json"), {
        "stepAttemptId": step["stepAttemptId"], "sessionId": session_id, "resultDigest": result_digest,
        "sdkVersion": sdk.__version__, "cliVersion": _cli_version.__cli_version__,
        "finishedAt": now_iso(), "unverifiedLive": True,
    })
    return StepRun(ok=True, reason=None, session_id=session_id, events=events, result_digest=result_digest)


def run_step_sdk(step: dict, *, plugin_path: Path, model: str | None, permission_mode: str = "acceptEdits") -> StepRun:
    return asyncio.run(_run_step_sdk_async(step, plugin_path=plugin_path, model=model, permission_mode=permission_mode))
