#!/usr/bin/env bash
# Tests for lib/tuning.sh (closed-template parameter tuning, ROADMAP-3.0 B2).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/lib/tuning.sh"
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

WORK="${TMPDIR:-/tmp}/tuning-test.$$"
trap 'rm -rf "$WORK"' EXIT
ROOT="$WORK/.loop-spec"
mkdir -p "$ROOT"
METRICS="$WORK/metrics.json"

# metrics fixture: mk <fpStreak> <gapCounts-json> <vfClassCounts-json>
mk() {
  jq -n --argjson fp "$1" --argjson gaps "$2" --argjson vf "$3" '
    {schema: 1, source: "fixture", runs: 20, converged: 15,
     convergenceRate: 0.75, firstPassRate: 0.5,
     consecutiveConverged: $fp, consecutiveFirstPass: $fp,
     gapCounts: $gaps, verifyFailureClassCounts: $vf,
     postMergeFixRate: null, verifyFailureRate: null,
     sentinelNeedsHumanRate: null}' > "$METRICS"
}

T() { bash "$SCRIPT" "$@" --root "$ROOT" --metrics-json "$METRICS"; }

# ── quiet corpus: nothing triggers ────────────────────────────────────────────
mk 0 '{}' '{}'
out="$(T evaluate --json)"
check "quiet: nothing triggered" "0" "$(jq '.triggered | length' <<<"$out")"
out="$(T apply)"
check "quiet: apply is a no-op" "tuning apply: nothing to change" "$out"
check "quiet: no tuning.json written" "0" "$([[ -f "$ROOT/tuning.json" ]] && echo 1 || echo 0)"

# ── defaults through get before any tuning exists ─────────────────────────────
check "get: default when no file" "2" "$(bash "$SCRIPT" get fastPathMaxTasks 2 --root "$ROOT")"
ec=0; bash "$SCRIPT" has-check suite-regression --root "$ROOT" || ec=$?
check "has-check: miss when no file" "1" "$ec"

# ── tighten triggers: gap recurrence + verify-failure class recurrence ────────
mk 0 '{"plan": 3, "spec": 2}' '{"suite-regression": 4, "live-probe": 1}'
out="$(T evaluate --json)"
check "tighten: plan gate trigger fires" "1" "$(jq '[.triggered[] | select(.id=="raise-gate-rounds-plan")] | length' <<<"$out")"
check "tighten: spec below threshold quiet" "0" "$(jq '[.triggered[] | select(.id=="raise-gate-rounds-spec")] | length' <<<"$out")"
check "tighten: verify class trigger fires" "1" "$(jq '[.triggered[] | select(.id=="verify-mandatory-check-suite-regression")] | length' <<<"$out")"
check "tighten: class below threshold quiet" "0" "$(jq '[.triggered[] | select(.id=="verify-mandatory-check-live-probe")] | length' <<<"$out")"
T apply >/dev/null
check "apply: tuning.json written" "1" "$([[ -f "$ROOT/tuning.json" ]] && echo 1 || echo 0)"
check "apply: gate rounds raised" "3" "$(bash "$SCRIPT" get planMaxCritiqueRounds 2 --root "$ROOT")"
check "apply: untouched param stays default" "2" "$(bash "$SCRIPT" get discussMaxCritiqueRounds 2 --root "$ROOT")"
ec=0; bash "$SCRIPT" has-check suite-regression --root "$ROOT" || ec=$?
check "apply: has-check hit" "0" "$ec"
ec=0; bash "$SCRIPT" has-check acceptance --root "$ROOT" || ec=$?
check "apply: has-check other class miss" "1" "$ec"
check "apply: audit trail lines" "2" "$(grep -c '"add"' "$ROOT/tuning-audit.jsonl")"

# re-apply with same metrics: idempotent
out="$(T apply)"
check "apply: idempotent on same metrics" "tuning apply: nothing to change" "$out"

# ── tightening persists even when its trigger later goes quiet ────────────────
mk 0 '{}' '{}'
out="$(T evaluate --json)"
check "tighten: not demoted when quiet" "0" "$(jq '.demote | length' <<<"$out")"
check "tighten: still applied" "3" "$(bash "$SCRIPT" get planMaxCritiqueRounds 2 --root "$ROOT")"

# ── loosen trigger: first-pass streak → fast-path widened ─────────────────────
mk 5 '{}' '{}'
T apply >/dev/null
check "loosen: fast-path tasks widened" "3" "$(bash "$SCRIPT" get fastPathMaxTasks 2 --root "$ROOT")"
check "loosen: fast-path files widened" "5" "$(bash "$SCRIPT" get fastPathMaxFiles 3 --root "$ROOT")"

