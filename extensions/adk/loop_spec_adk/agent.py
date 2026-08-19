"""Builds the loop-spec agents an ADK app mounts.

Two agents are published, mirroring what the loop-runner's rungs need:

``build_agent()``           the working agent — shell, files, skills, and the
                            dispatch tool that replaces Claude Code's `Agent`.
``build_readonly_agent()``  the judge/compiler agent — reads and skills only.
                            Read-only ticks (`--permission-mode plan`) select
                            this one, so a judge cannot edit the work it grades.

Role agents come from ``agents/*.md``: the same charters Claude Code and
OpenCode dispatch, parsed once and wrapped in ADK ``AgentTool``s.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any, Optional

import yaml
from google.adk.agents import LlmAgent
from google.adk.apps import App
from google.adk.tools import ToolContext, get_user_choice
from google.adk.tools.agent_tool import AgentTool
from google.adk.tools.environment import EnvironmentToolset
from google.adk.tools.skill_toolset import SkillToolset

from .bridge import AGENTS_DIR, SKILL_TOOLS, LoopSpecBridge
from .plugin import LoopSpecPlugin

DEFAULT_MODEL = os.environ.get("LOOP_SPEC_ADK_MODEL", "gemini-2.5-pro")

# The tools a read-only agent may hold. EnvironmentToolset.get_tools() returns
# its four tools unconditionally — it never consults the tool_filter its base
# class stores — so the filter has to be applied here or a judge silently keeps
# Execute, EditFile, and WriteFile.
READONLY_TOOLS = ("ReadFile",)

# loop-spec's portable model selector. Every agent charter ships `model: inherit`,
# and the Claude aliases (sonnet/opus/haiku/fable) that may appear there name no
# ADK model at all — forwarding either as a literal id fails the dispatch. A role
# model is honoured only when it is an ADK id: `gemini-*` natively, or
# `provider/model` through LiteLLM. This is the same rule loop.py's model_args()
# applies to the fleet backend, stated once per process boundary.
INHERIT = "inherit"


def adk_model(candidate: str, fallback: str) -> str:
    if not candidate or candidate == INHERIT:
        return fallback
    return candidate if candidate.startswith("gemini") or "/" in candidate else fallback

ROOT_INSTRUCTION = """You are loop-spec running under Google ADK.

Work through loop-spec's skills: call list_skills to see them, load_skill to read
one, and then follow it exactly as written. The skill bodies are the process;
they are not advisory.

File tools are restricted to the project directory. Shell commands start there
but inherit the permissions of the operating-system user running ADK; they are
not a sandbox and can reach paths that user can reach. Skills invoke
their shared code as `bash "${CLAUDE_SKILL_DIR}/../../lib/<script>.sh"` — those
paths resolve because CLAUDE_SKILL_DIR, CLAUDE_PLUGIN_ROOT, and
CLAUDE_PROJECT_DIR are exported into every command you run.

