#!/usr/bin/env bash
# adk-harness coverage: the ADK adaptation is a web of cross-file couplings
# (harness probe -> capability gates -> dispatch/skill mapping -> installer ->
# loop-runner backend). A rename or dropped pointer on any edge silently strands
# ADK runs on a tool or path that does not exist there. This pins every edge,
# mirroring tests/opencode-harness-coverage.test.sh.
#
# It also guards the removal: pi is gone, and a reference that survives points
# at a harness with no contract, no backend, and no extension.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
PASS=0
FAIL=0

# file<TAB>fixed-string that must be present.
checks=(
  # -- the adaptation contract exists and names its collaborators
  "skills/shared/adk-harness.md	lib/harness.sh"
  "skills/shared/adk-harness.md	execute-loop-fleet.md"
  "skills/shared/adk-harness.md	autonomous-mode.md"
  "skills/shared/adk-harness.md	--agent-cli adk"
  "skills/shared/adk-harness.md	lib/adk-install.sh"
  "skills/shared/adk-harness.md	dispatch_subagent"
  "skills/shared/adk-harness.md	subagent_type"
  "skills/shared/adk-harness.md	LOOP_SPEC_ADK_AGENT_DIR"
  "skills/shared/adk-harness.md	executionRootMode: \"in-place\""
  "skills/shared/adk-harness.md	lib/pr-delivery.sh"
  "skills/shared/adk-harness.md	directive-only"
  # -- the two facts a fleet debugger needs, recorded where they are found
  "skills/shared/adk-harness.md	CANNOT"
  "skills/shared/adk-harness.md	_readonly"
  "skills/shared/adk-harness.md	token counts, not money"
  # -- the harness probe knows adk and grants the subagent capability
  "lib/harness.sh	adk"
  "lib/harness.sh	claude|opencode|adk"
  "lib/execute-rung.sh	harness.sh"
  # -- capability gates are non-claude-gated (the bash side of the contract)
  "lib/teams-capability.sh	!= \"claude\""
  "lib/workflow-availability.sh	!= \"claude\""
  # -- the bridge: env delivery, skill dir tracking, SessionStart scripts
  "extensions/adk/loop_spec_adk/bridge.py	LOOP_SPEC_HARNESS"
  "extensions/adk/loop_spec_adk/bridge.py	CLAUDE_SKILL_DIR"
  "extensions/adk/loop_spec_adk/bridge.py	micro-inject.sh"
  "extensions/adk/loop_spec_adk/bridge.py	LocalEnvironment"
  "extensions/adk/loop_spec_adk/plugin.py	load_skill"
  "extensions/adk/loop_spec_adk/plugin.py	on_user_message_callback"
  "extensions/adk/loop_spec_adk/agent.py	AgentTool"
  "extensions/adk/loop_spec_adk/agent.py	dispatch_subagent"
  # -- installer places both agents and records the mount
  "lib/adk-install.sh	loop_spec_readonly"
  "lib/adk-install.sh	adk-install.json"
  "lib/adk-install.sh	build_app"
  "lib/adk-install.sh	LOOP_SPEC_ADK_AGENT_DIR"
  # -- loop-runner: the headless adk backend and its plumbing
  "skills/loop-runner/scripts/loop.py	def run_adk"
  "skills/loop-runner/scripts/loop.py	--default_llm_model"
  "skills/loop-runner/scripts/loop.py	--adk-agent-dir"
  "skills/loop-runner/scripts/supervisor.py	adk"
  "skills/loop-runner/scripts/compile_spec.py	adk"
  "skills/loop-runner/tests/fakeadk	session_id"
  # -- unattended recipes use the same seam as lib/harness.sh cli
  "lib/issue-intake.sh	LOOP_SPEC_ADK_AGENT_DIR"
  # -- the graph engine stays harness-neutral
  "skills/shared/adk-harness.md	Graph engine (GDD)"
  "skills/shared/adk-harness.md	lib/graph/run.sh"
)

for entry in "${checks[@]}"; do
  file="${entry%%	*}"
  needle="${entry#*	}"
  if [[ -f "$file" ]] && grep -qF -e "$needle" "$file"; then
    PASS=$((PASS+1)); echo "PASS: $file contains '$needle'"
  else
    FAIL=$((FAIL+1)); echo "FAIL: $file missing '$needle'"
  fi
done

