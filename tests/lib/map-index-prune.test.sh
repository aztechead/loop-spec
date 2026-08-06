#!/usr/bin/env bash
# Tests for lib/map-index-prune.sh
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/lib/map-index-prune.sh"
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

contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "PASS: $name"; ((PASS++)) || true
  else
    echo "FAIL: $name (expected output to contain '$needle', got '$haystack')"; ((FAIL++)) || true
  fi
}

WORK="${TMPDIR:-/tmp}/loop-spec-map-index-prune.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/state" "$WORK/lib"
cd "$WORK"
export LOOP_SPEC_MAP_INDEX="state/index.json"

rc=0; bash "$SCRIPT" extra-arg >/dev/null 2>&1 || rc=$?
check "A: arguments are a usage error" "2" "$rc"

# No index is nothing to prune, never a failure -- first runs have no index yet.
rc=0; out="$(bash "$SCRIPT")" || rc=$?
check "B: a missing index exits 0" "0" "$rc"
contains "C: the missing index is named" "pruned=0 kept=0 reason=state/index.json does not exist" "$out"

# A corrupt index is refused loudly: rewriting it would destroy the data.
printf 'not json\n' > state/index.json
rc=0; bash "$SCRIPT" >/dev/null 2>&1 || rc=$?
check "D: a corrupt index exits 2" "2" "$rc"
check "E: the corrupt index is left untouched" "not json" "$(cat state/index.json)"

printf 'real\n' > lib/present.sh
cat > state/index.json <<'EOF'
{"last_refreshed_at": {"arch": "2026-01-01T00:00:00Z"},
 "files": {"lib/present.sh": ["arch", "tech"], "lib/removed.sh": ["arch"]}}
EOF

rc=0; out="$(bash "$SCRIPT")" || rc=$?
check "F: pruning exits 0" "0" "$rc"
contains "G: the removed entry is reported with its domains" \
  "pruned path=lib/removed.sh domains=arch" "$out"
contains "H: the summary counts both sides" "pruned=1 kept=1" "$out"
check "I: the surviving entry keeps its domains" \
  '["arch","tech"]' "$(jq -c '.files["lib/present.sh"]' state/index.json)"
check "J: the orphan key is gone" "null" "$(jq -c '.files["lib/removed.sh"]' state/index.json)"
check "K: refresh stamps survive the prune" \
  '"2026-01-01T00:00:00Z"' "$(jq -c '.last_refreshed_at.arch' state/index.json)"

# A second run finds nothing -- pruning is idempotent.
rc=0; out="$(bash "$SCRIPT")" || rc=$?
check "L: a clean index exits 0" "0" "$rc"
contains "M: nothing left to prune is said plainly" "pruned=0 kept=1 reason=every indexed file exists" "$out"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
