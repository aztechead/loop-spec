#!/usr/bin/env bash
# Keep the expensive repository-wide comparison at the integrated-wave boundary.
# Per-task integration may only rerun its focused task proof; otherwise a width-N
# wave silently becomes N full suites plus VERIFY's mandatory full suite.
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

check_contains "subagent integration reruns focused proof" \
  skills/shared/execute-subagent.md '--verify "{task.verifyCommand}"'
check_contains "subagent has post-wave candidate gate" \
  skills/shared/execute-subagent.md 'Post-wave candidate suite gate'
check_contains "team integration reruns focused proof" \
  skills/execute/references/team-rung-protocol.md '--verify "{task.metadata.verifyCommand}"'
check_contains "team has post-queue candidate gate" \
  skills/execute/references/team-rung-protocol.md 'Post-merge-queue suite gate'
check_contains "workflow integration uses focused candidateVerify" \
  lib/workflows/execute-dag.js "const candidateVerify = byId[p.taskId].verifyCommand || 'true'"
check_contains "workflow has one post-wave candidate gate" \
  lib/workflows/execute-dag.js 'repository-wide candidate gate ONCE'
check_not_contains "workflow no longer appends full suite to every task proof" \
  lib/workflows/execute-dag.js '&& bash ${shellQuote(`${skillDir}/../../lib/feature-validation.sh`)}'

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
