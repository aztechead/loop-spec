#!/usr/bin/env bash
# Tests for lib/cycle-result.sh
set -uo pipefail

LIB="$(cd "$(dirname "$0")/../.." && pwd)/lib/cycle-result.sh"
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

WORK="${TMPDIR:-/tmp}/loop-spec-cycle-result.$$"
trap 'rm -rf "$WORK"' EXIT

# Build a minimal feature.json fixture shaped like .loop-spec/features/<slug>/
# (two levels deep so ../../ resolves to $WORK/.loop-spec)
LOOP_DIR="$WORK/.loop-spec"
FEAT_DIR="$LOOP_DIR/features/my-feature"
mkdir -p "$FEAT_DIR"

FIXTURE_FJ="$(jq -n '{
  schemaVersion: 7,
  slug: "my-feature",
  feature_title: "Add rate limiting",
  currentPhase: "iterate",
  branch: "feat/my-feature",
  baseBranch: "main",
  prUrl: null,
  checkpointPrUrl: null,
  autonomous: false,
  createdAt: "2026-01-01T00:00:00Z",
  updatedAt: "2026-01-01T01:00:00Z",
  warnings: [],
  iterate: {used: 2, maxIterations: 10}
}')"
printf '%s\n' "$FIXTURE_FJ" > "$FEAT_DIR/feature.json"

# Case A: write --status completed produces valid result.json
bash "$LIB" write "$FEAT_DIR" --status completed >/dev/null 2>&1
check "A: result.json created" "1" "$([[ -f "$FEAT_DIR/result.json" ]] && echo 1 || echo 0)"
check "A: valid JSON" "0" "$(jq . "$FEAT_DIR/result.json" >/dev/null 2>&1; echo $?)"
check "A: schema=1" "1" "$(jq '.schema' "$FEAT_DIR/result.json")"
check "A: status=completed" "completed" "$(jq -r '.status' "$FEAT_DIR/result.json")"
check "A: slug" "my-feature" "$(jq -r '.slug' "$FEAT_DIR/result.json")"
check "A: feature_title" "Add rate limiting" "$(jq -r '.feature_title' "$FEAT_DIR/result.json")"
check "A: iterations.used=2" "2" "$(jq '.iterations.used' "$FEAT_DIR/result.json")"
check "A: iterations.max=10" "10" "$(jq '.iterations.max' "$FEAT_DIR/result.json")"
check "A: branch" "feat/my-feature" "$(jq -r '.branch' "$FEAT_DIR/result.json")"
check "A: baseBranch" "main" "$(jq -r '.baseBranch' "$FEAT_DIR/result.json")"
check "A: finishedAt present" "1" "$([[ "$(jq -r '.finishedAt' "$FEAT_DIR/result.json")" != "null" ]] && echo 1 || echo 0)"

# Case B: converged=true with empty warnings
check "B: converged=true on clean completion" "true" "$(jq '.converged' "$FEAT_DIR/result.json")"

# Case C: converged=false when warnings contains iterate-budget-spent:
printf '%s\n' "$(jq '.warnings = ["iterate-budget-spent: foo gap"]' "$FEAT_DIR/feature.json")" > "$FEAT_DIR/feature.json"
bash "$LIB" write "$FEAT_DIR" --status completed >/dev/null 2>&1
check "C: converged=false with iterate-budget-spent warning" "false" "$(jq '.converged' "$FEAT_DIR/result.json")"
check "C: warnings array present" "1" "$(jq '.warnings | length' "$FEAT_DIR/result.json")"

# Restore clean warnings
printf '%s\n' "$FIXTURE_FJ" > "$FEAT_DIR/feature.json"

# Case D: --pr-url wins over feature.json .prUrl
printf '%s\n' "$(jq '.prUrl = "https://github.com/old/pr/1"' "$FEAT_DIR/feature.json")" > "$FEAT_DIR/feature.json"
bash "$LIB" write "$FEAT_DIR" --status completed --pr-url "https://github.com/new/pr/2" >/dev/null 2>&1
check "D: --pr-url wins over feature.json prUrl" "https://github.com/new/pr/2" "$(jq -r '.prUrl' "$FEAT_DIR/result.json")"

