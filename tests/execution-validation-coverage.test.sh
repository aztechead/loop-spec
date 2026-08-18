#!/usr/bin/env bash
# The repository-wide test/lint/typecheck comparison runs ONCE per cycle, at VERIFY.
#
# EXECUTE used to run it again at every wave/merge-queue boundary on all four rungs, so
# a run paid one full suite per wave PLUS the one VERIFY runs against the same integrated
# tree moments later -- the single largest fixed cost in a short cycle, and duplicated
# work by construction. Each task still runs its own focused `verifyCommand` after any
# rebase; that is the only command EXECUTE executes.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
PASS=0
FAIL=0

check_contains() {
  local name="$1" file="$2" needle="$3"
  if grep -Fq -- "$needle" "$file"; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (missing '$needle' in $file)"; FAIL=$((FAIL + 1))
  fi
}

check_not_contains() {
  local name="$1" file="$2" needle="$3"
  if grep -Fq -- "$needle" "$file"; then
    echo "FAIL: $name (unexpected '$needle' in $file)"; FAIL=$((FAIL + 1))
  else
    echo "PASS: $name"; PASS=$((PASS + 1))
  fi
}

# Each rung still runs the task's own focused proof.
check_contains "subagent integration reruns focused proof" \
  skills/shared/execute-subagent.md '--verify "{task.verifyCommand}"'
check_contains "team integration reruns focused proof" \
  skills/execute/references/team-rung-protocol.md '--verify "{task.metadata.verifyCommand}"'
check_contains "workflow integration uses focused candidateVerify" \
  lib/workflows/execute-dag.js "const candidateVerify = byId[p.taskId].verifyCommand || 'true'"

# No rung runs the repository-wide comparison. One name per rung, checked by file,
# because each rung reintroduces it in its own vocabulary.
for f in \
  skills/shared/execute-subagent.md \
  skills/shared/execute-inline.md \
  skills/shared/execute-loop-fleet.md \
  skills/execute/references/team-rung-protocol.md \
  lib/workflows/execute-dag.js \
  skills/loop-runner/scripts/supervisor.py
do
  check_not_contains "no repository-wide comparison in $(basename "$f")" \
    "$f" 'feature-validation.sh'
done

# VERIFY is where it runs, and the only place.
check_contains "VERIFY runs the comparison" \
  skills/verify/SKILL.md 'lib/feature-validation.sh" compare'

# Startup must not pay for a repository-wide suite on the untouched base. The capture
# survives only as an opt-in for repositories whose base commit is already red.
check_contains "startup baseline capture is opt-in" \
  skills/cycle/SKILL.md 'if [[ "${LOOP_SPEC_STARTUP_BASELINE:-0}" == "1" && "${greenfield:-0}" != "1" ]]; then'
check_contains "workspace startup baseline capture is opt-in" \
  skills/cycle/references/workspace-mode.md '[[ "${LOOP_SPEC_STARTUP_BASELINE:-0}" == "1" ]] || continue'
check_contains "the opt-in is documented" \
  docs/loop-spec/configuration.md '`LOOP_SPEC_STARTUP_BASELINE`'

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
