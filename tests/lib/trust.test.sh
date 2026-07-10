#!/usr/bin/env bash
# Tests for lib/trust.sh (graduated-trust track record, ROADMAP-3.0 D1).
# Table-driven level computation + the fail-closed invariants.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/lib/trust.sh"
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

WORK="${TMPDIR:-/tmp}/trust-test.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"

# metrics fixture builder: mk <streak> <pmfr> <live> <watch>  (each may be "null")
mk() {
  jq -n --argjson streak "$1" --argjson pmfr "$2" --argjson live "$3" --argjson watch "$4" '
    {schema: 1, source: "fixture", runs: 30, converged: $streak,
     convergenceRate: 0.9, firstPassRate: 0.5,
     consecutiveConverged: $streak, postMergeFixRate: $pmfr,
     verifyFailureRate: null, sentinelNeedsHumanRate: null}
    + (if $live != null then {liveVerifyPassing: $live} else {} end)
    + (if $watch != null then {watchWindowClean: $watch} else {} end)' \
    > "$WORK/metrics.json"
}

level_of() { bash "$SCRIPT" level --json --metrics-json "$WORK/metrics.json" --conf "${1:-$WORK/no-conf}" | jq -r '.level'; }

# ── Table-driven level computation ────────────────────────────────────────────
# streak pmfr live watch -> expected level (defaults: L1=5, L2=10, L3=20)
table=(
  "0     null  null  null  L0"
  "4     0     true  true  L0"
  "5     0     null  null  L1"
  "5     null  null  null  L0"
  "5     0.1   true  true  L0"
  "9     0     true  true  L1"
  "10    0     true  null  L2"
  "10    0     false null  L1"
  "10    0     null  null  L1"
  "19    0     true  true  L2"
  "20    0     true  true  L3"
  "20    0     true  false L2"
  "20    0     true  null  L2"
  "20    0     null  true  L1"
  "100   0     true  true  L3"
)
for row in "${table[@]}"; do
  read -r streak pmfr live watch expected <<<"$row"
  mk "$streak" "$pmfr" "$live" "$watch"
  check "table: streak=$streak pmfr=$pmfr live=$live watch=$watch -> $expected" \
    "$expected" "$(level_of)"
done

# ── The L0-default-with-empty-telemetry invariant ─────────────────────────────
EMPTY_ROOT="$WORK/empty/.loop-spec"
mkdir -p "$EMPTY_ROOT"
out="$(bash "$SCRIPT" level --json --root "$EMPTY_ROOT" --conf "$WORK/no-conf")"
check "empty telemetry -> L0" "L0" "$(jq -r '.level' <<<"$out")"
check "empty telemetry streak 0" "0" "$(jq '.inputs.consecutiveConverged' <<<"$out")"

# ── Demotion is instant: one non-converged run resets the streak input ────────
# (the streak is recomputed from digests by the metrics contract; trust.sh
# must reflect the reset immediately, with no memory of the old level)
mk 5 0 null null
check "before: L1" "L1" "$(level_of)"
mk 0 0 null null
check "one bad run: back to L0, no hysteresis" "L0" "$(level_of)"

# ── trust.conf overrides thresholds ───────────────────────────────────────────
printf 'L1_STREAK=2\nL2_STREAK=3\n' > "$WORK/trust.conf"
mk 2 0 null null
check "conf: lowered L1 threshold" "L1" "$(level_of "$WORK/trust.conf")"
mk 3 0 true null
check "conf: lowered L2 threshold" "L2" "$(level_of "$WORK/trust.conf")"

# ── Evidence lines name the fail-closed reads ─────────────────────────────────
mk 5 null null null
out="$(bash "$SCRIPT" level --metrics-json "$WORK/metrics.json" --conf "$WORK/no-conf")"
check "human output states level" "1" "$(grep -c '^trust level: L0' <<<"$out")"
check "evidence: pmfr fail-closed named" "1" "$(grep -c 'postMergeFixRate: unknown' <<<"$out")"
check "evidence: live-verify fail-closed named" "1" "$(grep -c 'liveVerify: unavailable' <<<"$out")"
check "evidence: watch fail-closed named" "1" "$(grep -c 'watchWindow: unavailable' <<<"$out")"
check "evidence: streak with thresholds" "1" "$(grep -c 'consecutiveConverged: 5 (L1 needs >= 5' <<<"$out")"

# ── json shape ────────────────────────────────────────────────────────────────
out="$(bash "$SCRIPT" level --json --metrics-json "$WORK/metrics.json" --conf "$WORK/no-conf")"
check "json: schema" "1" "$(jq '.schema' <<<"$out")"
check "json: key set" "evidence inputs level schema" "$(jq -r 'keys | sort | join(" ")' <<<"$out")"

# ── bad invocations ───────────────────────────────────────────────────────────
ec=0; bash "$SCRIPT" authorize >/dev/null 2>&1 || ec=$?
check "unshipped verb exits 2" "2" "$ec"
ec=0; bash "$SCRIPT" level --metrics-json "$WORK/absent.json" >/dev/null 2>&1 || ec=$?
check "missing metrics file exits 2" "2" "$ec"
echo 'not json' > "$WORK/bad.json"
ec=0; bash "$SCRIPT" level --metrics-json "$WORK/bad.json" >/dev/null 2>&1 || ec=$?
check "corrupt metrics file exits 2" "2" "$ec"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
