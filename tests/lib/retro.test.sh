#!/usr/bin/env bash
# Tests for lib/retro.sh (deterministic retrospective miner)
set -uo pipefail

LIB="$(cd "$(dirname "$0")/../.." && pwd)/lib/retro.sh"
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

WORK="${TMPDIR:-/tmp}/loop-spec-retro.$$"
trap 'rm -rf "$WORK"' EXIT
ROOT="$WORK/.loop-spec"

mkfeat() { # mkfeat <slug> <converged:true|false|null> <status|null> <iters> <events-lines...>
  local slug="$1" converged="$2" status="$3" iters="$4"; shift 4
  local d="$ROOT/features/$slug"
  mkdir -p "$d"
  printf '{"schemaVersion":7,"slug":"%s","iterate":{"used":%s,"maxIterations":10}}\n' "$slug" "$iters" > "$d/feature.json"
  if [[ "$status" != "null" ]]; then
    printf '{"schema":1,"slug":"%s","status":"%s","converged":%s,"iterations":{"used":%s,"max":10}}\n' \
      "$slug" "$status" "$converged" "$iters" > "$d/result.json"
  fi
  : > "$d/events.jsonl"
  local line
  for line in "$@"; do printf '%s\n' "$line" >> "$d/events.jsonl"; done
}

gap_ev() { printf '{"ts":"2026-07-08T10:00:00Z","slug":"x","event":"iterate_verdict","phase":"iterate","data":{"verdict":"not-converged","iteration":1,"gap":"%s"}}' "$1"; }
cap_ev() { printf '{"ts":"2026-07-08T10:00:00Z","slug":"x","event":"gate_round","phase":"discuss","data":{"gate":"%s","round":2}}' "$1"; }

# ── Fixture set: 3 features with plan gaps, 2 with spec-critique cap,
#    1 execute gap (below threshold), plus first-pass converged features ──────
mkfeat f1 true  completed 2 "$(gap_ev plan)" "$(cap_ev spec-critique)"
mkfeat f2 true  completed 3 "$(gap_ev plan)" "$(cap_ev spec-critique)"
mkfeat f3 false completed 10 "$(gap_ev plan)" "$(gap_ev execute)"
mkfeat f4 true  completed 1
mkfeat f5 true  completed 0
mkfeat f6 true  completed 1
mkfeat f7 false completed 10

# ── Case 1: plan-gap rule candidate fires at threshold 3 ─────────────────────
out="$(bash "$LIB" report --root "$ROOT" --json)"
check "1: valid json" "1" "$(jq -e 'type == "array"' >/dev/null 2>&1 <<<"$out" && echo 1 || echo 0)"
check "1: plan gap candidate present" "1" "$(jq '[.[] | select(.id == "gap-plan-recurs")] | length' <<<"$out")"
check "1: plan evidence count 3" "3" "$(jq '.[] | select(.id == "gap-plan-recurs") | .evidence.count' <<<"$out")"
check "1: plan evidence lists features" "1" "$(jq '.[] | select(.id == "gap-plan-recurs") | .evidence.features | contains(["f1","f2","f3"])' <<<"$out" | grep -c true)"
check "1: execute gap below threshold absent" "0" "$(jq '[.[] | select(.id == "gap-execute-recurs")] | length' <<<"$out")"
check "1: gate cap below threshold absent" "0" "$(jq '[.[] | select(.id == "gate-cap-spec-critique")] | length' <<<"$out")"

# ── Case 2: threshold is tunable ──────────────────────────────────────────────
out="$(bash "$LIB" report --root "$ROOT" --json --min-repeats 2)"
check "2: gate cap fires at min-repeats 2" "1" "$(jq '[.[] | select(.id == "gate-cap-spec-critique")] | length' <<<"$out")"

