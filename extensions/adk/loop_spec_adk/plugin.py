"""ADK plugin bridging loop-spec's Claude Code lifecycle hooks.

    Claude Code surface       ADK bridge
    -----------------------   -----------------------------------------------
    CLAUDE_* environment      LocalEnvironment(env_vars=...) (see bridge.py)
    active skill directory    after_tool_callback on the `load_skill` tool
    SessionStart              first on_user_message_callback of a session
    UserPromptSubmit          on_user_message_callback (every message)
    PreToolUse                before_tool_callback (shared tool guards)
    Stop                      not bridged — see below

Context injection fails open. Pre-tool guards block on denial or execution failure;
returning an error result prevents ADK from executing the tool. The Stop event has no ADK counterpart that
can veto termination (`after_run_callback` observes, it cannot continue), so
ambient verification enforcement here is directive-only — the same position
opencode is in, and the reason `lib/cycle-reconcile.sh` carries the route-exit
contract on both.
"""

from __future__ import annotations

import asyncio
import json
import os
from typing import Any, Optional

from google.adk.plugins.base_plugin import BasePlugin
from google.genai import types

from .bridge import PACKAGE_ROOT, SESSION_START_HOOKS, LoopSpecBridge

HOOK_TIMEOUT_S = 15.0


async def run_hook(script_rel: str, payload: Optional[dict], bridge: LoopSpecBridge,
                   enforce: bool = False) -> Optional[str]:
    """Run a bundled hook and return its additionalContext, or None."""
    try:
        proc = await asyncio.create_subprocess_exec(
            "python3" if script_rel.endswith(".py") else "bash", str(PACKAGE_ROOT / script_rel),
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=str(bridge.project_dir),
            env={**os.environ, **bridge.env_vars},
        )
    except OSError:
        return "loop-spec could not start the tool guard" if enforce else None
    try:
        stdout, stderr = await asyncio.wait_for(
            proc.communicate(json.dumps(payload or {}).encode()), timeout=HOOK_TIMEOUT_S)
    except (asyncio.TimeoutError, BrokenPipeError):
        try:
            proc.kill()
        except ProcessLookupError:
            pass
        await proc.communicate()
        return "loop-spec tool guard timed out or lost its input" if enforce else None
    if enforce and proc.returncode == 2:
        return (stderr or b"loop-spec denied this tool call").decode("utf-8", "replace").strip()
    if proc.returncode != 0:
        return "loop-spec tool guard failed: " + stderr.decode("utf-8", "replace") if enforce else None
    text = (stdout or b"").decode("utf-8", "replace").strip()
    if not text:
        return None
    # jq pretty-prints, and a hook may log before its JSON. Retry from each line
    # that could begin the final object.
    lines = text.split("\n")
    for start in range(len(lines)):
        if not lines[start].lstrip().startswith("{"):
            continue
        try:
            parsed = json.loads("\n".join(lines[start:]))
        except json.JSONDecodeError:
            continue
        context = (parsed or {}).get("hookSpecificOutput", {}).get("additionalContext")
        return context if isinstance(context, str) and context else None
    return None


class LoopSpecPlugin(BasePlugin):
    """Registered on the ADK Runner: `Runner(plugins=[LoopSpecPlugin(bridge)])`."""

    def __init__(self, bridge: LoopSpecBridge, name: str = "loop_spec") -> None:
        super().__init__(name=name)
        self._bridge = bridge

    async def on_user_message_callback(self, *, invocation_context: Any,
                                       user_message: types.Content) -> Optional[types.Content]:
        session = getattr(invocation_context, "session", None)
        state = getattr(session, "state", None)
        pending: list[str] = []
        if state is None or not state.get("loop_spec:session_started"):
            if state is not None:
                state["loop_spec:session_started"] = True
            # Hook order is part of Claude Code's hooks.json contract. Run them
            # sequentially so side effects and injected text observe that order.
            for script in SESSION_START_HOOKS:
                context = await run_hook(script, None, self._bridge)
                if context:
                    pending.append(context)

        prompt = "".join(part.text for part in (user_message.parts or [])
                         if getattr(part, "text", None))
        done_criteria = await run_hook("hooks/team/done-criteria.sh",
                                       {"prompt": prompt}, self._bridge)
        if done_criteria:
            pending.append(done_criteria)
        if not pending:
            return None

        injected = "<loop-spec-context>\n" + "\n\n".join(pending) + "\n</loop-spec-context>"
        return types.Content(
            role=user_message.role or "user",
            parts=[types.Part.from_text(text=injected), *(user_message.parts or [])],
        )

    async def before_tool_callback(self, *, tool: Any, tool_args: dict[str, Any],
                                   tool_context: Any) -> Optional[dict[str, Any]]:
        denial = await run_hook("hooks/pre-tool-guard.py", {
            "tool_name": getattr(tool, "name", ""), "tool_input": tool_args,
            "cwd": str(self._bridge.project_dir),
        }, self._bridge, enforce=True)
        return {"status": "error", "error": denial} if denial else None

    async def after_tool_callback(self, *, tool: Any, tool_args: dict[str, Any],
                                  tool_context: Any,
                                  result: dict[str, Any]) -> Optional[dict[str, Any]]:
        if getattr(tool, "name", "") == "load_skill":
            skill_name = tool_args.get("skill_name")
            if isinstance(skill_name, str):
                self._bridge.set_skill_dir(skill_name, tool_context.state)
        return None
