#!/usr/bin/env bash
# Unit tests for lib/quality-loop-state.sh
# Standalone: exit 0 on all pass, exit 1 on any failure.
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/quality-loop-state.sh"
PASS=0
FAIL=0

pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Run the script with the test state file set.
ql() {
  LOOP_SPEC_QL_STATE="$STATE_FILE" bash "$SCRIPT" "$@"
}

# Assert the state file is valid JSON.
assert_valid_json() {
  local label="$1"
  if jq . "$STATE_FILE" >/dev/null 2>&1; then
    pass "$label: state file is valid JSON"
  else
    fail "$label: state file is not valid JSON"
  fi
}

# ---------------------------------------------------------------------------
# Setup: temp workspace
# ---------------------------------------------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STATE_FILE="$WORK/quality-loop.json"

# ---------------------------------------------------------------------------
# Case 1: scope init - resets missing entries, prints count
# ---------------------------------------------------------------------------
echo "--- Case 1: scope init ---"

count="$(ql scope "src/a.py" "src/b.py" "src/c.py")"
if [[ "$count" == "3" ]]; then
  pass "scope prints count=3"
else
  fail "scope prints count=3 (got '$count')"
fi

assert_valid_json "scope init"

# All three files should have an entry.
for f in "src/a.py" "src/b.py" "src/c.py"; do
  entry="$(jq -r --arg f "$f" '.[$f] | type' "$STATE_FILE")"
  if [[ "$entry" == "object" ]]; then
    pass "scope: entry present for $f"
  else
    fail "scope: entry present for $f (got $entry)"
  fi
done

# Add a pre-existing entry for src/a.py with round data to verify it is NOT reset.
existing_state="$(jq --arg f "src/a.py" '.[$f].rounds["1"] = {"findings":[],"findingCount":0,"blockingCount":0}' "$STATE_FILE")"
printf '%s\n' "$existing_state" > "$STATE_FILE"

# Re-run scope with same files; existing entry for src/a.py must be preserved.
count2="$(ql scope "src/a.py" "src/b.py")"
if [[ "$count2" == "2" ]]; then
  pass "scope re-run prints count=2"
else
  fail "scope re-run prints count=2 (got '$count2')"
fi
preserved="$(jq -r '."src/a.py".rounds["1"]' "$STATE_FILE")"
if [[ "$preserved" != "null" ]]; then
  pass "scope: existing round data preserved for existing entry"
else
  fail "scope: existing round data preserved for existing entry"
fi

assert_valid_json "scope re-run"

# ---------------------------------------------------------------------------
# Case 2: record two rounds
# ---------------------------------------------------------------------------
echo "--- Case 2: record-round ---"

# Reset state
rm -f "$STATE_FILE"

ql scope "app/main.py" >/dev/null

FINDINGS_R1='[{"source":"code-reviewer","category":"error-handling","severity":"HIGH","claim":"missing null check","line":10}]'
ql record-round "app/main.py" 1 "$FINDINGS_R1"
assert_valid_json "record round 1"

# Verify round 1 data.
r1_count="$(jq -r '."app/main.py".rounds["1"].findingCount' "$STATE_FILE")"
r1_blocking="$(jq -r '."app/main.py".rounds["1"].blockingCount' "$STATE_FILE")"
if [[ "$r1_count" == "1" ]]; then
  pass "record-round 1: findingCount=1"
else
  fail "record-round 1: findingCount=1 (got $r1_count)"
fi
if [[ "$r1_blocking" == "1" ]]; then
  pass "record-round 1: blockingCount=1 (code-reviewer HIGH)"
else
  fail "record-round 1: blockingCount=1 (got $r1_blocking)"
fi

FINDINGS_R2='[{"source":"code-reviewer","category":"error-handling","severity":"MEDIUM","claim":"could handle edge case","line":20},{"source":"deterministic","category":"lint","severity":"LOW","claim":"trailing whitespace","line":5}]'
ql record-round "app/main.py" 2 "$FINDINGS_R2"
assert_valid_json "record round 2"

