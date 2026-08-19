#!/usr/bin/env bash
# adk-harness coverage: the ADK adaptation is a web of cross-file couplings
# (harness probe -> capability gates -> dispatch/skill mapping -> installer ->
# loop-runner backend). A rename or dropped pointer on any edge silently strands
# ADK runs on a tool or path that does not exist there. This pins every edge,
# mirroring tests/opencode-harness-coverage.test.sh.
#
# It also guards the removal: pi is gone, and a reference that survives points
# at a harness with no contract, no backend, and no extension.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fixed-string-coverage.sh"

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
  "skills/shared/adk-harness.md	--session_id"
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
  "extensions/adk/loop_spec_adk/bridge.py	SESSION_START_HOOKS"
  "extensions/adk/loop_spec_adk/bridge.py	LocalEnvironment"
  "extensions/adk/loop_spec_adk/plugin.py	load_skill"
  "extensions/adk/loop_spec_adk/plugin.py	loop_spec:session_started"
  "extensions/adk/loop_spec_adk/plugin.py	on_user_message_callback"
  "extensions/adk/loop_spec_adk/agent.py	AgentTool"
  "extensions/adk/loop_spec_adk/agent.py	dispatch_subagent"
  "skills/shared/adk-harness.md	model?"
  "extensions/adk/loop_spec_adk/agent.py	model: str = \"\""
  "extensions/adk/loop_spec_adk/agent.py	get_user_choice"
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

check_fixed_strings "${checks[@]}"

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

# -- pi is gone: no tracked active contract may still reference it. Use git's
# tracked corpus so local __pycache__ and other generated files cannot make this
# guard fail. claude-harness.md owns one explicit migration note saying that the
# old harness was removed; it is history, not an active contract.
pi_hits="$(git grep -n -i -E '(^|[^[:alnum:]_])pi([^[:alnum:]_]|$)|fakepi|PI_CODING|extensions/pi|pi-harness|/skill:' \
             -- README.md REVIEW-ORDER.md CLAUDE.md docs/adopting.md \
                docs/loop-spec/PREREQUISITES.md skills lib hooks agents commands extensions \
             2>/dev/null | grep -v '^skills/shared/claude-harness.md:' \
             | grep -v 'retired-harness-diagnostic' || true)"
if [[ -z "$pi_hits" ]]; then
  PASS=$((PASS+1)); echo "PASS: no tracked active contract references the removed pi harness"
else
  FAIL=$((FAIL+1)); echo "FAIL: active pi references survive in:"; echo "$pi_hits" | sed 's/^/    /'
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
ADK_STUB="$TMP/adk-stub"
mkdir -p "$ADK_STUB/google/adk" "$ADK_STUB/google_adk-2.7.0.dist-info"
printf '' > "$ADK_STUB/google/__init__.py"
printf '' > "$ADK_STUB/google/adk/__init__.py"
printf 'Metadata-Version: 2.1\nName: google-adk\nVersion: 2.7.0\n' \
  > "$ADK_STUB/google_adk-2.7.0.dist-info/METADATA"
export PYTHONPATH="$ADK_STUB${PYTHONPATH:+:$PYTHONPATH}"
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
if [[ "$(jq -r '.adkRequirement' "$TMP/.loop-spec/adk-install.json")" == ">=2.7,<3" \
   && "$(jq -r '.adkVersion' "$TMP/.loop-spec/adk-install.json")" == "2.7.0" ]]; then
  PASS=$((PASS+1)); echo "PASS: installer records the enforced ADK contract"
else
  FAIL=$((FAIL+1)); echo "FAIL: installer did not record the ADK contract"
fi
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

# Both install and check reject versions outside the supported major/minor range.
sed -i.bak 's/Version: 2.7.0/Version: 2.6.9/' \
  "$ADK_STUB/google_adk-2.7.0.dist-info/METADATA"
