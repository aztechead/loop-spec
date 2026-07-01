#!/usr/bin/env bash
# Tests for lib/backlog.sh (deferred-work backlog).
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/lib/backlog.sh"
PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $name"; ((PASS++)) || true
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; ((FAIL++)) || true
  fi
}

WORK="${TMPDIR:-/tmp}/backlog-test.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"
export LOOP_SPEC_BACKLOG_FILE="$WORK/BACKLOG.md"

# empty state
check "count on missing file is 0" "0" "$(bash "$SCRIPT" count)"
ec=0; bash "$SCRIPT" next >/dev/null 2>&1 || ec=$?
check "next on missing file exits 1" "1" "$ec"

# add
check "first add prints added" "added" "$(bash "$SCRIPT" add feat-a iterate-gap "close the CSV export gap")"
check "duplicate add prints exists" "exists" "$(bash "$SCRIPT" add feat-a iterate-gap "close the CSV export gap")"
check "second add prints added" "added" "$(bash "$SCRIPT" add feat-b verify-deferred "fix N+1 query in listing")"
check "count is 2" "2" "$(bash "$SCRIPT" count)"

# next returns FIRST unchecked, bare text
check "next returns first entry text" "close the CSV export gap" "$(bash "$SCRIPT" next)"

# done checks off exactly one
check "done marks entry" "done" "$(bash "$SCRIPT" done "close the CSV export gap")"
check "count is 1 after done" "1" "$(bash "$SCRIPT" count)"
check "next advances to second entry" "fix N+1 query in listing" "$(bash "$SCRIPT" next)"
grep -q '^- \[x\] .*close the CSV export gap' "$LOOP_SPEC_BACKLOG_FILE" && checked=yes || checked=no
check "done entry is checked in file" "yes" "$checked"

# done on unknown text fails
ec=0; bash "$SCRIPT" done "no such entry" >/dev/null 2>&1 || ec=$?
check "done on unknown text exits 1" "1" "$ec"

# header written once
check "header present" "1" "$(grep -c '^# BACKLOG.md' "$LOOP_SPEC_BACKLOG_FILE")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