r2_count="$(jq -r '."app/main.py".rounds["2"].findingCount' "$STATE_FILE")"
r2_blocking="$(jq -r '."app/main.py".rounds["2"].blockingCount' "$STATE_FILE")"
if [[ "$r2_count" == "2" ]]; then
  pass "record-round 2: findingCount=2"
else
  fail "record-round 2: findingCount=2 (got $r2_count)"
fi
# Both are blocking: code-reviewer (any severity) + deterministic (any severity).
if [[ "$r2_blocking" == "2" ]]; then
  pass "record-round 2: blockingCount=2 (code-reviewer + deterministic)"
else
  fail "record-round 2: blockingCount=2 (got $r2_blocking)"
fi

# ---------------------------------------------------------------------------
# Case 3: mark-clean refused while blocking findings exist, succeeds after zero-blocking round
# ---------------------------------------------------------------------------
echo "--- Case 3: mark-clean blocking ---"

rm -f "$STATE_FILE"
ql scope "lib/foo.py" >/dev/null

BLOCKING='[{"source":"deterministic","category":"lint","severity":"LOW","claim":"error","line":1}]'
ql record-round "lib/foo.py" 1 "$BLOCKING"
assert_valid_json "before refused mark-clean"

# mark-clean should exit 2 here.
rc=0
ql mark-clean "lib/foo.py" 1 >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 2 ]]; then
  pass "mark-clean refused (exit 2) while blocking findings exist"
else
  fail "mark-clean refused (exit 2) while blocking findings exist (got exit $rc)"
fi

assert_valid_json "after refused mark-clean"

# Now record a zero-blocking round and mark-clean should succeed.
EMPTY_FINDINGS='[]'
ql record-round "lib/foo.py" 2 "$EMPTY_FINDINGS"
assert_valid_json "zero-blocking round recorded"

rc=0
ql mark-clean "lib/foo.py" 2 >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]]; then
  pass "mark-clean succeeds after zero-blocking round"
else
  fail "mark-clean succeeds after zero-blocking round (got exit $rc)"
fi

clean="$(jq -r '."lib/foo.py".clean' "$STATE_FILE")"
if [[ "$clean" == "true" ]]; then
  pass "mark-clean: clean flag set to true"
else
  fail "mark-clean: clean flag set to true (got $clean)"
fi

assert_valid_json "after successful mark-clean"

# ---------------------------------------------------------------------------
# Case 4: security severity -- MEDIUM does not block, HIGH blocks
# ---------------------------------------------------------------------------
echo "--- Case 4: security severity gate ---"

rm -f "$STATE_FILE"
ql scope "srv/api.py" >/dev/null

# security-reviewer MEDIUM: should NOT be blocking.
MEDIUM='[{"source":"security-reviewer","category":"injection","severity":"MEDIUM","claim":"potential sql injection","line":42}]'
ql record-round "srv/api.py" 1 "$MEDIUM"
assert_valid_json "security MEDIUM round"

blocking_count="$(jq -r '."srv/api.py".rounds["1"].blockingCount' "$STATE_FILE")"
if [[ "$blocking_count" == "0" ]]; then
  pass "security MEDIUM does not block (blockingCount=0)"
else
  fail "security MEDIUM does not block (got blockingCount=$blocking_count)"
fi

# mark-clean should succeed (no blocking).
rc=0
ql mark-clean "srv/api.py" 1 >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 0 ]]; then
  pass "mark-clean succeeds after security MEDIUM only"
else
  fail "mark-clean succeeds after security MEDIUM only (got exit $rc)"
fi

# security-reviewer HIGH: should block.
rm -f "$STATE_FILE"
ql scope "srv/api.py" >/dev/null
HIGH='[{"source":"security-reviewer","category":"injection","severity":"HIGH","claim":"sql injection confirmed","line":42}]'
ql record-round "srv/api.py" 1 "$HIGH"
assert_valid_json "security HIGH round"

blocking_high="$(jq -r '."srv/api.py".rounds["1"].blockingCount' "$STATE_FILE")"
if [[ "$blocking_high" == "1" ]]; then
  pass "security HIGH blocks (blockingCount=1)"
