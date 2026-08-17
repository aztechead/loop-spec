#!/usr/bin/env bash
# adk-extension: assert the ADK bridge against the REAL google-adk package.
#
# Everything here would pass trivially against a mock, which is the point of not
# using one: the bridge's whole job is to satisfy ADK's actual contracts
# (LocalEnvironment reading env_vars at execute time, SkillToolset honouring
# tool_filter while EnvironmentToolset does not, App carrying plugins, LlmAgent
# being a pydantic model). Those are the things that break on an ADK upgrade.
#
# google-adk is not a loop-spec runtime dependency — only an ADK user installs
# it — so this suite SKIPS when it is absent. Point it at a specific interpreter
# with LOOP_SPEC_ADK_PYTHON=/path/to/python.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
PASS=0
FAIL=0

PY="${LOOP_SPEC_ADK_PYTHON:-python3}"
if ! "$PY" -c "import google.adk" >/dev/null 2>&1; then
  echo "adk-extension: SKIP — google-adk not importable by '$PY'"
  echo "  (install it, or set LOOP_SPEC_ADK_PYTHON, to run these assertions)"
  echo "Results: 0 passed, 0 failed (skipped)"
  exit 0
fi

check() { # check <label> <got> <want>
  if [[ "$2" == "$3" ]]; then
    echo "  ✓ $1"; PASS=$((PASS+1))
  else
    echo "  ✗ $1 (got '$2', want '$3')"; FAIL=$((FAIL+1))
  fi
}

OUT="$(PYTHONPATH="$REPO_ROOT/extensions/adk" "$PY" - <<'PY' 2>/dev/null
import asyncio, json, os, tempfile
from loop_spec_adk import (LoopSpecBridge, LoopSpecPlugin, build_agent,
                           build_app, build_readonly_agent, load_roles)
from loop_spec_adk.agent import adk_model

out = {}
bridge = LoopSpecBridge(".")
out["harness_env"] = bridge.env_vars.get("LOOP_SPEC_HARNESS")
out["plugin_root_is_repo"] = bridge.env_vars.get("CLAUDE_PLUGIN_ROOT") == os.getcwd()
out["project_dir_set"] = bool(bridge.env_vars.get("CLAUDE_PROJECT_DIR"))
out["skills_loaded"] = len(bridge.skills)
out["roles_loaded"] = len(load_roles())

# The portable selector and Claude aliases must never reach ADK as model ids.
out["model_inherit"] = adk_model("inherit", "gemini-2.5-pro")
out["model_alias"] = adk_model("opus", "gemini-2.5-pro")
out["model_gemini"] = adk_model("gemini-2.5-flash", "gemini-2.5-pro")
out["model_litellm"] = adk_model("anthropic/claude-sonnet-4-5", "gemini-2.5-pro")

async def tool_names(agent):
    names = []
    for ts in agent.tools:
        if hasattr(ts, "get_tools"):
            names += [t.name for t in await ts.get_tools()]
        else:
            names.append(getattr(ts, "__name__", str(ts)))
    return sorted(names)

