#!/usr/bin/env bash
# pi-harness coverage: the pi adaptation is a web of cross-file couplings
# (harness probe -> capability gates -> rung selection -> inline path -> shared
# substitution rules). A rename or dropped pointer on any edge silently strands
# pi runs on a tool that does not exist there. This pins every edge, mirroring
# tests/contract-strings.test.sh.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
PASS=0
FAIL=0

# file<TAB>fixed-string that must be present.
checks=(
  # -- the adaptation contract exists and names its collaborators
  "skills/shared/pi-harness.md	lib/harness.sh"
  "skills/shared/pi-harness.md	execute-inline.md"
  "skills/shared/pi-harness.md	execute-loop-fleet.md"
  "skills/shared/pi-harness.md	autonomous-mode.md"
  "skills/shared/pi-harness.md	--agent-cli pi"
  "skills/shared/pi-harness.md	pi install git:github.com/aztechead/loop-spec"
  "skills/shared/pi-harness.md	executionRootMode: \"in-place\""
  "skills/shared/pi-harness.md	lib/deliver.sh"
  "skills/shared/pi-harness.md	graphify install --platform pi"
  "skills/shared/pi-harness.md	discovered external graphify skill"
  "skills/shared/pi-harness.md	graphify-lifecycle.md"
  # -- EXECUTE ladder: harness probe + rung 0 + its reference
  "skills/execute/SKILL.md	lib/harness.sh"
  "skills/execute/SKILL.md	rung = \"inline\""
  "skills/execute/SKILL.md	skills/shared/execute-inline.md"
  # -- inline path keeps the shared result vocabulary (consumed by Step 3b-exit)
  "skills/shared/execute-inline.md	retry-exhausted"
  "skills/shared/execute-inline.md	spec-compliance-block"
  "skills/shared/execute-inline.md	commit-missing"
  "skills/shared/execute-inline.md	deadlock"
  "skills/shared/execute-inline.md	lib/harness.sh"
  # -- ladder doc names the rung
  "skills/shared/tier-matrix.md	execute-inline.md"
  "skills/shared/tier-matrix.md	lib/harness.sh cli"
  # -- dispatch fallbacks route pi one level further down
  "skills/shared/no-teams-fallback.md	pi-harness.md"
  "skills/cycle/SKILL.md	pi-harness.md"
  # -- startup probes: skip model probe, persist harness
  "skills/cycle/references/startup-probes.md	pi harness: skip this probe"
  "skills/cycle/references/startup-probes.md	data['harness']"
  # -- tool-contract doc carries the pi surface
  "skills/shared/harness-call-contracts.md	pi harness"
  "skills/shared/harness-call-contracts.md	pi-harness.md"
  # -- headless parity documented for autonomous mode + models
  "skills/shared/autonomous-mode.md	pi --mode json"
  "skills/shared/pi-harness.md	/skill:auto"
  "skills/auto/SKILL.md	Skill(loop-spec:micro)"
  "skills/shared/model-matrix.md	pi-harness.md"
  # -- the one-shot command adapts too
  "commands/loop-debug.md	pi-harness.md"
  # -- unattended sentinel recipes document both headless CLIs (same seam as
  #    lib/issue-intake.sh: lib/harness.sh cli)
  "docs/loop-spec/sentinel.md	pi --mode json \"/skill:sentinel run\""
  "docs/loop-spec/sentinel.md	lib/harness.sh cli"
  # -- micro mode: the SessionStart directive is bridged to pi (the Stop-time
  #    adhoc-verify-guard is CC-only; pi has no blocking stop event)
  "extensions/pi/loop-spec.ts	micro-inject.sh"
  # -- capability scripts are pi-gated (the bash side of the same contract)
  "lib/teams-capability.sh	harness.sh"
  "lib/workflow-availability.sh	harness.sh"
  "lib/cycle-preflight.sh	harness.sh"
  # -- loop-runner: the headless pi backend and its plumbing
  "skills/loop-runner/scripts/loop.py	def run_pi"
  "skills/loop-runner/scripts/loop.py	--agent-cli"
  "skills/loop-runner/scripts/supervisor.py	agent_cli"
  "skills/loop-runner/scripts/compile_spec.py	agent_cli"
  "skills/loop-runner/SKILL.md	--agent-cli pi"
  "skills/shared/execute-loop-fleet.md	--agent-cli pi"
  "skills/loop-runner/tests/fakepi	message_end"
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
