#!/usr/bin/env bash
# Codex harness coverage: the Codex adaptation is a web of cross-file
# couplings (harness probe -> capability gates -> spawn_agent/skill mapping ->
# installer -> loop-runner backend). A rename or dropped pointer on any edge
# silently strands Codex runs on a tool or path that does not exist there.
# This pins every edge, mirroring tests/opencode-harness-coverage.test.sh and
# tests/adk-harness-coverage.test.sh.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fixed-string-coverage.sh"

# file<TAB>fixed-string that must be present.
checks=(
  # -- the adaptation contract exists and names its collaborators
  "skills/shared/codex-harness.md	lib/harness.sh"
  "skills/shared/codex-harness.md	execute-loop-fleet.md"
  "skills/shared/codex-harness.md	autonomous-mode.md"
  "skills/shared/codex-harness.md	--agent-cli codex"
  "skills/shared/codex-harness.md	lib/codex-install.sh"
  "skills/shared/codex-harness.md	spawn_agent"
  "skills/shared/codex-harness.md	subagent_type"
  "skills/shared/codex-harness.md	agent_type"
  "skills/shared/codex-harness.md	loop-spec-<role>"
  "skills/shared/codex-harness.md	executionRootMode: \"in-place\""
  "skills/shared/codex-harness.md	lib/pr-delivery.sh"
  "skills/shared/codex-harness.md	directive-only"
  "skills/shared/codex-harness.md	does not pretend worktree creation changed cwd"
  "skills/shared/codex-harness.md	shell_environment_policy.set"
  "skills/shared/codex-harness.md	codex exec --json"
  "skills/shared/codex-harness.md	loop-spec-auto"
  "skills/shared/codex-harness.md	loop-spec-readonly"
  "skills/shared/codex-harness.md	token"
  "skills/shared/codex-harness.md	Graph engine (GDD)"
  "skills/shared/codex-harness.md	lib/graph/run.sh"
  "skills/shared/codex-harness.md	LOOP_SPEC_PHASE_MODEL_*"
  # -- native plugin + marketplace
  ".codex-plugin/plugin.json	\"hooks\": \"./hooks/codex-hooks.json\""
  ".codex-plugin/plugin.json	\"skills\": \"./skills/\""
  ".agents/plugins/marketplace.json	\"path\": \"./\""
  "hooks/codex-hooks.json	codex-session-start.sh"
  "hooks/codex-hooks.json	codex-shell-env.sh"
  "hooks/codex-session-start.sh	SESSION_START_SCRIPTS"
  "hooks/codex-session-start.sh	LOOP_SPEC_HARNESS=codex"
  "hooks/codex-shell-env.sh	permissionDecision"
  "hooks/codex-shell-env.sh	updatedInput"
  # -- the harness probe knows codex and grants the subagent capability
  "lib/harness.sh	codex"
  "lib/harness.sh	claude|opencode|adk|codex"
  "lib/execute-rung.sh	harness.sh"
  # -- capability gates are non-claude-gated
  "lib/teams-capability.sh	!= \"claude\""
  "lib/workflow-availability.sh	!= \"claude\""
  # -- dispatch docs route Codex through spawn_agent
  "skills/shared/no-teams-fallback.md	codex-harness.md"
  "skills/cycle/SKILL.md	codex-harness.md"
  "skills/shared/tier-matrix.md	codex-harness.md"
  "skills/cycle/references/startup-probes.md	codex-harness.md"
  "skills/shared/harness-call-contracts.md	Codex harness"
  "skills/shared/harness-call-contracts.md	codex-harness.md"
  "skills/shared/autonomous-mode.md	codex exec --json"
  "skills/shared/model-matrix.md	codex-harness.md"
  "commands/loop-debug.md	codex-harness.md"
  "docs/loop-spec/sentinel.md	codex exec --json"
  "lib/issue-intake.sh	exec --json"
  # -- installer places agents, adapters, and env
  "lib/codex-install.sh	loop-spec-install.json"
  "lib/codex-install.sh	loop-spec-readonly"
  "lib/codex-install.sh	shell_environment_policy.set"
  "lib/codex-install.sh	.agents/skills"
  # -- loop-runner backend
  "skills/loop-runner/scripts/loop.py	def run_codex"
  "skills/loop-runner/scripts/loop.py	codex"
  "skills/loop-runner/scripts/supervisor.py	codex"
  "skills/loop-runner/scripts/compile_spec.py	codex"
  "skills/loop-runner/SKILL.md	--agent-cli codex"
  "skills/shared/execute-loop-fleet.md	--agent-cli codex"
  "skills/loop-runner/tests/fakecodex	thread.started"
  "skills/shared/graph-contract.md	codex-harness.md"
  "skills/shared/route-exit-contract.md	codex-harness.md"
  "lib/bump-version.sh	.codex-plugin/plugin.json"
  "lib/graph/run.sh	harness-neutral"
  "lib/graph/engine.py	harness-neutral"
)

check_fixed_strings "${checks[@]}"

probe() {
  got="$(LOOP_SPEC_HARNESS=codex bash lib/harness.sh "$3" 2>/dev/null)"
  if [[ "$got" == "$2" ]]; then
    PASS=$((PASS+1)); echo "PASS: harness.sh $3 under codex == '$2'"
  else
    FAIL=$((FAIL+1)); echo "FAIL: harness.sh $3 under codex == '$got', want '$2'"
  fi
}
probe "detect" "codex" detect
probe "cli" "codex" cli
probe "subagents" "true" subagents

for gate in "teams-capability.sh	none" "workflow-availability.sh	false"; do
  script="${gate%%	*}"; want="${gate#*	}"
  got="$(LOOP_SPEC_HARNESS=codex CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 \
         LOOP_SPEC_WORKFLOWS_AVAILABLE=1 LOOP_SPEC_TEAMS_MODE=implicit \
         bash "lib/$script" 2>/dev/null)"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS+1)); echo "PASS: lib/$script under codex == '$want' despite a positive override"
  else
    FAIL=$((FAIL+1)); echo "FAIL: lib/$script under codex == '$got', want '$want'"
  fi
done

CX_DOC="skills/shared/codex-harness.md"
if grep -qF 'export CLAUDE_SKILL_DIR=' "$CX_DOC"; then
  PASS=$((PASS+1)); echo "PASS: $CX_DOC re-exports the active source skill directory"
else
  FAIL=$((FAIL+1)); echo "FAIL: $CX_DOC lost the per-skill source-directory re-export"
fi
if grep -qF 'Before EVERY bundled script' lib/codex-install.sh; then
  PASS=$((PASS+1)); echo "PASS: generated adapters re-export before every bundled command"
else
  FAIL=$((FAIL+1)); echo "FAIL: generated adapters do not scope CLAUDE_SKILL_DIR per command"
fi

if jq -e '.hooks and .skills' .codex-plugin/plugin.json >/dev/null; then
  PASS=$((PASS+1)); echo "PASS: .codex-plugin/plugin.json names skills and hooks"
else
  FAIL=$((FAIL+1)); echo "FAIL: .codex-plugin/plugin.json missing skills or hooks"
fi

finish_fixed_string_coverage
