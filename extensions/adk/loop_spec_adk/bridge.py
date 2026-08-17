"""Harness bridge between loop-spec and Google ADK.

loop-spec skills are shell-first: they reach their shared code through
``${CLAUDE_SKILL_DIR}/../../lib/*.sh`` and expect ``CLAUDE_PLUGIN_ROOT`` and
``CLAUDE_PROJECT_DIR`` in every shell invocation. Claude Code sets those itself
and the OpenCode plugin supplies them through its ``shell.env`` hook; under ADK
they come from ``LocalEnvironment(env_vars=...)``, which merges the mapping into
each subprocess and — critically — reads it at execute() time, so the dict this
module hands out stays live for the whole session.

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
  ``EnvironmentToolset`` over ``LocalEnvironment`` runs a real shell instead.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any, Optional

from google.adk.environment import LocalEnvironment
from google.adk.skills import load_skills_from_dir
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
    "hooks/team/rules-inject.sh",
    "hooks/team/micro-inject.sh",
)

# SkillToolset also builds a run_skill_script tool. loop-spec never uses it —
# skills call their scripts by real path through the shell, which is the only way
# `../../lib` resolves — and on the read-only agent it would advertise an
# execution path a judge must not have. SkillToolset honours tool_filter in
# get_tools(), so naming the three we want is enough.
SKILL_TOOLS = ("list_skills", "load_skill", "load_skill_resource")


class LoopSpecBridge:
    """Owns the live environment mapping and the loop-spec toolsets.

    One bridge per ADK session. ``env_vars`` is handed to LocalEnvironment by
    reference, so ``set_skill_dir`` takes effect on the next shell command
    without rebuilding anything.
    """

    def __init__(self, project_dir: Optional[Path | str] = None,
                 *, headless: Optional[bool] = None) -> None:
        self.project_dir = Path(project_dir or os.getcwd()).resolve()
        self.env_vars: dict[str, str] = {
            "LOOP_SPEC_HARNESS": "adk",
            "CLAUDE_PLUGIN_ROOT": str(PACKAGE_ROOT),
            "CLAUDE_PROJECT_DIR": str(self.project_dir),
        }
        # `adk run` is one-shot with nobody to answer a question; `adk web` and
        # `adk api_server` are persistent. lib/harness.sh ranks this assertion
        # below Claude Code's entrypoint stamp and above an inherited profile.
        if headless is None:
            headless = Path(os.environ.get("_", "")).name == "adk" or \
                os.environ.get("LOOP_SPEC_NON_INTERACTIVE") == "1"
        if headless:
            self.env_vars["LOOP_SPEC_NON_INTERACTIVE"] = "1"

        self.environment = LocalEnvironment(working_dir=self.project_dir,
                                            env_vars=self.env_vars)
        self.skills = load_skills_from_dir(SKILLS_DIR)
        self.skill_dirs = {
            skill.frontmatter.name: SKILLS_DIR / skill.frontmatter.name
            for skill in self.skills
        }

    def set_skill_dir(self, skill_name: str) -> Optional[Path]:
        """Point CLAUDE_SKILL_DIR at a loaded skill's real directory.

        ADK's Skill model carries instructions and resources in memory and no
        source path, so the mapping comes from this loader rather than from the
        tool result. Unknown names leave the previous value alone: a skill that
        is still executing must not lose its directory because an unrelated
        lookup missed.
        """
        skill_dir = self.skill_dirs.get(skill_name)
        if skill_dir is None:
            return None
        self.env_vars["CLAUDE_SKILL_DIR"] = str(skill_dir)
        return skill_dir

    def toolsets(self) -> list[Any]:
        """The loop-spec tool surface: shell + files, then skills."""
        return [
            EnvironmentToolset(environment=self.environment),
            SkillToolset(skills=self.skills, tool_filter=list(SKILL_TOOLS)),
        ]