When a skill prescribes a one-shot subagent dispatch, call dispatch_subagent with
the role it names. Pass model when feature.models.<role> is an ADK id; omit it
to inherit the mounted agent. Consult skills/shared/adk-harness.md for how the
rest of the Claude Code tool surface maps onto this harness."""


class ReadOnlyEnvironmentToolset(EnvironmentToolset):
    """EnvironmentToolset restricted to READONLY_TOOLS."""

    async def get_tools(self, readonly_context: Optional[Any] = None) -> list[Any]:
        return [tool for tool in await super().get_tools(readonly_context)
                if tool.name in READONLY_TOOLS]


def load_roles() -> dict[str, dict[str, str]]:
    """Parse agents/*.md into {role: {description, instruction, model}}."""
    roles: dict[str, dict[str, str]] = {}
    for path in sorted(AGENTS_DIR.glob("*.md")):
        text = path.read_text(encoding="utf-8")
        if not text.startswith("---\n"):
            continue
        end = text.find("\n---", 3)
        if end < 0:
            continue
        meta = yaml.safe_load(text[4:end + 1]) or {}
        name = meta.get("name")
        if not name:
            continue
        roles[str(name)] = {
            "description": str(meta.get("description", "")),
            "instruction": text[end + 4:].strip(),
            "model": str(meta.get("model") or ""),
        }
    return roles


def build_agent(project_dir: Optional[Path | str] = None, *,
                model: str = DEFAULT_MODEL,
                bridge: Optional[LoopSpecBridge] = None) -> LlmAgent:
    """The loop-spec working agent.

    Pass an existing `bridge` when the caller also registers `LoopSpecPlugin`:
    both must hold the SAME bridge, because the plugin records active-skill state
    consumed by the bridge's Execute tool. `build_app()` does that pairing for
    you and is what a mounted agent should use.
    """
    bridge = bridge or LoopSpecBridge(project_dir)
    roles = load_roles()

    def role_agent(role: str, override: str = "") -> LlmAgent:
        spec = roles[role]
        return LlmAgent(
            name=f"loop_spec_{role.replace('-', '_')}",
            model=adk_model(override or spec["model"], model),
            description=spec["description"],
            instruction=spec["instruction"],
            tools=[*bridge.toolsets(), bridge.execute_tool()],
        )

    async def dispatch_subagent(subagent_type: str, description: str, prompt: str,
                                tool_context: ToolContext,
                                model: str = "") -> dict[str, Any]:
        """Dispatch one loop-spec role for a single task and return its result.

        Args:
            subagent_type: role to dispatch, e.g. "implementer" or
                "spec-compliance-reviewer". The "loop-spec:" prefix Claude Code
                uses is accepted and stripped.
            description: 3-5 word label for the task.
            prompt: the full task for the role to perform.
            model: optional ADK model id (`gemini-*` or `provider/model`).
                Empty, inherit, and Claude aliases use the mounted agent's model.
        """
        role = subagent_type.split(":")[-1]
        if role not in roles:
            return {"status": "error",
                    "error": f"unknown subagent_type '{subagent_type}'. "
                             f"Known roles: {', '.join(sorted(roles))}"}
        result = await AgentTool(agent=role_agent(role, model)).run_async(
            args={"request": prompt}, tool_context=tool_context)
        return {"status": "ok", "role": role, "description": description,
                "result": result}

    return LlmAgent(
        name="loop_spec",
        model=model,
        description="Loop-driven development: spec, plan, execute, verify, deliver.",
        instruction=ROOT_INSTRUCTION,
        tools=[*bridge.toolsets(), bridge.execute_tool(), get_user_choice,
               dispatch_subagent],
    )


def build_readonly_agent(project_dir: Optional[Path | str] = None, *,
                         model: str = DEFAULT_MODEL,
                         bridge: Optional[LoopSpecBridge] = None) -> LlmAgent:
    """The judge/compiler agent: skills and ReadFile, no shell, no writes."""
    bridge = bridge or LoopSpecBridge(project_dir)
    return LlmAgent(
        name="loop_spec_readonly",
        model=model,
        description="Read-only loop-spec judge and spec compiler.",
        instruction=ROOT_INSTRUCTION + "\n\nYou are READ-ONLY: you have no shell "
                    "and no write tools. Report findings; never edit.",
        tools=[ReadOnlyEnvironmentToolset(environment=bridge.environment),
               SkillToolset(skills=bridge.skills, tool_filter=list(SKILL_TOOLS))],
    )


def build_app(project_dir: Optional[Path | str] = None, *,
              model: str = DEFAULT_MODEL, readonly: bool = False) -> App:
    """An ADK `App` with the agent and its plugin sharing one bridge.

    `adk run <dir>` looks for a module-level `app` before `root_agent`, so this
    is what a mounted agent exposes — it is the only form that carries the
    lifecycle plugin, and without the plugin CLAUDE_SKILL_DIR never advances off
    the skill a session started on.
    """
    bridge = LoopSpecBridge(project_dir)
    build = build_readonly_agent if readonly else build_agent
    return App(
        name="loop_spec_readonly" if readonly else "loop_spec",
        root_agent=build(model=model, bridge=bridge),
        plugins=[LoopSpecPlugin(bridge)],
    )
