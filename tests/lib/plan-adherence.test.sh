#!/usr/bin/env bash
# Tests for lib/plan-adherence.sh
set -euo pipefail

LIB="$(cd "$(dirname "$0")/../.." && pwd)/lib/plan-adherence.sh"
PASS=0
FAIL=0

check() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"
    ((FAIL++)) || true
  fi
}

# === A: single task ===
out=$(bash "$LIB" /dev/stdin <<< '### task-001: do a thing')
count=$(echo "$out" | jq '.plan_task_ids | length')
gap=$(echo "$out" | jq '.gap_message')
check "A: single task - plan_task_ids length is 1" "1" "$count"
check "A: single task - gap_message is null" "null" "$gap"

# Verify the task ID extracted is correct
id=$(echo "$out" | jq -r '.plan_task_ids[0]')
check "A: single task - ID is task-001" "task-001" "$id"

# === B: multiple tasks ===
input="$(cat <<'INPUT'
## Architecture overview

Some prose here.

### task-001: first task
Acceptance criteria blah blah.

### task-002: second task
More prose.

### task-003: third task
Final task.
INPUT
)"
out=$(bash "$LIB" /dev/stdin <<< "$input")
count=$(echo "$out" | jq '.plan_task_ids | length')
gap=$(echo "$out" | jq '.gap_message')
check "B: multiple tasks - plan_task_ids length is 3" "3" "$count"
check "B: multiple tasks - gap_message is null" "null" "$gap"

id0=$(echo "$out" | jq -r '.plan_task_ids[0]')
id2=$(echo "$out" | jq -r '.plan_task_ids[2]')
check "B: multiple tasks - first ID is task-001" "task-001" "$id0"
check "B: multiple tasks - last ID is task-003" "task-003" "$id2"

# === C: no tasks ===
out=$(bash "$LIB" /dev/stdin <<< '# Some plan with no task headings

Just prose here, no task-NNN headings.')
count=$(echo "$out" | jq '.plan_task_ids | length')
gap=$(echo "$out" | jq '.gap_message')
check "C: no tasks - plan_task_ids is empty array" "0" "$count"
check "C: no tasks - gap_message is null" "null" "$gap"

# === D: invalid file path (fail-open) ===
out=$(bash "$LIB" /nonexistent/path/to/PLAN.md)
exit_code=$?
check "D: invalid file - exits 0 (fail-open)" "0" "$exit_code"
gap=$(echo "$out" | jq -r '.gap_message')
ids=$(echo "$out" | jq '.plan_task_ids | length')
check "D: invalid file - plan_task_ids is empty" "0" "$ids"
# gap_message should be non-null (contains error message)
if [[ "$gap" != "null" && -n "$gap" ]]; then
  echo "PASS: D: invalid file - gap_message is non-null error string"
  ((PASS++)) || true
else
  echo "FAIL: D: invalid file - gap_message should be non-null error string, got '$gap'"
  ((FAIL++)) || true
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
