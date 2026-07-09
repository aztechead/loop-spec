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

WORK="${TMPDIR:-/tmp}/loop-spec-feature-write.$$"
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

# ── set / append subcommands (regression: a field run misdiagnosed nested set
#    as "top-level only" and bypassed the script with raw jq) ──────────────────
bash "$LIB" "$WORK/feat" '{"slug":"baz","artifacts":{"patterns":null},"warnings":[]}' >/dev/null

# Case G: top-level set
bash "$LIB" set "$WORK/feat" currentPhase '"plan"' >/dev/null
check "G: top-level set" "plan" "$(jq -r '.currentPhase' "$WORK/feat/feature.json")"

# Case H: NESTED set (dot path into an object)
bash "$LIB" set "$WORK/feat" artifacts.patterns '"docs/PATTERNS.md"' >/dev/null
check "H: nested set writes through dot path" "docs/PATTERNS.md" \
  "$(jq -r '.artifacts.patterns' "$WORK/feat/feature.json")"

# Case H2: nested set creates missing intermediate objects
bash "$LIB" set "$WORK/feat" telemetry.dispatches '3' >/dev/null
check "H2: nested set creates intermediates" "3" \
  "$(jq -r '.telemetry.dispatches' "$WORK/feat/feature.json")"

# Case H3: set null and false (valid JSON values, not errors)
bash "$LIB" set "$WORK/feat" artifacts.patterns 'null' >/dev/null
check "H3: set null accepted" "null" "$(jq -r '.artifacts.patterns' "$WORK/feat/feature.json")"
bash "$LIB" set "$WORK/feat" autonomous 'false' >/dev/null
check "H3: set false accepted" "false" "$(jq -r '.autonomous' "$WORK/feat/feature.json")"

# Case I: append to an array, and to a null/missing path (becomes [v])
bash "$LIB" append "$WORK/feat" warnings '"w1"' >/dev/null
bash "$LIB" append "$WORK/feat" warnings '"w2"' >/dev/null
check "I: append grows array" '["w1","w2"]' "$(jq -c '.warnings' "$WORK/feat/feature.json")"
bash "$LIB" append "$WORK/feat" telemetry.events '"e1"' >/dev/null
check "I: append to missing path creates array" '["e1"]' \
  "$(jq -c '.telemetry.events' "$WORK/feat/feature.json")"

# Case J: append onto a non-array is refused, file untouched
exit_code=0
bash "$LIB" append "$WORK/feat" currentPhase '"x"' >/dev/null 2>&1 || exit_code=$?
check "J: append onto non-array rejected" "1" "$( [[ $exit_code -ne 0 ]] && echo 1 || echo 0 )"
check "J: file untouched after refusal" "plan" "$(jq -r '.currentPhase' "$WORK/feat/feature.json")"

# Case K: bare (unquoted) string value → clear error naming the quoting rule
err=$(bash "$LIB" set "$WORK/feat" artifacts.patterns docs/PATTERNS.md 2>&1 >/dev/null) && exit_code=0 || exit_code=$?
check "K: bare string value rejected (exit 1)" "1" "$exit_code"
check "K: error explains JSON quoting" "1" "$(grep -c 'JSON-quoted' <<<"$err")"
check "K: file untouched after bad value" "null" \
  "$(jq -r '.artifacts.patterns' "$WORK/feat/feature.json")"

# Case L: array-index path rejected with the array-limitation hint
err=$(bash "$LIB" set "$WORK/feat" 'workspace.repos[0]' '"x"' 2>&1 >/dev/null) && exit_code=0 || exit_code=$?
check "L: array-index dot_path rejected" "1" "$exit_code"
check "L: error names the limitation" "1" "$(grep -c 'array indices are not' <<<"$err")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