# Restore fixture
printf '%s\n' "$FIXTURE_FJ" > "$FEAT_DIR/feature.json"

# Case E: feature.json .prUrl used when no --pr-url arg
printf '%s\n' "$(jq '.prUrl = "https://github.com/feat/pr/5"' "$FEAT_DIR/feature.json")" > "$FEAT_DIR/feature.json"
bash "$LIB" write "$FEAT_DIR" --status completed >/dev/null 2>&1
check "E: feature.json prUrl used when no arg" "https://github.com/feat/pr/5" "$(jq -r '.prUrl' "$FEAT_DIR/result.json")"

# Restore fixture
printf '%s\n' "$FIXTURE_FJ" > "$FEAT_DIR/feature.json"

# Case F: last-result.json copy created at the right relative location
bash "$LIB" write "$FEAT_DIR" --status completed >/dev/null 2>&1
check "F: last-result.json created" "1" "$([[ -f "$LOOP_DIR/last-result.json" ]] && echo 1 || echo 0)"
check "F: last-result.json has same slug" "my-feature" "$(jq -r '.slug' "$LOOP_DIR/last-result.json")"

# Case G: missing feature.json → exit 0 + no result.json written
mkdir -p "$WORK/empty-feat"
rm -f "$WORK/empty-feat/result.json"
ec=0
bash "$LIB" write "$WORK/empty-feat" --status completed >/dev/null 2>&1 || ec=$?
check "G: missing feature.json exits 0" "0" "$ec"
check "G: no result.json on missing feature.json" "0" "$([[ -f "$WORK/empty-feat/result.json" ]] && echo 1 || echo 0)"

# Case H: bad --status → exit 0 + no result.json written
printf '%s\n' "$FIXTURE_FJ" > "$FEAT_DIR/feature.json"
rm -f "$FEAT_DIR/result.json"
ec=0
bash "$LIB" write "$FEAT_DIR" --status invalid_status >/dev/null 2>&1 || ec=$?
check "H: bad --status exits 0" "0" "$ec"
check "H: no result.json on bad status" "0" "$([[ -f "$FEAT_DIR/result.json" ]] && echo 1 || echo 0)"

# Case I: the matching event line appears in events.jsonl
printf '%s\n' "$FIXTURE_FJ" > "$FEAT_DIR/feature.json"
rm -f "$FEAT_DIR/events.jsonl"
bash "$LIB" write "$FEAT_DIR" --status completed >/dev/null 2>&1
check "I: events.jsonl written" "1" "$([[ -f "$FEAT_DIR/events.jsonl" ]] && echo 1 || echo 0)"
evt_event="$(tail -1 "$FEAT_DIR/events.jsonl" | jq -r '.event' 2>/dev/null || echo MISSING)"
check "I: event matches status" "completed" "$evt_event"

# Case J: --reason persisted in result.json; no --reason arg produces null
printf '%s\n' "$FIXTURE_FJ" > "$FEAT_DIR/feature.json"
bash "$LIB" write "$FEAT_DIR" --status paused --reason "user pause" >/dev/null 2>&1
check "J: reason in result.json" "user pause" "$(jq -r '.reason' "$FEAT_DIR/result.json")"
printf '%s\n' "$FIXTURE_FJ" > "$FEAT_DIR/feature.json"
bash "$LIB" write "$FEAT_DIR" --status completed >/dev/null 2>&1
check "J2: no reason arg → reason is null" "null" "$(jq -r '.reason' "$FEAT_DIR/result.json")"

# Case K: converged=false for iterate-terminal: warning
printf '%s\n' "$(jq '.warnings = ["iterate-terminal: gap closed as terminal"]' "$FEAT_DIR/feature.json")" > "$FEAT_DIR/feature.json"
bash "$LIB" write "$FEAT_DIR" --status completed >/dev/null 2>&1
check "K: converged=false with iterate-terminal warning" "false" "$(jq '.converged' "$FEAT_DIR/result.json")"

# Case L: no --status → exit 0
printf '%s\n' "$FIXTURE_FJ" > "$FEAT_DIR/feature.json"
ec=0
bash "$LIB" write "$FEAT_DIR" >/dev/null 2>&1 || ec=$?
check "L: missing --status exits 0" "0" "$ec"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
