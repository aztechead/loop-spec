#!/usr/bin/env bash
# Unit tests for lib/effort-probe.sh — deterministic inputs, fail-safe system2.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/lib/effort-probe.sh"
WORK="${TMPDIR:-/tmp}/loop-spec-effort-probe.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"
PASS=0; FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL + 1))
  fi
}

check_match() {
  local name="$1" pattern="$2" actual="$3"
  if [[ "$actual" =~ $pattern ]]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected match /$pattern/, got '$actual')"; FAIL=$((FAIL + 1))
  fi
}

[[ -f "$SCRIPT" ]] || { echo "FAIL: missing $SCRIPT"; exit 1; }

# Helper: run with scrubbed overrides
run_probe() {
  env -u LOOP_SPEC_EFFORT -u LOOP_SPEC_EFFORT_PHASE -u LOOP_SPEC_EFFORT_NODE \
    bash "$SCRIPT" "$@"
}

# --- shape ---
out="$(run_probe --node-kind function --security-signal none --width 1 \
  --changed-files 1 --task-count 1 --attempt 0 --authorizes-delivery false)"
rc=$?
check "well-formed exit 0" "0" "$rc"
check_match "single-line shape" '^mode=(system1|system2) reason=' "$out"
lines="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
check "exactly one stdout line" "1" "$lines"

# --- system1: small habitual function node ---
out="$(run_probe --node-kind function --security-signal none --width 1 \
  --changed-files 1 --task-count 1 --attempt 0 --authorizes-delivery false)"
check_match "small function -> system1" '^mode=system1 reason=' "$out"

# --- security signal forces system2 ---
out="$(run_probe --node-kind function --security-signal credential --width 1 \
  --changed-files 1 --task-count 1 --attempt 0 --authorizes-delivery false)"
check_match "security-signal -> system2" '^mode=system2 reason=.*security' "$out"

# --- wide DAG ---
out="$(run_probe --node-kind agent --security-signal none --width 4 \
  --changed-files 2 --task-count 5 --attempt 0 --authorizes-delivery false)"
check_match "wide DAG -> system2" '^mode=system2 reason=.*width' "$out"

# --- many changed files ---
out="$(run_probe --node-kind agent --security-signal none --width 1 \
  --changed-files 20 --task-count 2 --attempt 0 --authorizes-delivery false)"
check_match "many files -> system2" '^mode=system2 reason=.*changed-files' "$out"

# --- many tasks ---
out="$(run_probe --node-kind agent --security-signal none --width 1 \
  --changed-files 1 --task-count 10 --attempt 0 --authorizes-delivery false)"
check_match "many tasks -> system2" '^mode=system2 reason=.*task-count' "$out"

# --- prior attempt ---
out="$(run_probe --node-kind function --security-signal none --width 1 \
  --changed-files 1 --task-count 1 --attempt 1 --authorizes-delivery false)"
check_match "retry attempt -> system2" '^mode=system2 reason=.*attempt' "$out"

# --- delivery-authorizing node ---
out="$(run_probe --node-kind agent --security-signal none --width 1 \
  --changed-files 1 --task-count 1 --attempt 0 --authorizes-delivery true)"
check_match "delivery auth -> system2" '^mode=system2 reason=.*deliver' "$out"

# --- unresolved input fails safe to system2 ---
# One case per unresolvable input. A single representative case leaves the other
# fail-safe branches free to flip to system1 undetected, which is the bug this
# covers: the probe must fail toward deliberation on EVERY unresolved input.
out="$(run_probe --node-kind function --security-signal none --width unknown \
  --changed-files 1 --task-count 1 --attempt 0 --authorizes-delivery false)"
check_match "unresolved width -> system2" '^mode=system2 reason=.*width' "$out"

out="$(run_probe --node-kind function --security-signal none --width 1 \
  --changed-files x --task-count 1 --attempt 0 --authorizes-delivery false)"
check_match "unresolved changed-files -> system2" '^mode=system2 reason=.*changed-files' "$out"

out="$(run_probe --node-kind function --security-signal none --width 1 \
  --changed-files 1 --task-count x --attempt 0 --authorizes-delivery false)"
check_match "unresolved task-count -> system2" '^mode=system2 reason=.*task-count' "$out"

out="$(run_probe --node-kind function --security-signal none --width 1 \
  --changed-files 1 --task-count 1 --attempt x --authorizes-delivery false)"
check_match "unresolved attempt -> system2" '^mode=system2 reason=.*attempt' "$out"

out="$(run_probe --node-kind function --security-signal none --width 1 \
  --changed-files 1 --task-count 1 --attempt 0 --authorizes-delivery maybe)"
check_match "unresolved authorizes-delivery -> system2" '^mode=system2 reason=.*authorizes-delivery' "$out"

out="$(run_probe --node-kind wombat --security-signal none --width 1 \
  --changed-files 1 --task-count 1 --attempt 0 --authorizes-delivery false)"
check_match "unresolved node-kind -> system2" '^mode=system2 reason=.*node-kind' "$out"

# --- global override both directions ---
out="$(env -u LOOP_SPEC_EFFORT_PHASE -u LOOP_SPEC_EFFORT_NODE \
  LOOP_SPEC_EFFORT=system1 bash "$SCRIPT" --node-kind agent --security-signal credential \
  --width 9 --changed-files 99 --task-count 99 --attempt 3 --authorizes-delivery true)"
check_match "LOOP_SPEC_EFFORT=system1 overrides" '^mode=system1 reason=.*override' "$out"

out="$(env -u LOOP_SPEC_EFFORT_PHASE -u LOOP_SPEC_EFFORT_NODE \
  LOOP_SPEC_EFFORT=system2 bash "$SCRIPT" --node-kind function --security-signal none \
  --width 1 --changed-files 1 --task-count 1 --attempt 0 --authorizes-delivery false)"
check_match "LOOP_SPEC_EFFORT=system2 overrides" '^mode=system2 reason=.*override' "$out"

# --- per-node beats per-phase beats global ---
out="$(LOOP_SPEC_EFFORT=system2 LOOP_SPEC_EFFORT_PHASE=system2 LOOP_SPEC_EFFORT_NODE=system1 \
  bash "$SCRIPT" --node-kind agent --security-signal credential --width 9 \
  --changed-files 99 --task-count 99 --attempt 3 --authorizes-delivery true \
  --phase execute --node-id execute.task-001)"
check_match "per-node override wins" '^mode=system1 reason=.*override.*node' "$out"

out="$(LOOP_SPEC_EFFORT=system2 LOOP_SPEC_EFFORT_PHASE=system1 \
  env -u LOOP_SPEC_EFFORT_NODE \
  bash "$SCRIPT" --node-kind agent --security-signal credential --width 9 \
  --changed-files 99 --task-count 99 --attempt 3 --authorizes-delivery true \
  --phase execute)"
check_match "per-phase override beats global" '^mode=system1 reason=.*override.*phase' "$out"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
