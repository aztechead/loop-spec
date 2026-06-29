#!/usr/bin/env bash
# Tests for lib/acceptance-lint.sh -- flags bare-substring grep acceptance criteria.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/lib/acceptance-lint.sh"
PASS=0
FAIL=0

check() {
  local name="$1" cond="$2"
  if [[ "$cond" == "1" ]]; then PASS=$((PASS+1)); echo "PASS: $name"
  else FAIL=$((FAIL+1)); echo "FAIL: $name"; fi
}

# Bare-substring grep -> flagged (exit 1).
echo '[{"id":"task-001","acceptanceCriteria":["grep -c \"allVersions\" src/app.ts returns 0"]}]' | bash "$LIB" >/dev/null 2>&1
check "bare grep -c flagged (exit 1)" "$([[ $? -eq 1 ]] && echo 1 || echo 0)"

# Behavioral check (no grep) -> ok (exit 0).
echo '[{"id":"task-001","acceptanceCriteria":["npm test -- app.test.ts exits 0"]}]' | bash "$LIB" >/dev/null 2>&1
check "behavioral criterion ok (exit 0)" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"

# Whole-word anchored grep -> exempt (exit 0).
echo '[{"id":"task-001","acceptanceCriteria":["grep -w \"allVersions\" src/app.ts exits 0"]}]' | bash "$LIB" >/dev/null 2>&1
check "grep -w exempt (exit 0)" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"

# Comment-excluding pipeline -> exempt (exit 0).
echo '[{"id":"task-001","acceptanceCriteria":["grep -v \"//\" f | grep -c x returns 1"]}]' | bash "$LIB" >/dev/null 2>&1
check "grep -v comment strip exempt" "$([[ $? -eq 0 ]] && echo 1 || echo 0)"

# Mixed: one bad among good -> flagged.
echo '[{"id":"t1","acceptanceCriteria":["pytest passes"]},{"id":"t2","acceptanceCriteria":["grep -c \"foo\" f returns 2"]}]' | bash "$LIB" >/dev/null 2>&1
check "mixed set flags the bad one" "$([[ $? -eq 1 ]] && echo 1 || echo 0)"

# Flag output names the offending task id.
out="$(echo '[{"id":"task-099","acceptanceCriteria":["grep -c \"foo\" f returns 2"]}]' | bash "$LIB" 2>/dev/null)"
check "flag output names the task" "$(echo "$out" | grep -q 'task-099' && echo 1 || echo 0)"

# Invalid JSON -> error exit.
echo 'not json' | bash "$LIB" >/dev/null 2>&1
check "invalid JSON errors" "$([[ $? -ne 0 ]] && echo 1 || echo 0)"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
