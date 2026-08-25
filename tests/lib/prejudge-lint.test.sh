#!/usr/bin/env bash
# Tests for lib/prejudge-lint.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/lib/prejudge-lint.sh"
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

WORK="${TMPDIR:-/tmp}/prejudge-lint-test.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"

printf '%s\n' "Review the diff. Report every finding." > "$WORK/clean.md"
ec=0
bash "$SCRIPT" scan "$WORK/clean.md" >/dev/null || ec=$?
check "clean template exits 0" "0" "$ec"

printf '%s\n' "Please do not flag the logging change." > "$WORK/coached.md"
ec=0
out=$(bash "$SCRIPT" scan "$WORK/coached.md" 2>&1) || ec=$?
check "do-not-flag exits 1" "1" "$ec"
echo "$out" | grep -q "tell=do-not-flag" && r=ok || r=missing
check "do-not-flag is named" "ok" "$r"

printf '%s\n' "This is at most Minor." > "$WORK/minor.md"
ec=0
out=$(bash "$SCRIPT" scan "$WORK/minor.md" 2>&1) || ec=$?
check "at-most-minor exits 1" "1" "$ec"
echo "$out" | grep -q "tell=at-most-minor" && r=ok || r=missing
check "at-most-minor is named" "ok" "$r"

printf '%s\n' "Skip it because the plan chose JSON." > "$WORK/chose.md"
ec=0
out=$(bash "$SCRIPT" scan "$WORK/chose.md" 2>&1) || ec=$?
check "plan-chose exits 1" "1" "$ec"
echo "$out" | grep -q "tell=plan-chose" && r=ok || r=missing
check "plan-chose is named" "ok" "$r"

printf '%s\n' "Please ignore this finding." > "$WORK/ignore.md"
ec=0
out=$(bash "$SCRIPT" scan "$WORK/ignore.md" 2>&1) || ec=$?
check "ignore-finding exits 1" "1" "$ec"
echo "$out" | grep -q "tell=ignore-finding" && r=ok || r=missing
check "ignore-finding is named" "ok" "$r"

printf '%s\n' "Don't treat style as Important." > "$WORK/treat.md"
ec=0
out=$(bash "$SCRIPT" scan "$WORK/treat.md" 2>&1) || ec=$?
check "dont-treat exits 1" "1" "$ec"
echo "$out" | grep -q "tell=dont-treat" && r=ok || r=missing
check "dont-treat is named" "ok" "$r"

printf '%s\n' "A plan-mandated finding is reported, not skipped." > "$WORK/allowed.md"
ec=0
bash "$SCRIPT" scan "$WORK/allowed.md" >/dev/null || ec=$?
check "plan-mandated label is allowed" "0" "$ec"

ec=0; bash "$SCRIPT" >/dev/null 2>&1 || ec=$?
check "usage without scan exits 2" "2" "$ec"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
