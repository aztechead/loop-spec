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

# Acknowledgment removes only the published prefix under the writer's lock.
bash "$LIB" "$WORK/feat" '{"slug":"ack","pendingRemediationTasks":[{"id":"a"},{"id":"b"}],"artifacts":{"tasks":"tasks.json"},"warnings":["keep"],"specApproval":{"digest":"immutable"}}' >/dev/null
ack='{"snapshot":[{"id":"a"}],"generation":null,"receipt":"first"}'
exit_code=0
bash "$LIB" ack-remediation "$WORK/feat" "$ack" >/dev/null 2>&1 || exit_code=$?
check "ack: exact prefix acknowledged" "0" "$exit_code"
check "ack: concurrent suffix remains" '[{"id":"b"}]' "$(jq -c '.pendingRemediationTasks' "$WORK/feat/feature.json")"
check "ack: unrelated artifacts retained" "tasks.json" "$(jq -r '.artifacts.tasks' "$WORK/feat/feature.json")"
check "ack: unrelated warnings retained" '["keep"]' "$(jq -c '.warnings' "$WORK/feat/feature.json")"
check "ack: approval unchanged" '{"digest":"immutable"}' "$(jq -c '.specApproval' "$WORK/feat/feature.json")"
before="$(cat "$WORK/feat/feature.json")"
exit_code=0
bash "$LIB" ack-remediation "$WORK/feat" "$ack" >/dev/null 2>&1 || exit_code=$?
check "ack: stale snapshot rejected" "1" "$exit_code"
check "ack: stale snapshot changes nothing" "$before" "$(cat "$WORK/feat/feature.json")"

exit_code=0
bash "$LIB" set "$WORK/feat" specApproval '{"digest":"changed"}' >/dev/null 2>&1 || exit_code=$?
check "ack: later writes still cannot change approval" "1" "$exit_code"
check "ack: rejected approval edit changes nothing" "$before" "$(cat "$WORK/feat/feature.json")"
# The driver's reopen for a human-approved SPEC rewind: the record retires into the
# history first, then the approval may clear; a bare clear is still refused.
exit_code=0
bash "$LIB" set "$WORK/feat" specApproval null >/dev/null 2>&1 || exit_code=$?
check "reopen: clearing the approval without retiring it is refused" "1" "$exit_code"
bash "$LIB" append "$WORK/feat" specApprovalHistory '{"digest":"immutable","reopenedBy":"human.iterate-spec-approval"}' >/dev/null
bash "$LIB" set "$WORK/feat" specApproval null >/dev/null
check "reopen: a retired approval may clear" "null" "$(jq -r '.specApproval' "$WORK/feat/feature.json")"
printf '#!/usr/bin/env bash\necho "injected store persistence failure" >&2\nexit 2\n' > "$WORK/failing-store.sh"
chmod +x "$WORK/failing-store.sh"
exit_code=0
LOOP_SPEC_STORE="$WORK/failing-store.sh" bash "$LIB" set "$WORK/feat" slug '"locally-written"' >/dev/null 2>&1 || exit_code=$?
check "writer: store persistence failure remains exit 2" "2" "$exit_code"
check "writer: store failure retains the existing local-written contract" "locally-written" "$(jq -r '.slug' "$WORK/feat/feature.json")"

python3 "$(dirname "$0")/feature-write-concurrency.py" "$LIB" || FAIL=$((FAIL + 1))

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
