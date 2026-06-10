#!/usr/bin/env bash
# Tests for lib/dag-width.sh
set -euo pipefail

LIB="$(cd "$(dirname "$0")/../.." && pwd)/lib/dag-width.sh"
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

# width via stdin
check "A: empty set -> 0"        "0" "$(echo '[]' | bash "$LIB")"
check "B: single task -> 1"      "1" "$(echo '[{"id":"t1","blockedBy":[]}]' | bash "$LIB")"
check "C: serial chain -> 1"     "1" "$(echo '[{"id":"a","blockedBy":[]},{"id":"b","blockedBy":["a"]},{"id":"c","blockedBy":["b"]}]' | bash "$LIB")"
check "D: three independent -> 3" "3" "$(echo '[{"id":"a","blockedBy":[]},{"id":"b","blockedBy":[]},{"id":"c","blockedBy":[]}]' | bash "$LIB")"
check "E: diamond -> 2"          "2" "$(echo '[{"id":"a","blockedBy":[]},{"id":"b","blockedBy":["a"]},{"id":"c","blockedBy":["a"]},{"id":"d","blockedBy":["b","c"]}]' | bash "$LIB")"

# missing/null blockedBy treated as no edges
check "F: null blockedBy -> 2"   "2" "$(echo '[{"id":"a","blockedBy":null},{"id":"b"}]' | bash "$LIB")"

# dangling dep (edge to nonexistent id) cannot block -> ignored
check "G: dangling dep -> 1"     "1" "$(echo '[{"id":"a","blockedBy":["ghost"]}]' | bash "$LIB")"

# width via positional arg (not stdin)
check "H: arg input -> 2"        "2" "$(bash "$LIB" '[{"id":"a","blockedBy":[]},{"id":"b","blockedBy":[]}]')"

# wide-then-narrow keeps the peak
check "I: peak across waves -> 3" "3" "$(echo '[{"id":"a","blockedBy":[]},{"id":"b","blockedBy":[]},{"id":"c","blockedBy":[]},{"id":"d","blockedBy":["a","b","c"]}]' | bash "$LIB")"

# dependency cycle -> exit 3, partial width on stdout
cyc_out="$(echo '[{"id":"a","blockedBy":["b"]},{"id":"b","blockedBy":["a"]}]' | bash "$LIB" 2>/dev/null || true)"
check "J: cycle prints partial W=0" "0" "$cyc_out"
set +e
echo '[{"id":"a","blockedBy":["b"]},{"id":"b","blockedBy":["a"]}]' | bash "$LIB" >/dev/null 2>&1
cyc_rc=$?
set -e
check "K: cycle exits 3" "3" "$cyc_rc"

# invalid JSON -> exit 2
set +e
echo 'not json' | bash "$LIB" >/dev/null 2>&1
bad_rc=$?
set -e
check "L: invalid JSON exits 2" "2" "$bad_rc"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