else
  fail "security HIGH blocks (got blockingCount=$blocking_high)"
fi

rc=0
ql mark-clean "srv/api.py" 1 >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 2 ]]; then
  pass "mark-clean refused (exit 2) for security HIGH"
else
  fail "mark-clean refused (exit 2) for security HIGH (got exit $rc)"
fi

assert_valid_json "after security HIGH mark-clean refusal"

# ---------------------------------------------------------------------------
# Case 5: systemic detection - category repeated in last 2 consecutive rounds
# ---------------------------------------------------------------------------
echo "--- Case 5: systemic detection ---"

rm -f "$STATE_FILE"
ql scope "core/engine.py" >/dev/null

# Round 1: category "error-handling" appears.
R1='[{"source":"code-reviewer","category":"error-handling","severity":"HIGH","claim":"missing check","line":1}]'
ql record-round "core/engine.py" 1 "$R1"

# Round 2: different category only.
R2='[{"source":"code-reviewer","category":"performance","severity":"MEDIUM","claim":"slow loop","line":5}]'
ql record-round "core/engine.py" 2 "$R2"

# systemic should produce no output (error-handling not in round 2).
systemic_out="$(ql systemic "core/engine.py")"
if [[ -z "$systemic_out" ]]; then
  pass "systemic: no output when categories differ between rounds 1 and 2"
else
  fail "systemic: no output when categories differ (got '$systemic_out')"
fi

# Round 3: "error-handling" reappears alongside "performance".
R3='[{"source":"code-reviewer","category":"error-handling","severity":"HIGH","claim":"still missing","line":1},{"source":"deterministic","category":"lint","severity":"LOW","claim":"whitespace","line":2}]'
ql record-round "core/engine.py" 3 "$R3"

assert_valid_json "after 3 rounds"

# systemic on rounds 2+3: "performance" and "error-handling" overlap between rounds 2 and 3?
# Round 2: performance. Round 3: error-handling, lint.
# Intersection = empty (performance not in round 3; error-handling not in round 2).
systemic_2_3="$(ql systemic "core/engine.py")"
if [[ -z "$systemic_2_3" ]]; then
  pass "systemic: no output when rounds 2 and 3 share no categories"
else
  fail "systemic: no output when rounds 2 and 3 share no categories (got '$systemic_2_3')"
fi

# Now record round 4 that repeats "error-handling" from round 3.
R4='[{"source":"code-reviewer","category":"error-handling","severity":"MEDIUM","claim":"edge case missed","line":7}]'
ql record-round "core/engine.py" 4 "$R4"

assert_valid_json "after 4 rounds"

systemic_3_4="$(ql systemic "core/engine.py")"
if echo "$systemic_3_4" | grep -q "error-handling"; then
  pass "systemic: fires on 'error-handling' repeated in rounds 3 and 4"
else
  fail "systemic: fires on 'error-handling' repeated in rounds 3 and 4 (got '$systemic_3_4')"
fi

# ---------------------------------------------------------------------------
# Case 6: status subcommand
# ---------------------------------------------------------------------------
echo "--- Case 6: status ---"

rm -f "$STATE_FILE"
ql scope "mod/x.py" >/dev/null

# status for unknown file returns empty object.
status_empty="$(ql status "mod/unknown.py")"
if printf '%s' "$status_empty" | jq -e 'type == "object"' >/dev/null 2>&1; then
  pass "status unknown file returns JSON object"
else
  fail "status unknown file returns JSON object (got '$status_empty')"
fi

F1='[{"source":"code-reviewer","category":"style","severity":"LOW","claim":"naming","line":3}]'
ql record-round "mod/x.py" 1 "$F1"

status_out="$(ql status "mod/x.py")"
s_rounds="$(printf '%s' "$status_out" | jq -r '.rounds')"
s_lfc="$(printf '%s' "$status_out" | jq -r '.lastFindingCount')"
s_bc="$(printf '%s' "$status_out" | jq -r '.blockingCount')"
s_clean="$(printf '%s' "$status_out" | jq -r '.clean')"

