#!/usr/bin/env bash
# Test suite for hooks/team/task-created.sh
# PreToolUse (TaskCreate) hook: schema validation on loop-spec-owned tasks only.
# Usage: bash hooks/team/task-created.test.sh
set -euo pipefail

HOOK="$(dirname "$0")/task-created.sh"

PASS=0
FAIL=0

check() {
  local name="$1"
  local expected_exit="$2"
  local payload="$3"
  local actual_exit=0

  echo "$payload" | bash "$HOOK" >/dev/null 2>&1 || actual_exit=$?

  if [[ "$actual_exit" -eq "$expected_exit" ]]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name (expected exit $expected_exit, got $actual_exit)"
    ((FAIL++)) || true
  fi
}

# Build a TaskCreate payload with given subject + metadata JSON string
payload() {
  local subject="$1"
  local metadata="$2"
  printf '{"tool_name":"TaskCreate","tool_input":{"subject":"%s","metadata":%s}}' "$subject" "$metadata"
}

VALID_META='{"loopSpec":true,"blockedBy":[],"files":["foo.sh"],"verifyCommand":"bash t.sh","acceptanceCriteria":["works"]}'

echo "=== task-created.sh tests ==="

# a: marked task, all four fields present -> ALLOW (exit 0)
check "a: marked task with all required fields ALLOW" 0 \
  "$(payload 'task-001: add adder' "$VALID_META")"

# b: UNMARKED ordinary task with no metadata -> ALLOW (core task tracking must not break)
check "b: unmarked bare TaskCreate ALLOW" 0 \
  '{"tool_name":"TaskCreate","tool_input":{"subject":"Refactor the parser","description":"..."}}'

# c: unmarked task with partial metadata -> ALLOW (not loop-spec-owned)
check "c: unmarked task with unrelated metadata ALLOW" 0 \
  "$(payload 'Investigate flaky test' '{"priority":"high"}')"

# d: loopSpec marker with missing verifyCommand -> DENY (exit 2)
MISSING_VERIFY='{"loopSpec":true,"blockedBy":[],"files":["foo.sh"],"acceptanceCriteria":["works"]}'
check "d: marked task missing verifyCommand DENY" 2 \
  "$(payload 'task-002: x' "$MISSING_VERIFY")"

# e: subject convention task-NNN: marks the task even without loopSpec key -> DENY on empty metadata
check "e: task-NNN: subject convention enforced DENY" 2 \
  "$(payload 'task-003: y' '{}')"

# f: marked, empty acceptanceCriteria array -> DENY (exit 2)
EMPTY_AC='{"loopSpec":true,"blockedBy":[],"files":["foo.sh"],"verifyCommand":"bash t.sh","acceptanceCriteria":[]}'
check "f: marked task empty acceptanceCriteria DENY" 2 \
  "$(payload 'task-004: z' "$EMPTY_AC")"

# g: malformed JSON payload -> ALLOW (fail-open, never a hook error)
check "g: malformed payload fail-open ALLOW" 0 'this is not json'

# h: empty stdin -> ALLOW (fail-open)
check "h: empty stdin ALLOW" 0 ''

# i: kill switch LOOP_SPEC_TASK_GUARD=0 -> ALLOW even when invalid
actual_exit=0
echo "$(payload 'task-005: k' '{}')" | LOOP_SPEC_TASK_GUARD=0 bash "$HOOK" >/dev/null 2>&1 || actual_exit=$?
if [[ "$actual_exit" -eq 0 ]]; then
  echo "PASS: i: kill switch ALLOW"
  ((PASS++)) || true
else
  echo "FAIL: i: kill switch ALLOW (got $actual_exit)"
  ((FAIL++)) || true
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
