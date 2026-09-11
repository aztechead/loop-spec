#!/usr/bin/env bash
# Unit tests for lib/quality-loop-state.sh
# Standalone: exit 0 on all pass, exit 1 on any failure.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO_ROOT/lib/quality-loop-state.sh"
CYCLE_DRIVER="$REPO_ROOT/lib/cycle-driver.sh"
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

# Build a real schema-7 feature the way the cycle makes one (mirrors
# tests/lib/phase-exit.test.sh), for the cycle-participation cases below.
# Prints the feature directory.
make_feature() {
  local work="$1" repo="$1/repo"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  (
    export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
    export LOOP_SPEC_HARNESS=codex LOOP_SPEC_TEAMS_MODE=none LOOP_SPEC_WORKFLOWS_AVAILABLE=0 LOOP_SPEC_CHECKPOINT_PR=0
    unset LOOP_SPEC_AUTONOMOUS LOOP_SPEC_NON_INTERACTIVE
    cd "$repo" || exit 1
    bash "$CYCLE_DRIVER" start --dir "$repo" -- my feature >/dev/null 2>&1 || true
    bash "$CYCLE_DRIVER" init --dir "$repo" --slug my-feature --title "my feature" \
      --style auto --profile standard --autonomous 0 >/dev/null 2>&1 || true
  )
  printf '%s' "$repo/.loop-spec/features/my-feature"
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
# Case 9: cycle participation -- a real feature dir, publication generation
# ---------------------------------------------------------------------------
echo "--- Case 9: cycle participation ---"

# (b) record-round then mark-clean succeed; generation advances by one per
# accepted publication.
FDB="$(make_feature "$WORK/cycle-b")"
TOK_B1="$WORK/cycle-b/tok1.json"
# cycle-driver.sh init is itself a publication participant (task-004 WP3): it
# bootstraps the legacy contract as part of init, so a feature is never without one
# by the time the cycle can touch it -- record-round and mark-clean below each then
# advance that same contract by one generation, rather than establishing it lazily.
gen0="$(jq -r '.artifactPublication.generation // "absent"' "$FDB/feature.json")"
if [[ "$gen0" == "0" ]]; then
  pass "in-cycle: init bootstraps the publication contract at generation 0"
else
  fail "in-cycle: init bootstraps the publication contract at generation 0 (got generation=$gen0)"
fi

LOOP_SPEC_QL_STATE="$FDB/quality-loop.json" LOOP_SPEC_PUBLICATION_TOKEN_OUTPUT="$TOK_B1" \
  bash "$SCRIPT" record-round "app/main.py" 1 '[]' >/dev/null
gen1="$(jq -r '.artifactPublication.generation' "$FDB/feature.json")"
if [[ "$gen1" == "1" ]]; then
  pass "in-cycle: record-round's accepted publication bumps generation to 1"
else
  fail "in-cycle: record-round's accepted publication bumps generation to 1 (got $gen1)"
fi
if [[ -f "$FDB/quality-loop.json" ]]; then
  pass "in-cycle: sidecar lands at <feature dir>/quality-loop.json"
else
  fail "in-cycle: sidecar lands at <feature dir>/quality-loop.json"
fi
if [[ -s "$TOK_B1" ]]; then
  pass "in-cycle: record-round returns the accepted refresh"
else
  fail "in-cycle: record-round returns the accepted refresh"
fi

TOK_B2="$WORK/cycle-b/tok2.json"
LOOP_SPEC_QL_STATE="$FDB/quality-loop.json" LOOP_SPEC_PUBLICATION_TOKEN="$TOK_B1" \
  LOOP_SPEC_PUBLICATION_TOKEN_OUTPUT="$TOK_B2" bash "$SCRIPT" mark-clean "app/main.py" 1 >/dev/null
gen2="$(jq -r '.artifactPublication.generation' "$FDB/feature.json")"
if [[ "$gen2" == "2" ]]; then
  pass "in-cycle: mark-clean's accepted publication bumps generation to 2"
else
  fail "in-cycle: mark-clean's accepted publication bumps generation to 2 (got $gen2)"
fi
clean_b="$(jq -r '."app/main.py".clean' "$FDB/quality-loop.json")"
if [[ "$clean_b" == "true" ]]; then
  pass "in-cycle: sidecar reflects mark-clean"
else
  fail "in-cycle: sidecar reflects mark-clean (got $clean_b)"
fi

# (c) an old held token: run mark-clean with it after an unrelated write bumps
# the generation. Refused as stale; nothing changes.
FDC="$(make_feature "$WORK/cycle-c")"
TOK_C1="$WORK/cycle-c/tok1.json"
LOOP_SPEC_QL_STATE="$FDC/quality-loop.json" LOOP_SPEC_PUBLICATION_TOKEN_OUTPUT="$TOK_C1" \
  bash "$SCRIPT" record-round "app/main.py" 1 '[]' >/dev/null
# The unrelated write is its own participant (task-009 strict enforcement): it begins
# its own operation rather than bypassing the ingress token entirely.
TOK_C_BUMP="$WORK/cycle-c/tok-bump.json"
python3 "$REPO_ROOT/lib/feature_write.py" ingress "$FDC" > "$TOK_C_BUMP"
bash "$REPO_ROOT/lib/feature-write.sh" set "$FDC" warnings '["x"]' --token "$TOK_C_BUMP" >/dev/null
before_sidecar_c="$(cat "$FDC/quality-loop.json")"
rc=0
out_c="$(LOOP_SPEC_QL_STATE="$FDC/quality-loop.json" LOOP_SPEC_PUBLICATION_TOKEN="$TOK_C1" \
  bash "$SCRIPT" mark-clean "app/main.py" 1 2>&1)" || rc=$?
if [[ "$rc" -eq 1 ]]; then
  pass "stale token: mark-clean exits 1"
else
  fail "stale token: mark-clean exits 1 (got exit $rc)"
fi
if grep -q "stale publication token" <<<"$out_c"; then
  pass "stale token: message names it"
else
  fail "stale token: message names it (got '$out_c')"
fi
after_sidecar_c="$(cat "$FDC/quality-loop.json")"
if [[ "$before_sidecar_c" == "$after_sidecar_c" ]]; then
  pass "stale token: sidecar bytes unchanged"
else
  fail "stale token: sidecar bytes unchanged"
fi
status_c="$(LOOP_SPEC_QL_STATE="$FDC/quality-loop.json" bash "$SCRIPT" status "app/main.py")"
clean_c="$(jq -r '.clean' <<<"$status_c")"
if [[ "$clean_c" == "false" ]]; then
  pass "stale token: status still reports clean=false"
else
  fail "stale token: status still reports clean=false (got $clean_c)"
fi

# (d) an in-progress migration marker refuses record-round before writing.
FDD="$(make_feature "$WORK/cycle-d")"
bash "$REPO_ROOT/lib/feature-write.sh" ingress "$FDD" >/dev/null
digest64="$(printf 'a%.0s' {1..64})"
jq --arg d "$digest64" \
  '.artifactPublication.migration = {"id":"m1","previewDigest":$d,"phase":"marker","originalGeneration":0,"publishedHashes":{}}' \
  "$FDD/feature.json" > "$FDD/feature.json.tmp"
mv "$FDD/feature.json.tmp" "$FDD/feature.json"
gen_before_d="$(jq -r '.artifactPublication.generation' "$FDD/feature.json")"
rc=0
LOOP_SPEC_QL_STATE="$FDD/quality-loop.json" bash "$SCRIPT" record-round "app/main.py" 1 '[]' >/dev/null 2>&1 || rc=$?
if [[ "$rc" -eq 1 ]]; then
  pass "migration marker: record-round refuses"
else
  fail "migration marker: record-round refuses (got exit $rc)"
fi
if [[ -f "$FDD/quality-loop.json" ]]; then
  fail "migration marker: no sidecar written"
else
  pass "migration marker: no sidecar written"
fi
gen_after_d="$(jq -r '.artifactPublication.generation' "$FDD/feature.json")"
if [[ "$gen_before_d" == "$gen_after_d" ]]; then
  pass "migration marker: generation unchanged"
else
  fail "migration marker: generation unchanged (before=$gen_before_d after=$gen_after_d)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
