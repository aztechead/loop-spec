#!/usr/bin/env bash
# opencode-harness coverage: the opencode adaptation is a web of cross-file
# couplings (harness probe -> capability gates -> native task/skill/question
# mapping -> installer -> loop-runner backend). A rename or dropped pointer on
# any edge silently strands opencode runs on a tool or path that does not
# exist there. This pins every edge, mirroring tests/pi-harness-coverage.test.sh.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fixed-string-coverage.sh"

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
  "skills/shared/opencode-harness.md	task_id"
  "skills/shared/opencode-harness.md	task_id?, command?"
  "skills/shared/opencode-harness.md	OPENCODE_EXPERIMENTAL_BACKGROUND_SUBAGENTS"
  "skills/shared/opencode-harness.md	question"
  "skills/shared/opencode-harness.md	multiSelect"
  "skills/shared/opencode-harness.md	multiple"
  "skills/shared/opencode-harness.md	providerID"
  "skills/shared/opencode-harness.md	modelID"
  "skills/shared/opencode-harness.md	executionRootMode: \"in-place\""
  "skills/shared/opencode-harness.md	lib/pr-delivery.sh"
  "skills/shared/opencode-harness.md	does not pretend worktree creation changed cwd"
  "skills/shared/opencode-harness.md	--model adversarial=github-copilot/"
  "skills/shared/opencode-harness.md	LOOP_SPEC_PHASE_MODEL_*"
  "lib/opencode-install.sh	modelRoutes"
  # -- the harness probe knows opencode and grants the subagent capability
  "lib/harness.sh	opencode"
  "lib/execute-rung.sh	harness.sh"
  # -- capability gates are non-claude-gated (the bash side of the contract)
  "lib/teams-capability.sh	!= \"claude\""
  "lib/workflow-availability.sh	!= \"claude\""
  # -- dispatch docs route opencode through the native task tool
  "skills/shared/dispatch.md	opencode-harness.md"
  "skills/cycle/SKILL.md	opencode-harness.md"
  "skills/shared/tier-matrix.md	opencode-harness.md"
  # -- tool-contract doc carries the opencode surface
  "skills/shared/dispatch.md	opencode harness"
  "skills/shared/dispatch.md	opencode-harness.md"
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
  "skills/shared/opencode-harness.md	Graph engine (GDD)"
  "skills/shared/opencode-harness.md	lib/graph/run.sh"
  "lib/graph/run.sh	harness-neutral"
  "lib/graph/engine.py	harness-neutral"
)

check_fixed_strings "${checks[@]}"


# lib/graph must not branch on harness-specific constructs
while IFS= read -r f; do
  if grep -nE 'CLAUDE_CODE_ENTRYPOINT|opencode run|pi --mode|LOOP_SPEC_HARNESS=' "$f"       | grep -vE 'harness-neutral|lib/harness|#|never branches' >/dev/null; then
    FAIL=$((FAIL+1)); echo "FAIL: $f references a harness-specific construct"
  else
    PASS=$((PASS+1)); echo "PASS: $f harness-neutral"
  fi
done < <(find lib/graph -type f \( -name '*.sh' -o -name '*.py' \) 2>/dev/null)

# The OpenCode install generates an ADAPTER at <config>/skills/loop-spec-<name>/;
# its `../../lib` does not exist. A live cycle died here: the model followed an
# unconditional "export CLAUDE_SKILL_DIR yourself" instruction, clobbered the
# correct plugin-provided path with the adapter directory, then hunted the user's
# home directory for lib/ and was permission-denied. The fallback must only ever
# fill an EMPTY value.
OC_DOC="skills/shared/opencode-harness.md"
if grep -qE '^export CLAUDE_SKILL_DIR=' "$OC_DOC"; then
  FAIL=$((FAIL+1)); echo "FAIL: $OC_DOC tells the model to overwrite CLAUDE_SKILL_DIR unconditionally"
else
  PASS=$((PASS+1)); echo "PASS: $OC_DOC never overwrites CLAUDE_SKILL_DIR unconditionally"
fi
if grep -qF ': "${CLAUDE_SKILL_DIR:=' "$OC_DOC"; then
  PASS=$((PASS+1)); echo "PASS: $OC_DOC assigns CLAUDE_SKILL_DIR only when empty"
else
  FAIL=$((FAIL+1)); echo "FAIL: $OC_DOC lost the assign-only-when-empty fallback"
fi

# Same live run, next failure: SPEC read its own artifact templates with the
# `read` tool. The package sits outside the project in a symlink install, so
# opencode asked external_directory permission and headless auto-rejected it --
# while `bash cat` on the identical path succeeds.
if grep -qF 'external_directory' "$OC_DOC"; then
  PASS=$((PASS+1)); echo "PASS: $OC_DOC records the external_directory read gate"
else
  FAIL=$((FAIL+1)); echo "FAIL: $OC_DOC does not warn that reading package files needs bash"
fi

finish_fixed_string_coverage
