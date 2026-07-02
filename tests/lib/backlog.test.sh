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

# gap-id: deterministic + normalization-insensitive
gid1="$(bash "$SCRIPT" gap-id "Fix the CSV export!")"
gid2="$(bash "$SCRIPT" gap-id "  fix   the csv EXPORT ")"
check "gap-id is deterministic across normalization" "$gid1" "$gid2"
check "gap-id is 8 hex chars" "8" "${#gid1}"
gid_other="$(bash "$SCRIPT" gap-id "a different gap")"
[[ "$gid1" != "$gid_other" ]] && distinct=yes || distinct=no
check "different text gets different gap-id" "yes" "$distinct"

# add --id stamps the id into the metadata group
check "add with id prints added" "added" "$(bash "$SCRIPT" add feat-c iterate-gap "close the export gap" --id "$gid1")"
grep -q "id=$gid1) close the export gap" "$LOOP_SPEC_BACKLOG_FILE" && stamped=yes || stamped=no
check "id stamped in entry metadata" "yes" "$stamped"

# idempotent on id even with different text
check "duplicate id prints exists" "exists" "$(bash "$SCRIPT" add feat-c iterate-gap "close the export gap (reworded)" --id "$gid1")"

# next --json surfaces the id of the top entry
bash "$SCRIPT" done "fix N+1 query in listing" >/dev/null
next_json="$(bash "$SCRIPT" next --json)"
check "next --json id" "$gid1" "$(jq -r '.id' <<<"$next_json")"
check "next --json text" "close the export gap" "$(jq -r '.text' <<<"$next_json")"
check "next --json type" "iterate-gap" "$(jq -r '.type' <<<"$next_json")"

# entries without an id report null id
bash "$SCRIPT" add feat-d manual "an id-less entry" >/dev/null
bash "$SCRIPT" done "close the export gap" >/dev/null
check "next --json null id when absent" "null" "$(bash "$SCRIPT" next --json | jq -r '.id')"

# terminal: closes by id with a TERMINAL note
check "re-add for terminal test" "added" "$(bash "$SCRIPT" add feat-c iterate-gap "close the export gap again" --id "$gid1")"
ec=0; bash "$SCRIPT" is-terminal "$gid1" >/dev/null 2>&1 || ec=$?
check "is-terminal before terminal exits 1" "1" "$ec"
check "terminal marks entry" "terminal" "$(bash "$SCRIPT" terminal "$gid1" "two budgets spent; approach wrong")"
grep -q -- '- \[x\] .*close the export gap again -- TERMINAL: two budgets spent' "$LOOP_SPEC_BACKLOG_FILE" && tmarked=yes || tmarked=no
check "terminal entry checked with note" "yes" "$tmarked"
ec=0; bash "$SCRIPT" is-terminal "$gid1" || ec=$?
check "is-terminal after terminal exits 0" "0" "$ec"
ec=0; bash "$SCRIPT" terminal "$gid1" "again" >/dev/null 2>&1 || ec=$?
check "terminal on already-closed id exits 1" "1" "$ec"
ec=0; bash "$SCRIPT" is-terminal "deadbeef" >/dev/null 2>&1 || ec=$?
check "is-terminal on unknown id exits 1" "1" "$ec"

# rung 5: a TERMINAL id is never re-queued
check "re-add of terminal id refused" "terminal" "$(bash "$SCRIPT" add feat-c iterate-gap "the same gap yet again" --id "$gid1" 2>/dev/null)"
grep -q -- '- \[ \] .*the same gap yet again' "$LOOP_SPEC_BACKLOG_FILE" && readded=yes || readded=no
check "terminal id not re-queued in file" "no" "$readded"

# count is a single number even when zero unchecked remain (grep -c || echo 0 bug)
while entry="$(bash "$SCRIPT" next 2>/dev/null)"; do bash "$SCRIPT" done "$entry" >/dev/null; done
c="$(bash "$SCRIPT" count)"
check "count zero is single line" "0" "$c"
check "count zero line count" "1" "$(bash "$SCRIPT" count | wc -l | tr -d ' ')"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