async def main():
    await bridge.environment.initialize()

    # CLAUDE_SKILL_DIR advances live, and a real lib script runs through it.
    bridge.set_skill_dir("cycle")
    r = await bridge.environment.execute('bash "$CLAUDE_SKILL_DIR/../../lib/harness.sh" detect')
    out["detect"] = (r.stdout or "").strip()
    out["skill_dir_is_cycle"] = bridge.env_vars["CLAUDE_SKILL_DIR"].endswith("/skills/cycle")

    # An unknown skill name must not clobber the directory of the running skill.
    bridge.set_skill_dir("no-such-skill")
    out["unknown_skill_keeps_dir"] = bridge.env_vars["CLAUDE_SKILL_DIR"].endswith("/skills/cycle")
    bridge.set_skill_dir("execute")
    out["skill_dir_moves"] = bridge.env_vars["CLAUDE_SKILL_DIR"].endswith("/skills/execute")

    # A real shell, not shlex.split: pipes and command substitution must survive.
    r = await bridge.environment.execute(
        'bash "$CLAUDE_PLUGIN_ROOT/lib/harness.sh" subagents | tr a-z A-Z')
    out["pipe"] = (r.stdout or "").strip()
    r = await bridge.environment.execute('echo "$(basename "$CLAUDE_PLUGIN_ROOT")"')
    out["subshell"] = (r.stdout or "").strip()

    # Capability gates answer for adk through the injected env, not a claude probe.
    r = await bridge.environment.execute('bash "$CLAUDE_PLUGIN_ROOT/lib/teams-capability.sh"')
    out["teams"] = (r.stdout or "").strip()
    r = await bridge.environment.execute('bash "$CLAUDE_PLUGIN_ROOT/lib/workflow-availability.sh"')
    out["workflows"] = (r.stdout or "").strip()

    out["root_tools"] = await tool_names(build_agent(bridge=bridge))
    out["readonly_tools"] = await tool_names(build_readonly_agent(bridge=bridge))

    app = build_app(".")
    out["app_plugins"] = [p.name for p in app.plugins]
    out["app_agent"] = app.root_agent.name
    ro = build_app(".", readonly=True)
    out["readonly_app_agent"] = ro.root_agent.name

    # The plugin drives the same bridge it was handed.
    b2 = LoopSpecBridge(".")
    plugin = LoopSpecPlugin(b2)
    await plugin.after_tool_callback(
        tool=type("T", (), {"name": "load_skill"})(),
        tool_args={"skill_name": "deliver"}, tool_context=None, result={})
    out["plugin_sets_skill_dir"] = b2.env_vars.get("CLAUDE_SKILL_DIR", "").endswith("/skills/deliver")

    print(json.dumps(out))

asyncio.run(main())
PY
)"

if [[ -z "$OUT" ]]; then
  echo "  ✗ the ADK bridge driver produced no output"
  echo "Results: 0 passed, 1 failed"
  exit 1
fi

get() { echo "$OUT" | "$PY" -c "import json,sys;print(json.load(sys.stdin)[sys.argv[1]])" "$1"; }

SKILL_COUNT="$(find skills -mindepth 2 -maxdepth 2 -name SKILL.md | wc -l | tr -d ' ')"
ROLE_COUNT="$(find agents -maxdepth 1 -name '*.md' ! -name README.md | wc -l | tr -d ' ')"

echo "== ADK bridge against real google-adk =="
check "harness env is adk"            "$(get harness_env)" "adk"
check "CLAUDE_PLUGIN_ROOT is the repo" "$(get plugin_root_is_repo)" "True"
check "CLAUDE_PROJECT_DIR set"        "$(get project_dir_set)" "True"
check "every skill loads"             "$(get skills_loaded)" "$SKILL_COUNT"
check "every agent charter loads"     "$(get roles_loaded)" "$ROLE_COUNT"
check "lib script runs via CLAUDE_SKILL_DIR" "$(get detect)" "adk"
check "skill dir points at the skill" "$(get skill_dir_is_cycle)" "True"
check "unknown skill keeps prior dir" "$(get unknown_skill_keeps_dir)" "True"
check "skill dir advances"            "$(get skill_dir_moves)" "True"
check "shell pipes survive"           "$(get pipe)" "TRUE"
check "command substitution survives" "$(get subshell)" "loop-spec"
check "teams gated to none"           "$(get teams)" "none"
check "workflows gated to false"      "$(get workflows)" "false"
check "inherit falls back"            "$(get model_inherit)" "gemini-2.5-pro"
check "claude alias falls back"       "$(get model_alias)" "gemini-2.5-pro"
check "gemini id passes through"      "$(get model_gemini)" "gemini-2.5-flash"
check "litellm id passes through"     "$(get model_litellm)" "anthropic/claude-sonnet-4-5"
check "root tool surface"             "$(get root_tools)" \
  "['EditFile', 'Execute', 'ReadFile', 'WriteFile', 'dispatch_subagent', 'list_skills', 'load_skill', 'load_skill_resource']"
check "read-only tool surface"        "$(get readonly_tools)" \
  "['ReadFile', 'list_skills', 'load_skill', 'load_skill_resource']"
check "app carries the plugin"        "$(get app_plugins)" "['loop_spec']"
check "app wraps the agent"           "$(get app_agent)" "loop_spec"
check "read-only app wraps its agent" "$(get readonly_app_agent)" "loop_spec_readonly"
check "plugin sets the skill dir"     "$(get plugin_sets_skill_dir)" "True"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
