"""Harness bridge between loop-spec and Google ADK.

loop-spec skills are shell-first: they reach their shared code through
``${CLAUDE_SKILL_DIR}/../../lib/*.sh`` and expect ``CLAUDE_PLUGIN_ROOT`` and
``CLAUDE_PROJECT_DIR`` in every shell invocation. Claude Code sets those itself
and the OpenCode plugin supplies them through its ``shell.env`` hook. Under ADK,
the static values come from ``LocalEnvironment(env_vars=...)`` and the active
skill directory comes from session state at each Execute call. Keeping that last
value per session prevents concurrent ``adk web`` / ``adk api_server`` sessions
from changing one another's shell environment.

Two deliberate omissions, both load-bearing:

* ``SkillToolset`` is built WITHOUT ``environment=`` or ``code_executor=``. Both
    make it materialize skills into a temp or ``skills_folder`` copy and expose a
    RunSkillScriptTool over that copy. loop-spec skills do not live alone: they
    call siblings under ``lib/`` that no per-skill copy contains, so a materialized
    skill breaks every ``../../lib`` path. Skills supply instructions here; the
    filesystem the shell tools see is the real package.
* ``ExecuteBashTool`` is not used. It ``shlex.split()``s the command (killing
    pipes, ``&&`` and ``$( )``), exposes no env injection, and demands per-call
    confirmation — three separate ways loop-spec's shell lines would fail.
    A session-aware function over ``LocalEnvironment`` runs a real shell instead.
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path
from typing import Any, Optional

from google.adk.environment import LocalEnvironment
from google.adk.skills import load_skill_from_dir
from google.adk.tools import ToolContext
from google.adk.tools.environment import EnvironmentToolset
from google.adk.tools.skill_toolset import SkillToolset

# extensions/adk/loop_spec_adk/bridge.py -> the package root three levels up.
PACKAGE_ROOT = Path(__file__).resolve().parents[3]
SKILLS_DIR = PACKAGE_ROOT / "skills"
AGENTS_DIR = PACKAGE_ROOT / "agents"

# SessionStart-equivalent injections, in the order Claude Code's hooks.json fires
# them. Each prints a hook JSON payload whose additionalContext is the text to
# put in front of the model.
SESSION_START_HOOKS = (
    "hooks/team/discipline-inject.sh",
    "hooks/team/grill-inject.sh",
    "hooks/team/simplicity-inject.sh",
    "hooks/team/human-code-inject.sh",
    "hooks/team/rules-inject.sh",
    "hooks/team/micro-inject.sh",
)

# SkillToolset also builds a run_skill_script tool. loop-spec never uses it —
# skills call their scripts by real path through the shell, which is the only way
# `../../lib` resolves — and on the read-only agent it would advertise an
# execution path a judge must not have. SkillToolset honours tool_filter in
# get_tools(), so naming the three we want is enough.
SKILL_TOOLS = ("list_skills", "load_skill", "load_skill_resource")
FILE_TOOLS = ("ReadFile", "EditFile", "WriteFile")
SKILL_DIR_STATE_KEY = "loop_spec:active_skill_dir"
EXECUTE_TIMEOUT_S = 300.0
MAX_OUTPUT_CHARS = 30_000


def _truncate(value: str) -> str:
    """Bound shell output without hiding either the beginning or the failure tail."""
    if len(value) <= MAX_OUTPUT_CHARS:
        return value
    half = MAX_OUTPUT_CHARS // 2
    omitted = len(value) - (half * 2)
    return (value[:half] + f"\n... [{omitted} characters omitted] ...\n"
            + value[-half:])


class FileEnvironmentToolset(EnvironmentToolset):
    """EnvironmentToolset without its process-global Execute tool."""

    async def get_tools(self, context: Optional[Any] = None) -> list[Any]:
        return [tool for tool in await super().get_tools(context)
                if tool.name in FILE_TOOLS]


class LoopSpecBridge:
    """Owns loop-spec's project environment, skill inventory, and toolsets."""

    def __init__(self, project_dir: Optional[Path | str] = None,
                 *, headless: Optional[bool] = None) -> None:
        self.project_dir = Path(project_dir or os.getcwd()).resolve()
        self.env_vars: dict[str, str] = {
            "LOOP_SPEC_HARNESS": "adk",
            "CLAUDE_PLUGIN_ROOT": str(PACKAGE_ROOT),
            "CLAUDE_PROJECT_DIR": str(self.project_dir),
        }
        # The caller must mark one-shot execution explicitly. Inferring it from
        # the `_` executable misclassifies `adk web` and `adk api_server`, whose
        # executable is also named `adk` but whose sessions are interactive.
        if headless is None:
            headless = os.environ.get("LOOP_SPEC_NON_INTERACTIVE") == "1"
        if headless:
            self.env_vars["LOOP_SPEC_NON_INTERACTIVE"] = "1"
        # The run profile (.loop-spec/profile.json, lib/profile.sh) is project
        # policy; this is the harness's env seam, so it is applied here the way the
        # Agent SDK applies it through ClaudeAgentOptions.env. A variable the caller
        # already set in the process environment outranks the file.
        for key, value in self.profile_env().items():
            if key not in os.environ:
                self.env_vars.setdefault(key, value)

        self.environment = LocalEnvironment(working_dir=self.project_dir,
                                            env_vars=self.env_vars)
        self.skills = [
            load_skill_from_dir(skill_dir)
            for skill_dir in sorted(SKILLS_DIR.iterdir())
            if skill_dir.is_dir() and (skill_dir / "SKILL.md").is_file()
        ]
        self.skill_dirs = {
            skill.frontmatter.name: SKILLS_DIR / skill.frontmatter.name
            for skill in self.skills
        }

    def set_skill_dir(self, skill_name: str, state: Any) -> Optional[Path]:
        """Point this session's CLAUDE_SKILL_DIR at a skill's real directory.

        ADK's Skill model carries instructions and resources in memory and no
        source path, so the mapping comes from this loader rather than from the
        tool result. Unknown names leave the session's previous value alone: a
        skill still executing must not lose its directory because an unrelated
        lookup missed.
        """
        skill_dir = self.skill_dirs.get(skill_name)
        if skill_dir is None:
            return None
        state[SKILL_DIR_STATE_KEY] = str(skill_dir)
        return skill_dir

    def profile_env(self) -> dict[str, str]:
        """Resolve the project's run profile to the variables it sets."""
        try:
            out = subprocess.run(
                ["bash", str(PACKAGE_ROOT / "lib" / "profile.sh"), "resolve"],
                cwd=self.project_dir, capture_output=True, text=True, check=True,
                env={**os.environ, "CLAUDE_PROJECT_DIR": str(self.project_dir)})
        except (OSError, subprocess.CalledProcessError) as exc:
            detail = getattr(exc, "stderr", "") or str(exc)
            raise RuntimeError(f"loop-spec profile did not resolve: {detail.strip()}") from exc
        return dict(json.loads(out.stdout).get("env", {}))

    def environment_for(self, state: Any) -> dict[str, str]:
        """Build one invocation's environment from static and session state."""
        env_vars = dict(self.env_vars)
        skill_dir = state.get(SKILL_DIR_STATE_KEY) if state is not None else None
        if isinstance(skill_dir, str) and skill_dir:
            env_vars["CLAUDE_SKILL_DIR"] = skill_dir
        return env_vars

    async def execute(self, command: str, state: Any) -> dict[str, Any]:
        """Run a real shell with the active session's skill environment."""
        environment = LocalEnvironment(working_dir=self.project_dir,
                                       env_vars=self.environment_for(state))
        await environment.initialize()
        try:
            result = await environment.execute(command, timeout=EXECUTE_TIMEOUT_S)
        except Exception as exc:
            return {"status": "error", "error": str(exc)}
        finally:
            await environment.close()
        response: dict[str, Any] = {"status": "ok"}
        if result.stdout:
            response["stdout"] = _truncate(result.stdout)
        if result.stderr:
            response["stderr"] = _truncate(result.stderr)
        if result.exit_code != 0:
            response.update(status="error", exit_code=result.exit_code)
        if result.timed_out:
            response.update(status="error",
                            error=f"Command timed out after {EXECUTE_TIMEOUT_S:g}s.")
        return response

    def execute_tool(self) -> Any:
        """Return the session-aware Execute function exposed to working agents."""
        async def Execute(command: str, tool_context: ToolContext) -> dict[str, Any]:
            """Run a shell command in the project directory.

            Chain dependent commands with &&. The command inherits loop-spec's
            harness paths and the skill most recently loaded in this session.
            """
            if not command:
                return {"status": "error", "error": "`command` is required."}
            return await self.execute(command, tool_context.state)

        return Execute

    def toolsets(self) -> list[Any]:
        """The loop-spec file and skill tools (Execute is session-aware)."""
        return [
            FileEnvironmentToolset(environment=self.environment),
            SkillToolset(skills=self.skills, tool_filter=list(SKILL_TOOLS)),
        ]