OUT_OF_RANGE="$TMP/out-of-range"
mkdir -p "$OUT_OF_RANGE"
if bash lib/adk-install.sh install --project "$OUT_OF_RANGE" >/dev/null 2>&1 \
   || [[ -e "$OUT_OF_RANGE/adk_agents/loop_spec/agent.py" ]]; then
  FAIL=$((FAIL+1)); echo "FAIL: installer accepted google-adk below 2.7"
else
  PASS=$((PASS+1)); echo "PASS: installer rejects google-adk below 2.7"
fi
sed -i.bak 's/Version: 2.6.9/Version: 3.0.0/' \
  "$ADK_STUB/google_adk-2.7.0.dist-info/METADATA"
if bash lib/adk-install.sh check --project "$TMP" >/dev/null 2>&1; then
  FAIL=$((FAIL+1)); echo "FAIL: installer check accepted google-adk 3.x"
else
  PASS=$((PASS+1)); echo "PASS: installer check rejects google-adk 3.x"
fi
sed -i.bak 's/Version: 3.0.0/Version: 2.7.0/' \
  "$ADK_STUB/google_adk-2.7.0.dist-info/METADATA"
# check must catch a mount whose package root moved out from under it.
sed -i.bak "s|^_PACKAGE_PATH = .*$|_PACKAGE_PATH = '/nonexistent/loop-spec/extensions/adk'|" \
  "$TMP/adk_agents/loop_spec/agent.py"
if bash lib/adk-install.sh check --project "$TMP" >/dev/null 2>&1; then
  FAIL=$((FAIL+1)); echo "FAIL: adk-install check passed a shim pointing at a missing package"
else
  PASS=$((PASS+1)); echo "PASS: adk-install check catches a moved package root"
fi

# Mounts cannot escape the project, and existing user files are never clobbered.
if bash lib/adk-install.sh install --project "$TMP" --mount ../escaped >/dev/null 2>&1; then
  FAIL=$((FAIL+1)); echo "FAIL: installer accepted a mount outside the project"
else
  PASS=$((PASS+1)); echo "PASS: installer rejects mount traversal"
fi
COLLISION="$TMP/collision/loop_spec"
mkdir -p "$COLLISION"
echo "user owned" > "$COLLISION/agent.py"
if bash lib/adk-install.sh install --project "$TMP" --mount collision >/dev/null 2>&1; then
  FAIL=$((FAIL+1)); echo "FAIL: installer overwrote an existing agent.py"
elif grep -qF "user owned" "$COLLISION/agent.py"; then
  PASS=$((PASS+1)); echo "PASS: installer preserves existing agent.py"
else
  FAIL=$((FAIL+1)); echo "FAIL: installer damaged existing agent.py"
fi

# Values are serialized as Python literals, so quotes in a configured model do
# not corrupt or inject into the generated shim.
QUOTED="$TMP/quoted"
mkdir -p "$QUOTED"
if bash lib/adk-install.sh install --project "$QUOTED" --model "gemini-'quoted" >/dev/null 2>&1 \
   && python3 -m py_compile "$QUOTED/adk_agents/loop_spec/agent.py"; then
  PASS=$((PASS+1)); echo "PASS: installer safely quotes generated Python values"
else
  FAIL=$((FAIL+1)); echo "FAIL: quoted model produced an invalid shim"
fi

# Uninstall removes only marked generated files. Anything else in the mount is
# preserved and makes the incomplete uninstall visible to the caller.
bash lib/adk-install.sh install --project "$QUOTED" >/dev/null 2>&1
echo "keep me" > "$QUOTED/adk_agents/loop_spec/notes.txt"
if bash lib/adk-install.sh uninstall --project "$QUOTED" >/dev/null 2>&1; then
  FAIL=$((FAIL+1)); echo "FAIL: uninstall claimed complete with unrelated files present"
elif [[ -f "$QUOTED/adk_agents/loop_spec/notes.txt" \
        && ! -e "$QUOTED/adk_agents/loop_spec/agent.py" ]]; then
  PASS=$((PASS+1)); echo "PASS: uninstall preserves unrelated mount content"
else
  FAIL=$((FAIL+1)); echo "FAIL: uninstall removed unrelated mount content"
fi

finish_fixed_string_coverage
