#!/usr/bin/env bash
# Tests for lib/footprint.sh: the scout's record the oneshot probe reads.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/lib/footprint.sh"
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

WORK="${TMPDIR:-/tmp}/footprint-test.$$"; FD="$WORK/fd"; mkdir -p "$FD"
trap 'rm -rf "$WORK"' EXIT

check "bad invocation exits 2" "2" "$(bash "$LIB" >/dev/null 2>&1; echo $?)"
check "a missing feature dir exits 2" "2" "$(bash "$LIB" list "$WORK/none" >/dev/null 2>&1; echo $?)"
check "list on an empty ledger prints nothing" "" "$(bash "$LIB" list "$FD")"
check "a cite without a line is refused" "1" "$(bash "$LIB" cite "$FD" src/a.py >/dev/null 2>&1; echo $?)"
check "an absolute cite is refused" "1" "$(bash "$LIB" cite "$FD" /etc/passwd:1 >/dev/null 2>&1; echo $?)"
check "nothing was written by the refusals" "0" "$([[ -f "$FD/footprint.jsonl" ]] && echo 1 || echo 0)"
bash "$LIB" cite "$FD" src/a.py:12 "holds the bug"
bash "$LIB" cite "$FD" src/a.py:40
bash "$LIB" cite "$FD" tests/test_a.py:3 --read-only "the task protects it"
bash "$LIB" cite "$FD" src/b.py:1
check "list: cited files once each, first-cite order, read-only left out" "src/a.py src/b.py" "$(bash "$LIB" list "$FD" | paste -sd' ')"
check "list --read-only: the read-only files" "tests/test_a.py" "$(bash "$LIB" list "$FD" --read-only)"
check "show: every cite" "4" "$(bash "$LIB" show "$FD" | wc -l | tr -d ' ')"
check "show: a cite carries its why" "holds the bug" "$(bash "$LIB" show "$FD" | head -1 | jq -r '.why')"
check "show: a cite carries its line" "40" "$(bash "$LIB" show "$FD" | sed -n 2p | jq -r '.line')"
bash "$LIB" cite "$FD" src/b.py:9 --read-only
check "a file cited both ways is read-only (the mark is the stronger fact)" "src/a.py" "$(bash "$LIB" list "$FD")"
check "and it appears in the read-only list once" "tests/test_a.py src/b.py" "$(bash "$LIB" list "$FD" --read-only | paste -sd' ')"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
