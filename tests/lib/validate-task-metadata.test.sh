#!/usr/bin/env bash
# Tests for lib/validate-task-metadata.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/lib/validate-task-metadata.sh"

PASS=0
FAIL=0

check() {
  local name="$1"
  local expected_exit="$2"
  local metadata="$3"
  local actual_exit=0
  bash "$SCRIPT" "$metadata" >/dev/null 2>&1 || actual_exit=$?
  if [[ "$actual_exit" -eq "$expected_exit" ]]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected exit $expected_exit, got $actual_exit)"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== validate-task-metadata.sh tests ==="

VALID='{"blockedBy":[],"files":["foo.sh"],"verifyCommand":"bash t.sh","acceptanceCriteria":["works"]}'
check "A: valid metadata ALLOW" 0 "$VALID"

check "B: missing blockedBy DENY" 2 \
  '{"files":["foo.sh"],"verifyCommand":"bash t.sh","acceptanceCriteria":["works"]}'

check "C: missing files DENY" 2 \
  '{"blockedBy":[],"verifyCommand":"bash t.sh","acceptanceCriteria":["works"]}'

check "D: missing verifyCommand DENY" 2 \
  '{"blockedBy":[],"files":["foo.sh"],"acceptanceCriteria":["works"]}'

check "E: missing acceptanceCriteria DENY" 2 \
  '{"blockedBy":[],"files":["foo.sh"],"verifyCommand":"bash t.sh"}'

check "F: empty verifyCommand DENY" 2 \
  '{"blockedBy":[],"files":["foo.sh"],"verifyCommand":"","acceptanceCriteria":["works"]}'

check "G: whitespace-only verifyCommand DENY" 2 \
  '{"blockedBy":[],"files":["foo.sh"],"verifyCommand":"   ","acceptanceCriteria":["works"]}'

check "H: empty acceptanceCriteria DENY" 2 \
  '{"blockedBy":[],"files":["foo.sh"],"verifyCommand":"bash t.sh","acceptanceCriteria":[]}'

check "I: verifyCommand is not string DENY" 2 \
  '{"blockedBy":[],"files":["foo.sh"],"verifyCommand":123,"acceptanceCriteria":["works"]}'

check "J: acceptanceCriteria is not array DENY" 2 \
  '{"blockedBy":[],"files":["foo.sh"],"verifyCommand":"bash t.sh","acceptanceCriteria":"works"}'

check "K: blockedBy is not array DENY" 2 \
  '{"blockedBy":"task-001","files":["foo.sh"],"verifyCommand":"bash t.sh","acceptanceCriteria":["works"]}'

check "L: invalid JSON DENY" 2 '{not valid json'

check "M: metadata is not an object DENY" 2 '"a string"'

# Special-case test for no-argument invocation: cannot use check() helper because
# it always passes a third arg. Test directly.
no_arg_exit=0
bash "$SCRIPT" >/dev/null 2>&1 || no_arg_exit=$?
if [[ "$no_arg_exit" -eq 1 ]]; then
  echo "PASS: N: no argument exit 1"
  PASS=$((PASS + 1))
else
  echo "FAIL: N: no argument exit 1 (expected exit 1, got $no_arg_exit)"
  FAIL=$((FAIL + 1))
fi

# New optional field test cases (task-003)

check "O: userGate + failurePolicy + gateScope present ALLOW" 0 \
  '{"blockedBy":[],"files":["foo.sh"],"verifyCommand":"bash t.sh","acceptanceCriteria":["works"],"userGate":true,"failurePolicy":"stop-plan","gateScope":"once"}'

check "P: requiresUserSpecification + requireEvidenceTokens present ALLOW" 0 \
  '{"blockedBy":[],"files":["foo.sh"],"verifyCommand":"bash t.sh","acceptanceCriteria":["works"],"requiresUserSpecification":true,"requireEvidenceTokens":[["AC:","PROVEN BY"]]}'

check "Q: requireABCompare + subagentType + dispatchBrief + model present ALLOW" 0 \
  '{"blockedBy":[],"files":["foo.sh"],"verifyCommand":"bash t.sh","acceptanceCriteria":["works"],"requireABCompare":false,"subagentType":"checker","dispatchBrief":"run tests","model":"sonnet"}'

check "R: all 9 new optional fields absent from valid payload ALLOW" 0 \
  '{"blockedBy":[],"files":["foo.sh"],"verifyCommand":"bash t.sh","acceptanceCriteria":["works"]}'

check "S: invalid failurePolicy value DENY" 2 \
  '{"blockedBy":[],"files":["foo.sh"],"verifyCommand":"bash t.sh","acceptanceCriteria":["works"],"failurePolicy":"bogus"}'

check "T: repo present as valid string ALLOW" 0 \
  '{"blockedBy":[],"files":["foo.sh"],"verifyCommand":"bash t.sh","acceptanceCriteria":["works"],"repo":"frontend"}'

check "U: repo absent ALLOW" 0 \
  '{"blockedBy":[],"files":["foo.sh"],"verifyCommand":"bash t.sh","acceptanceCriteria":["works"]}'

check "V: repo present as number DENY" 2 \
  '{"blockedBy":[],"files":["foo.sh"],"verifyCommand":"bash t.sh","acceptanceCriteria":["works"],"repo":42}'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