# ── Case 3: model-tier suggestion (3 first-pass converged, no exec recurrence) ─
out="$(bash "$LIB" report --root "$ROOT" --json)"
check "3: model-tier suggestion present" "1" "$(jq '[.[] | select(.id == "model-tier-headroom")] | length' <<<"$out")"
check "3: suggestion kind is suggestion" "suggestion" "$(jq -r '.[] | select(.id == "model-tier-headroom") | .kind' <<<"$out")"

# ── Case 4: shipped-with-gaps info (f3 + f7) ──────────────────────────────────
check "4: shipped-with-gaps info" "2" "$(jq '.[] | select(.id == "shipped-with-gaps") | .evidence.count' <<<"$out")"
check "4: convergence info present" "1" "$(jq '[.[] | select(.id == "convergence-rate")] | length' <<<"$out")"

# ── Case 5: human report renders sections ─────────────────────────────────────
out="$(bash "$LIB" report --root "$ROOT")"
check "5: rule candidates section" "1" "$(grep -c 'RULE CANDIDATES' <<<"$out")"
check "5: suggestions section" "1" "$(grep -c 'SUGGESTIONS' <<<"$out")"
check "5: plan rule text rendered" "1" "$(grep -c 'PLAN decomposition recurs' <<<"$out")"

# ── Case 6: apply writes rules idempotently, suggestions never applied ────────
RF="$WORK/RULES.md"
out="$(LOOP_SPEC_RULES_FILE="$RF" LOOP_SPEC_GLOBAL_RULES_FILE="$WORK/global.md" bash "$LIB" apply --root "$ROOT")"
check "6: apply reports added" "1" "$(grep -c 'added: Retro: PLAN decomposition' <<<"$out")"
check "6: rule persisted" "1" "$(grep -c 'PLAN decomposition recurs' "$RF")"
check "6: suggestion NOT persisted" "0" "$(grep -c 'modelTier' "$RF")"
check "6: info NOT persisted" "0" "$(grep -c 'Convergence:' "$RF")"
out="$(LOOP_SPEC_RULES_FILE="$RF" LOOP_SPEC_GLOBAL_RULES_FILE="$WORK/global.md" bash "$LIB" apply --root "$ROOT")"
check "6: re-apply dedupes (exists)" "1" "$(grep -c 'exists: Retro: PLAN decomposition' <<<"$out")"
check "6: still exactly one rule line" "1" "$(grep -c 'PLAN decomposition recurs' "$RF")"

# ── Case 7: quiet loop -> no candidates, exit 0 ───────────────────────────────
ROOT2="$WORK/quiet/.loop-spec"
mkdir -p "$ROOT2/features"
ec=0
out="$(bash "$LIB" report --root "$ROOT2")" || ec=$?
check "7: empty root exit 0" "0" "$ec"
check "7: says not repeating itself" "1" "$(grep -c 'not repeating itself' <<<"$out")"

# ── Case 8: fleet cost info when fleet-result.json is present ─────────────────
mkdir -p "$WORK/.loop"
echo '{"total_cost_usd": 4.2, "tasks": {}}' > "$WORK/.loop/fleet-result.json"
out="$(bash "$LIB" report --root "$ROOT" --json)"
check "8: fleet cost finding" "1" "$(jq '[.[] | select(.id == "fleet-cost")] | length' <<<"$out")"

# ── Case 9: bad invocations ───────────────────────────────────────────────────
ec=0; bash "$LIB" bogus >/dev/null 2>&1 || ec=$?
check "9: unknown subcommand exit 2" "2" "$ec"
ec=0; bash "$LIB" report --min-repeats abc >/dev/null 2>&1 || ec=$?
check "9: bad min-repeats exit 2" "2" "$ec"

# ── Case 10: corrupt telemetry tolerated ──────────────────────────────────────
mkdir -p "$ROOT/features/corrupt"
echo 'not json' > "$ROOT/features/corrupt/feature.json"
echo 'not json' > "$ROOT/features/corrupt/events.jsonl"
ec=0
bash "$LIB" report --root "$ROOT" --json >/dev/null 2>&1 || ec=$?
check "10: corrupt feature tolerated exit 0" "0" "$ec"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