# -- behavioural: the probe itself, driven through the documented override.
probe() { # probe <label> <expected> <verb>
  got="$(LOOP_SPEC_HARNESS=adk bash lib/harness.sh "$3" 2>/dev/null)"
  if [[ "$got" == "$2" ]]; then
    PASS=$((PASS+1)); echo "PASS: harness.sh $3 under adk == '$2'"
  else
    FAIL=$((FAIL+1)); echo "FAIL: harness.sh $3 under adk == '$got', want '$2'"
  fi
}
probe "detect" "adk" detect
probe "cli" "adk" cli
probe "subagents" "true" subagents

for gate in "teams-capability.sh	none" "workflow-availability.sh	false"; do
  script="${gate%%	*}"; want="${gate#*	}"
  got="$(LOOP_SPEC_HARNESS=adk CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 \
         LOOP_SPEC_WORKFLOWS_AVAILABLE=1 LOOP_SPEC_TEAMS_MODE=implicit \
         bash "lib/$script" 2>/dev/null)"
  # A positive override must not conjure a surface ADK does not have.
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS+1)); echo "PASS: lib/$script under adk == '$want' despite a positive override"
  else
    FAIL=$((FAIL+1)); echo "FAIL: lib/$script under adk == '$got', want '$want'"
  fi
done

# -- pi is gone: no shipped file may still reference it.
# Shipped content only: the test suite legitimately names the retired harness in
# its removal guards (tests/lib/harness.test.sh pins that `pi` now resolves to
# claude), and scanning itself would make this check permanently red.
pi_hits="$(grep -rlE 'pi-harness|--agent-cli pi\b|PI_CODING_AGENT_DIR|extensions/pi|pi\.dev|/skill:' \
             skills lib hooks agents commands extensions 2>/dev/null || true)"
if [[ -z "$pi_hits" ]]; then
  PASS=$((PASS+1)); echo "PASS: no shipped file references the removed pi harness"
else
  FAIL=$((FAIL+1)); echo "FAIL: pi references survive in:"; echo "$pi_hits" | sed 's/^/    /'
fi

for gone in "extensions/pi" "skills/shared/pi-harness.md" "package.json" \
            "tests/pi-extension.test.sh" "tests/validate-pi-manifest.test.sh"; do
  if [[ -e "$gone" ]]; then
    FAIL=$((FAIL+1)); echo "FAIL: $gone should have been removed with the pi harness"
  else
    PASS=$((PASS+1)); echo "PASS: $gone removed"
  fi
done

# -- the installer must produce a mount that imports, not just files that exist.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
if bash lib/adk-install.sh install --project "$TMP" --model gemini-2.5-flash >/dev/null 2>&1 \
   && bash lib/adk-install.sh check --project "$TMP" >/dev/null 2>&1; then
  PASS=$((PASS+1)); echo "PASS: adk-install install+check round-trips"
else
  FAIL=$((FAIL+1)); echo "FAIL: adk-install install+check failed"
fi
for want in "$TMP/adk_agents/loop_spec/agent.py" "$TMP/adk_agents/loop_spec_readonly/agent.py" \
            "$TMP/.loop-spec/adk-install.json"; do
  if [[ -f "$want" ]]; then
    PASS=$((PASS+1)); echo "PASS: installer wrote ${want#$TMP/}"
  else
    FAIL=$((FAIL+1)); echo "FAIL: installer did not write ${want#$TMP/}"
  fi
done
# `adk run` loads `app` before `root_agent`; only the App form carries the plugin.
if grep -qF "app = build_app(" "$TMP/adk_agents/loop_spec/agent.py" 2>/dev/null; then
  PASS=$((PASS+1)); echo "PASS: generated shim exposes an App"
else
  FAIL=$((FAIL+1)); echo "FAIL: generated shim does not expose an App"
fi
if grep -qF "readonly=True" "$TMP/adk_agents/loop_spec_readonly/agent.py" 2>/dev/null; then
  PASS=$((PASS+1)); echo "PASS: read-only shim builds the read-only agent"
else
  FAIL=$((FAIL+1)); echo "FAIL: read-only shim does not request readonly"
fi
# check must catch a mount whose package root moved out from under it.
sed -i.bak 's|^_PACKAGE_PATH = r".*"$|_PACKAGE_PATH = r"/nonexistent/loop-spec/extensions/adk"|' \
  "$TMP/adk_agents/loop_spec/agent.py"
if bash lib/adk-install.sh check --project "$TMP" >/dev/null 2>&1; then
  FAIL=$((FAIL+1)); echo "FAIL: adk-install check passed a shim pointing at a missing package"
else
  PASS=$((PASS+1)); echo "PASS: adk-install check catches a moved package root"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