# ── loosening demotes on the first contrary signal ────────────────────────────
mk 0 '{}' '{}'
out="$(T evaluate --json)"
check "demote: widen-fast-path flagged" '["widen-fast-path"]' "$(jq -c '.demote' <<<"$out")"
T apply >/dev/null
check "demote: fast-path back to default" "2" "$(bash "$SCRIPT" get fastPathMaxTasks 2 --root "$ROOT")"
check "demote: tightening survived the demotion pass" "3" "$(bash "$SCRIPT" get planMaxCritiqueRounds 2 --root "$ROOT")"
check "demote: audited" "1" "$(grep -c '"demote"' "$ROOT/tuning-audit.jsonl")"

# ── the closed-set pin: adjustments only ever come from the templates ─────────
# (mirrors retro's closed-template test: every id in tuning.json must be one of
# the fixed template ids; the model cannot author an adjustment)
mk 9 '{"plan": 9, "spec": 9, "execute": 9}' '{"marker": 9, "tamper": 9, "suite-regression": 9, "acceptance": 9, "code-review": 9, "live-probe": 9}'
T apply >/dev/null
known='^(widen-fast-path|verify-mandatory-check-(marker|tamper|suite-regression|acceptance|code-review|live-probe)|raise-gate-rounds-(spec|plan|execute))$'
bad="$(jq -r '.adjustments[].id' "$ROOT/tuning.json" | grep -Evc "$known" || true)"
check "closed set: every applied id is a template id" "0" "$bad"
check "closed set: full corpus applies all templates" "10" "$(jq '.adjustments | length' "$ROOT/tuning.json")"

# ── kill switch ───────────────────────────────────────────────────────────────
check "kill: get returns default" "2" "$(LOOP_SPEC_TUNING=0 bash "$SCRIPT" get fastPathMaxTasks 2 --root "$ROOT")"
ec=0; LOOP_SPEC_TUNING=0 bash "$SCRIPT" has-check suite-regression --root "$ROOT" || ec=$?
check "kill: has-check misses" "1" "$ec"
out="$(LOOP_SPEC_TUNING=0 T apply)"
check "kill: apply no-ops" "tuning: disabled (LOOP_SPEC_TUNING=0)" "$out"

# ── auto gating (retro-style) ─────────────────────────────────────────────────
FEAT="$WORK/feat"
mkdir -p "$FEAT"
ROOT2="$WORK/auto/.loop-spec"; mkdir -p "$ROOT2"
mk 5 '{}' '{}'

echo '{"autonomous": false}' > "$FEAT/feature.json"
out="$(bash "$SCRIPT" auto "$FEAT" --root "$ROOT2" --metrics-json "$METRICS")"
check "auto: interactive reports only" "1" "$(grep -c 'pending parameter adjustment' <<<"$out")"
check "auto: interactive did not write" "0" "$([[ -f "$ROOT2/tuning.json" ]] && echo 1 || echo 0)"

echo '{"autonomous": true}' > "$FEAT/feature.json"
bash "$SCRIPT" auto "$FEAT" --root "$ROOT2" --metrics-json "$METRICS" >/dev/null
check "auto: autonomous applies" "3" "$(bash "$SCRIPT" get fastPathMaxTasks 2 --root "$ROOT2")"

rm -rf "$ROOT2"; mkdir -p "$ROOT2"
out="$(LOOP_SPEC_TUNING_AUTO_APPLY=0 bash "$SCRIPT" auto "$FEAT" --root "$ROOT2" --metrics-json "$METRICS")"
check "auto: =0 forces report-only" "0" "$([[ -f "$ROOT2/tuning.json" ]] && echo 1 || echo 0)"
echo '{"autonomous": false}' > "$FEAT/feature.json"
LOOP_SPEC_TUNING_AUTO_APPLY=1 bash "$SCRIPT" auto "$FEAT" --root "$ROOT2" --metrics-json "$METRICS" >/dev/null
check "auto: =1 forces apply" "3" "$(bash "$SCRIPT" get fastPathMaxTasks 2 --root "$ROOT2")"

# auto never aborts
ec=0; bash "$SCRIPT" auto >/dev/null 2>&1 || ec=$?
check "auto: missing feature dir exits 0" "0" "$ec"
ec=0; bash "$SCRIPT" auto "$FEAT" --root "$ROOT2" --metrics-json "$WORK/absent.json" >/dev/null 2>&1 || ec=$?
check "auto: missing metrics exits 0" "0" "$ec"
ec=0; LOOP_SPEC_TUNING=0 bash "$SCRIPT" auto "$FEAT" --root "$ROOT2" --metrics-json "$METRICS" >/dev/null 2>&1 || ec=$?
check "auto: kill switch exits 0" "0" "$ec"

# ── bad invocations ───────────────────────────────────────────────────────────
ec=0; bash "$SCRIPT" bogus >/dev/null 2>&1 || ec=$?
check "unknown subcommand exits 2" "2" "$ec"
ec=0; bash "$SCRIPT" get onlyparam >/dev/null 2>&1 || ec=$?
check "get without default exits 2" "2" "$ec"
ec=0; bash "$SCRIPT" evaluate --metrics-json "$WORK/absent.json" --root "$ROOT" >/dev/null 2>&1 || ec=$?
check "evaluate missing metrics exits 2" "2" "$ec"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
