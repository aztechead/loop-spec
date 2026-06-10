#!/usr/bin/env bash
# Tests for lib/feature-write.sh
set -euo pipefail

LIB="$(cd "$(dirname "$0")/../.." && pwd)/lib/feature-write.sh"
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
    echo "FAIL: $name (expected $expected, got $actual)"
    ((FAIL++)) || true
  fi
}

WORK="${TMPDIR:-/tmp}/super-spec-feature-write.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/feat"

# Case A: write to fresh dir produces feature.json with correct content
bash "$LIB" "$WORK/feat" '{"slug":"foo","schemaVersion":1}' >/dev/null
got=$(jq -r '.slug' "$WORK/feat/feature.json" 2>/dev/null || echo MISSING)
check "A: fresh write creates feature.json with content" "foo" "$got"

# Case B: second write rotates current to .bak
bash "$LIB" "$WORK/feat" '{"slug":"bar","schemaVersion":1}' >/dev/null
got_curr=$(jq -r '.slug' "$WORK/feat/feature.json")
got_bak=$(jq -r '.slug' "$WORK/feat/feature.json.bak")
check "B: second write rotates current to .bak (current=bar)" "bar" "$got_curr"
check "B: second write rotates current to .bak (bak=foo)" "foo" "$got_bak"

# Case C: invalid JSON rejected, feature.json untouched
exit_code=0
bash "$LIB" "$WORK/feat" 'not json {{{' >/dev/null 2>&1 || exit_code=$?
check "C: invalid JSON rejected (exit 1)" "1" "$exit_code"
got_unchanged=$(jq -r '.slug' "$WORK/feat/feature.json")
check "C: feature.json unchanged after invalid input" "bar" "$got_unchanged"

# Case D: missing dir rejected
exit_code=0
bash "$LIB" "$WORK/missing" '{"x":1}' >/dev/null 2>&1 || exit_code=$?
check "D: missing dir rejected (exit 1)" "1" "$exit_code"

# Case E: wrong arg count rejected
exit_code=0
bash "$LIB" "$WORK/feat" >/dev/null 2>&1 || exit_code=$?
check "E: wrong arg count rejected (exit 1)" "1" "$exit_code"

# Case F: no .tmp file left behind after success
bash "$LIB" "$WORK/feat" '{"slug":"baz"}' >/dev/null
[[ -f "$WORK/feat/feature.json.tmp" ]] && tmp_present=yes || tmp_present=no
check "F: feature.json.tmp cleaned up after success" "no" "$tmp_present"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
