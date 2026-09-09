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

WORK="${TMPDIR:-/tmp}/footprint-test.$$"; FD="$WORK/repo/.loop-spec/features/fd"; mkdir -p "$FD" "$WORK/repo/tests" "$WORK/repo/src"
trap 'rm -rf "$WORK"' EXIT
# Read-only is the task's word: feature.json.protected names the files the change may
# not touch; a cited source file's existing test module is in the footprint by
# construction (followup-4, item 1).
git -C "$WORK/repo" init -q -b main
printf '{"slug":"fd","protected":["tests/test_a.py"]}\n' > "$FD/feature.json"
: > "$WORK/repo/tests/test_a.py"; : > "$WORK/repo/tests/test_b.py"

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
check "list: cited files once each, first-cite order, the protected file left out, b's test module added by construction" "src/a.py src/b.py tests/test_b.py" "$(bash "$LIB" list "$FD" 2>/dev/null | paste -sd' ')"
check "list --read-only: the protected file" "tests/test_a.py" "$(bash "$LIB" list "$FD" --read-only 2>/dev/null)"
check "show: every cite" "4" "$(bash "$LIB" show "$FD" | wc -l | tr -d ' ')"
check "show: a cite carries its why" "holds the bug" "$(bash "$LIB" show "$FD" | head -1 | jq -r '.why')"
check "show: a cite carries its line" "40" "$(bash "$LIB" show "$FD" | sed -n 2p | jq -r '.line')"
bash "$LIB" cite "$FD" src/b.py:9 --read-only
check "a read-only mark on a file the task does not protect is not honored" "src/a.py src/b.py tests/test_b.py" "$(bash "$LIB" list "$FD" 2>/dev/null | paste -sd' ')"
check "and the notice says so" "1" "$(bash "$LIB" list "$FD" 2>&1 >/dev/null | grep -c 'src/b.py is marked read-only by the scout but the task protects no such file')"
check "the read-only list is the protected list" "tests/test_a.py" "$(bash "$LIB" list "$FD" --read-only 2>/dev/null | paste -sd' ')"
# A protected test module is read-only even when the scout never cited it.
printf '{"slug":"fd","protected":["tests/test_a.py","tests/test_b.py"]}\n' > "$FD/feature.json"
check "a protected test module of a cited file is read-only by construction" "tests/test_a.py tests/test_b.py" "$(bash "$LIB" list "$FD" --read-only 2>/dev/null | paste -sd' ')"
check "and out of the footprint" "src/a.py src/b.py" "$(bash "$LIB" list "$FD" 2>/dev/null | paste -sd' ')"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
