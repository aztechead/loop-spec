#!/usr/bin/env bash
# opencode-harness coverage: the opencode adaptation is a web of cross-file
# couplings (harness probe -> capability gates -> native task/skill/question
# mapping -> installer -> loop-runner backend). A rename or dropped pointer on
# any edge silently strands opencode runs on a tool or path that does not
# exist there. This pins every edge, mirroring tests/pi-harness-coverage.test.sh.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
PASS=0
FAIL=0

# file<TAB>fixed-string that must be present.
checks=(
  # -- the adaptation contract exists and names its collaborators
  "skills/shared/opencode-harness.md	lib/harness.sh"
  "skills/shared/opencode-harness.md	execute-loop-fleet.md"
  "skills/shared/opencode-harness.md	autonomous-mode.md"
  "skills/shared/opencode-harness.md	--agent-cli opencode"
  "skills/shared/opencode-harness.md	lib/opencode-install.sh"
  "skills/shared/opencode-harness.md	loop-spec-<role>"
  "skills/shared/opencode-harness.md	subagent_type"
  "skills/shared/opencode-harness.md	question"
  "skills/shared/opencode-harness.md	multiSelect"
  "skills/shared/opencode-harness.md	multiple"
  "skills/shared/opencode-harness.md	providerID"
  "skills/shared/opencode-harness.md	modelID"
  "skills/shared/opencode-harness.md	executionRootMode: \"in-place\""
  "skills/shared/opencode-harness.md	lib/pr-delivery.sh"
  "skills/shared/opencode-harness.md	does not pretend worktree creation changed cwd"
  "skills/shared/opencode-harness.md	graphify install --platform opencode"
  "skills/shared/opencode-harness.md	skill({name: \"graphify\"})"
  "skills/shared/opencode-harness.md	graphify-lifecycle.md"
  "skills/shared/opencode-harness.md	--model adversarial=github-copilot/"
  "lib/opencode-install.sh	modelRoutes"
  # -- the harness probe knows opencode and grants the subagent capability
  "lib/harness.sh	opencode"
  # -- capability gates are non-claude-gated (the bash side of the contract)
  "lib/teams-capability.sh	!= \"claude\""
  "lib/workflow-availability.sh	!= \"claude\""
  # -- dispatch docs route opencode through the native task tool
  "skills/shared/no-teams-fallback.md	opencode-harness.md"
  "skills/cycle/SKILL.md	opencode-harness.md"
  "skills/shared/tier-matrix.md	opencode-harness.md"
  # -- startup probes: skip model probe under opencode too
  "skills/cycle/references/startup-probes.md	opencode-harness.md"
  # -- tool-contract doc carries the opencode surface
  "skills/shared/harness-call-contracts.md	opencode harness"
  "skills/shared/harness-call-contracts.md	opencode-harness.md"
  # -- headless parity documented for autonomous mode + models
  "skills/shared/autonomous-mode.md	opencode run --format json"
  "skills/shared/opencode-harness.md	loop-spec-auto"
  "skills/auto/SKILL.md	Skill(loop-spec:debug)"
  "skills/shared/model-matrix.md	opencode-harness.md"
  # -- the one-shot command adapts too
  "commands/loop-debug.md	opencode-harness.md"
  # -- unattended recipes document the opencode headless CLI (same seam as
  #    lib/issue-intake.sh: lib/harness.sh cli)
  "docs/loop-spec/sentinel.md	opencode run --format json"
  "lib/issue-intake.sh	run --format json"
  # -- the bridge plugin: native hooks + the same SessionStart scripts
  "extensions/opencode/loop-spec.ts	shell.env"
  "extensions/opencode/loop-spec.ts	micro-inject.sh"
  "extensions/opencode/loop-spec.ts	LOOP_SPEC_HARNESS"
  "skills/shared/opencode-harness.md	directive-only"
  # -- installer places every native surface and is documented by the contract
  "lib/opencode-install.sh	extensions/opencode/loop-spec.ts"
  "lib/opencode-install.sh	commands/loop-debug.md"
  "lib/opencode-install.sh	loop-spec-install.json"
  # -- skill command wrappers: the TUI hides skill-sourced slash entries, so
  #    the installer must generate /loop-spec/<name> commands and the contract
  #    must tell users that is the invocation surface
  "lib/opencode-install.sh	commands/loop-spec/"
  "skills/shared/opencode-harness.md	/loop-spec/<name>"
  # -- loop-runner: the headless opencode backend and its plumbing
  "skills/loop-runner/scripts/loop.py	def run_opencode"
  "skills/loop-runner/scripts/loop.py	opencode"
  "skills/loop-runner/scripts/supervisor.py	opencode"
  "skills/loop-runner/scripts/compile_spec.py	opencode"
  "skills/loop-runner/SKILL.md	--agent-cli opencode"
  "skills/shared/execute-loop-fleet.md	--agent-cli opencode"
  "skills/loop-runner/tests/fakeopencode	step_finish"
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

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
