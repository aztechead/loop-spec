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

# Malformed input is a USAGE error (2), never a criterion finding (1): a caller
# that treats every non-zero exit as "criteria are bad" would remediate the wrong thing.
rc=0; echo 'not json' | bash "$LIB" >/dev/null 2>&1 || rc=$?
check "invalid JSON is a bad invocation" "$([[ $rc -eq 2 ]] && echo 1 || echo 0)"
rc=0; printf '' | bash "$LIB" >/dev/null 2>&1 || rc=$?
check "empty input is a bad invocation" "$([[ $rc -eq 2 ]] && echo 1 || echo 0)"
rc=0; printf '   \n' | bash "$LIB" >/dev/null 2>&1 || rc=$?
check "whitespace-only input is a bad invocation" "$([[ $rc -eq 2 ]] && echo 1 || echo 0)"
rc=0; echo '{"id":"task-001"}' | bash "$LIB" >/dev/null 2>&1 || rc=$?
check "a JSON object is not a tasks array" "$([[ $rc -eq 2 ]] && echo 1 || echo 0)"

# An empty tasks array is a DEFINED clean state, not a crash.
rc=0; echo '[]' | bash "$LIB" >/dev/null 2>&1 || rc=$?
check "empty tasks array is clean" "$([[ $rc -eq 0 ]] && echo 1 || echo 0)"

# The graph gate names a file; a graph node has no pipeline to pipe through.
TASKS="${TMPDIR:-/tmp}/loop-spec-acceptance-lint.$$.json"
trap 'rm -f "$TASKS"' EXIT
echo '[{"id":"task-001","acceptanceCriteria":["grep -w \"foo\" f"]}]' > "$TASKS"
rc=0; bash "$LIB" "$TASKS" >/dev/null 2>&1 || rc=$?
check "clean tasks file passes by path" "$([[ $rc -eq 0 ]] && echo 1 || echo 0)"
echo '[{"id":"task-002","acceptanceCriteria":["grep -c \"foo\" f returns 2"]}]' > "$TASKS"
rc=0; bash "$LIB" "$TASKS" >/dev/null 2>&1 || rc=$?
check "flagged tasks file exits 1 by path" "$([[ $rc -eq 1 ]] && echo 1 || echo 0)"
rc=0; bash "$LIB" "$TASKS.missing" >/dev/null 2>&1 || rc=$?
check "missing tasks file is a bad invocation" "$([[ $rc -eq 2 ]] && echo 1 || echo 0)"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
