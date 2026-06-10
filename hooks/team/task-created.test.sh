#!/usr/bin/env bash
# Test suite for hooks/team/task-created.sh
# PreToolUse (TaskCreate) hook: schema validation on task creation.
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

# Build a TaskCreate payload with given metadata JSON string
payload_with_metadata() {
  local metadata="$1"
  printf '{"tool_name":"TaskCreate","tool_input":{"metadata":%s}}' "$metadata"
}

VALID_META='{"blockedBy":[],"files":["foo.sh"],"verifyCommand":"bash t.sh","acceptanceCriteria":["works"]}'

echo "=== task-created.sh tests ==="

# a: all four fields present and valid -> ALLOW (exit 0)
check "a: all required fields present ALLOW" 0 \
  "$(payload_with_metadata "$VALID_META")"

# b: empty metadata {} -> DENY (exit 2)
check "b: empty metadata DENY" 2 \
  "$(payload_with_metadata '{}')"

# c: missing verifyCommand -> DENY (exit 2)
MISSING_VERIFY='{"blockedBy":[],"files":["foo.sh"],"acceptanceCriteria":["works"]}'
check "c: missing verifyCommand DENY" 2 \
  "$(payload_with_metadata "$MISSING_VERIFY")"

# d: empty acceptanceCriteria array -> DENY (exit 2)
EMPTY_AC='{"blockedBy":[],"files":["foo.sh"],"verifyCommand":"bash t.sh","acceptanceCriteria":[]}'
check "d: empty acceptanceCriteria array DENY" 2 \
  "$(payload_with_metadata "$EMPTY_AC")"

# e: missing blockedBy -> DENY (exit 2)
MISSING_BLOCKED_BY='{"files":["foo.sh"],"verifyCommand":"bash t.sh","acceptanceCriteria":["works"]}'
check "e: missing blockedBy DENY" 2 \
  "$(payload_with_metadata "$MISSING_BLOCKED_BY")"

# f: missing files -> DENY (exit 2)
MISSING_FILES='{"blockedBy":[],"verifyCommand":"bash t.sh","acceptanceCriteria":["works"]}'
check "f: missing files DENY" 2 \
  "$(payload_with_metadata "$MISSING_FILES")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
