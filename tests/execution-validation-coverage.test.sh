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

# VERIFY is where it runs, and the only place — including resume.
check_contains "VERIFY runs the comparison" \
  skills/verify/references/pre-team-gates.md 'lib/feature-validation.sh" compare'
check_not_contains "cycle resume does not run the comparison" \
  skills/cycle/SKILL.md 'feature-validation.sh'
check_contains "cycle resume names VERIFY as the only suite" \
  skills/cycle/SKILL.md 'VERIFY Step 1.75 is the only place'
check_contains "cycle resume prints remaining task ids" \
  skills/cycle/SKILL.md 'task-progress.sh" remaining'
check_contains "EXECUTE seeds mergedSet from done ids" \
  skills/execute/references/conflicts.md 'task-progress.sh" done'
check_contains "EXECUTE persists mark-done" \
  skills/execute/references/conflicts.md 'task-progress.sh" mark-done'
check_contains "subagent protocol persists mark-done" \
  skills/shared/execute-subagent.md 'task-progress.sh" mark-done'
check_contains "inline protocol persists mark-done" \
  skills/shared/execute-inline.md 'task-progress.sh" mark-done'
check_contains "team protocol persists mark-done" \
  skills/execute/references/team-rung-protocol.md 'task-progress.sh" mark-done'
check_contains "workflow DAG persists mark-done" \
  lib/workflows/execute-dag.js 'task-progress.sh'
check_contains "workflow DAG seeds doneTaskIds" \
  lib/workflows/execute-dag.js 'doneTaskIds'
check_contains "loop-fleet passes the sidecar" \
  skills/shared/execute-loop-fleet.md '--tasks-json'
check_contains "supervisor accepts the sidecar" \
  skills/loop-runner/scripts/supervisor.py '--tasks-json'
check_contains "resume reference picks up remaining ids" \
  skills/shared/cycle-resume-escalation.md 'task-progress.sh remaining'

# Startup must not pay for a repository-wide suite on the untouched base. The capture
# survives only as an opt-in for repositories whose base commit is already red.
check_contains "startup baseline capture is opt-in" \
  lib/feature-bootstrap.sh 'if [[ "${LOOP_SPEC_STARTUP_BASELINE:-0}" == "1" && "${greenfield:-0}" != "1" ]]; then'
check_contains "workspace prepare/baseline uses the shared bootstrap" \
  skills/cycle/references/workspace-mode.md 'feature-bootstrap.sh" prepare-repo'
check_contains "the opt-in is documented" \
  docs/loop-spec/configuration.md '`LOOP_SPEC_STARTUP_BASELINE`'

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
