#!/usr/bin/env bash
# Unit tests for lib/conflict-monitor.sh — four signals, no side effects.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/lib/conflict-monitor.sh"
WORK="${TMPDIR:-/tmp}/loop-spec-conflict-monitor.$$"
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

[[ -x "$SCRIPT" || -f "$SCRIPT" ]] || { echo "FAIL: missing $SCRIPT"; exit 1; }

# --- no conflict ---
out="$(bash "$SCRIPT" check --test-exit 0 --gate-log /dev/null --consecutive 0)"
rc=$?
check "no-conflict exit 0" "0" "$rc"
check_match "no-conflict shape" '^conflict=no reason=' "$out"

# --- failing test command ---
out="$(bash "$SCRIPT" check --test-exit 1 --gate-log /dev/null --consecutive 0)"
rc=$?
check "test-exit conflict exit 0" "0" "$rc"
check_match "test-exit conflict" '^conflict=yes reason=test-exit:' "$out"

# --- [major] gate finding ---
printf 'gate: acceptance\n[major] criteria uncovered\n' > "$WORK/gate.log"
out="$(bash "$SCRIPT" check --test-exit 0 --gate-log "$WORK/gate.log" --consecutive 0)"
check_match "major-gate conflict" '^conflict=yes reason=major-gate:' "$out"

# --- contradictory agent outputs ---
printf 'verdict=pass\n' > "$WORK/a.out"
printf 'verdict=fail\n' > "$WORK/b.out"
out="$(bash "$SCRIPT" check --test-exit 0 --gate-log /dev/null \
  --agent-outputs "$WORK/a.out" "$WORK/b.out" --consecutive 0)"
check_match "contradiction conflict" '^conflict=yes reason=contradiction:' "$out"

# --- N consecutive identical failures (default N=2 from strategy-rotation) ---
out="$(env -u LOOP_SPEC_STRATEGY_ROTATION_THRESHOLD bash "$SCRIPT" check \
  --test-exit 0 --gate-log /dev/null --consecutive 2)"
check_match "consecutive default threshold" '^conflict=yes reason=consecutive-failures:' "$out"

out="$(LOOP_SPEC_STRATEGY_ROTATION_THRESHOLD=5 bash "$SCRIPT" check \
  --test-exit 0 --gate-log /dev/null --consecutive 2)"
check_match "consecutive below configured N is no" '^conflict=no reason=' "$out"

out="$(LOOP_SPEC_STRATEGY_ROTATION_THRESHOLD=5 bash "$SCRIPT" check \
  --test-exit 0 --gate-log /dev/null --consecutive 5)"
check_match "consecutive at configured N is yes" '^conflict=yes reason=consecutive-failures:' "$out"

# --- checkpoint ledger untouched ---
printf 'ledger-v1\nrecord-1\n' > "$WORK/ledger.jsonl"
before="$(cksum "$WORK/ledger.jsonl")"
bash "$SCRIPT" check --test-exit 1 --gate-log /dev/null --consecutive 0 \
  --checkpoint-ledger "$WORK/ledger.jsonl" >/dev/null
after="$(cksum "$WORK/ledger.jsonl")"
check "checkpoint ledger unchanged on conflict=yes" "$before" "$after"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