if [[ "$s_rounds" == "1" ]]; then
  pass "status: rounds=1"
else
  fail "status: rounds=1 (got $s_rounds)"
fi
# code-reviewer LOW is still blocking (any code-reviewer finding blocks).
if [[ "$s_bc" == "1" ]]; then
  pass "status: blockingCount=1 (code-reviewer LOW)"
else
  fail "status: blockingCount=1 (got $s_bc)"
fi
if [[ "$s_clean" == "false" ]]; then
  pass "status: clean=false before mark-clean"
else
  fail "status: clean=false before mark-clean (got $s_clean)"
fi

# Global status (all files).
global_status="$(ql status)"
if printf '%s' "$global_status" | jq -e 'type == "object"' >/dev/null 2>&1; then
  pass "status (global): returns JSON object"
else
  fail "status (global): returns JSON object"
fi

assert_valid_json "status assertions"

# ---------------------------------------------------------------------------
# Case 7: LOOP_SPEC_QL_STATE override honored
# ---------------------------------------------------------------------------
echo "--- Case 7: LOOP_SPEC_QL_STATE override ---"

CUSTOM_STATE="$WORK/custom-state-file.json"
LOOP_SPEC_QL_STATE="$CUSTOM_STATE" bash "$SCRIPT" scope "override/test.py" >/dev/null

if [[ -f "$CUSTOM_STATE" ]]; then
  pass "LOOP_SPEC_QL_STATE override: file created at custom path"
else
  fail "LOOP_SPEC_QL_STATE override: file NOT created at custom path"
fi

if jq . "$CUSTOM_STATE" >/dev/null 2>&1; then
  pass "LOOP_SPEC_QL_STATE override: custom state file is valid JSON"
else
  fail "LOOP_SPEC_QL_STATE override: custom state file is not valid JSON"
fi

entry="$(jq -r '."override/test.py" | type' "$CUSTOM_STATE")"
if [[ "$entry" == "object" ]]; then
  pass "LOOP_SPEC_QL_STATE override: entry written to custom state file"
else
  fail "LOOP_SPEC_QL_STATE override: entry NOT in custom state file (got $entry)"
fi

# Default state file must NOT have the override entry (different path used).
if [[ -f "$STATE_FILE" ]]; then
  default_entry="$(jq -r '."override/test.py"' "$STATE_FILE")"
  if [[ "$default_entry" == "null" ]]; then
    pass "LOOP_SPEC_QL_STATE override: default state file unaffected"
  else
    fail "LOOP_SPEC_QL_STATE override: default state file unexpectedly contains override entry"
  fi
else
  pass "LOOP_SPEC_QL_STATE override: default state file unaffected (does not exist)"
fi

# ---------------------------------------------------------------------------
# Case 8: state file valid JSON after every command (comprehensive check)
# ---------------------------------------------------------------------------
echo "--- Case 8: JSON validity after every command ---"

rm -f "$STATE_FILE"

ql scope "final/check.py" >/dev/null
assert_valid_json "after scope"

ql record-round "final/check.py" 1 '[]' >/dev/null
assert_valid_json "after record-round (empty)"

ql record-round "final/check.py" 2 \
  '[{"source":"security-reviewer","category":"authz","severity":"CRITICAL","claim":"no auth check","line":99}]' >/dev/null
assert_valid_json "after record-round (CRITICAL)"

# mark-clean should be refused here.
rc=0
ql mark-clean "final/check.py" 2 >/dev/null 2>&1 || rc=$?
assert_valid_json "after refused mark-clean (JSON must stay valid)"

# Clear findings and mark clean.
ql record-round "final/check.py" 3 '[]' >/dev/null
ql mark-clean "final/check.py" 3 >/dev/null
assert_valid_json "after successful mark-clean"

ql status >/dev/null
assert_valid_json "after status"

ql systemic "final/check.py" >/dev/null || true
assert_valid_json "after systemic"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
