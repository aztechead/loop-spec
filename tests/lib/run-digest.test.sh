#!/usr/bin/env bash
# Tests for lib/run-digest.sh (committed per-run telemetry digest)
set -uo pipefail

LIB="$(cd "$(dirname "$0")/../.." && pwd)/lib/run-digest.sh"
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

WORK="${TMPDIR:-/tmp}/loop-spec-run-digest.$$"
trap 'rm -rf "$WORK"' EXIT

# Project layout: <project>/.loop-spec/features/<slug>
PROJ="$WORK/proj"
FDIR="$PROJ/.loop-spec/features/my-feat"
mkdir -p "$FDIR"

cat > "$FDIR/feature.json" << 'EOF'
{"schemaVersion":7,"slug":"my-feat","updatedAt":"2026-07-08T11:59:00Z","iterate":{"used":3,"maxIterations":10},"warnings":["w1","w2"]}
EOF
cat > "$FDIR/result.json" << 'EOF'
{"schema":1,"slug":"my-feat","status":"completed","converged":false,
 "iterations":{"used":3,"max":10},"finishedAt":"2026-07-08T12:00:00Z"}
EOF
cat > "$FDIR/events.jsonl" << 'EOF'
{"ts":"t","slug":"my-feat","event":"iterate_verdict","phase":"iterate","data":{"verdict":"not-converged","iteration":1,"gap":"plan"}}
{"ts":"t","slug":"my-feat","event":"iterate_verdict","phase":"iterate","data":{"verdict":"not-converged","iteration":2,"gap":"plan"}}
{"ts":"t","slug":"my-feat","event":"iterate_verdict","phase":"iterate","data":{"verdict":"converged","iteration":3,"gap":"none"}}
{"ts":"t","slug":"my-feat","event":"gate_round","phase":"discuss","data":{"gate":"spec-critique","round":2}}
{"ts":"t","slug":"my-feat","event":"gate_round","phase":"plan","data":{"gate":"plan-critique","round":1}}
{"ts":"t","slug":"my-feat","event":"verify_failure","phase":"verify","data":{"class":"suite-regression"}}
{"ts":"t","slug":"my-feat","event":"verify_failure","phase":"verify","data":{"class":"suite-regression"}}
{"ts":"t","slug":"my-feat","event":"verify_failure","phase":"verify","data":{"class":"acceptance"}}
EOF

# ── Case 1: default out-dir resolution + digest content ───────────────────────
ec=0
out="$(bash "$LIB" append "$FDIR" 2>&1)" || ec=$?
check "1: exit 0" "0" "$ec"
DIGEST="$PROJ/docs/loop-spec/telemetry/runs/my-feat.json"
check "1: digest at project docs path" "1" "$([[ -f "$DIGEST" ]] && echo 1 || echo 0)"
check "1: schema 2" "2" "$(jq -r '.schema' "$DIGEST")"
check "1: converged false preserved (not null)" "false" "$(jq -r '.converged' "$DIGEST")"
check "1: gaps unique, none excluded" '["plan"]' "$(jq -c '.gaps' "$DIGEST")"
check "1: gateCaps only round>=2" '["spec-critique"]' "$(jq -c '.gateCaps' "$DIGEST")"
check "1: iterateRounds counts verdicts" "3" "$(jq -r '.iterateRounds' "$DIGEST")"
check "1: gateRoundsByGate max per gate" '{"plan-critique":1,"spec-critique":2}' "$(jq -cS '.gateRoundsByGate' "$DIGEST")"
check "1: verifyFailureClasses unique" '["acceptance","suite-regression"]' "$(jq -c '.verifyFailureClasses' "$DIGEST")"
check "1: iterations used" "3" "$(jq -r '.iterations.used' "$DIGEST")"
check "1: warnings count" "2" "$(jq -r '.warnings' "$DIGEST")"
check "1: finishedAt carried" "2026-07-08T12:00:00Z" "$(jq -r '.finishedAt' "$DIGEST")"

# ── Case 2: idempotent overwrite (latest run wins, single file per slug) ──────
printf '%s\n' "$(jq '.iterate.used = 5' "$FDIR/feature.json")" > "$FDIR/feature.json"
bash "$LIB" append "$FDIR" >/dev/null 2>&1
check "2: single file per slug" "1" "$(ls "$PROJ/docs/loop-spec/telemetry/runs" | wc -l | tr -d ' ')"

# ── Case 3: explicit --out-dir ────────────────────────────────────────────────
bash "$LIB" append "$FDIR" --out-dir "$WORK/alt" >/dev/null 2>&1
check "3: explicit out-dir honored" "1" "$([[ -f "$WORK/alt/my-feat.json" ]] && echo 1 || echo 0)"

# ── Case 4: observability contract — never fails the caller ──────────────────
ec=0; bash "$LIB" append "$WORK/nonexistent" >/dev/null 2>&1 || ec=$?
check "4: missing feature dir exit 0" "0" "$ec"
ec=0; bash "$LIB" bogus >/dev/null 2>&1 || ec=$?
check "4: unknown subcommand exit 0" "0" "$ec"

# ── Case 5: corrupt inputs tolerated (slug falls back to dirname) ─────────────
CDIR="$PROJ/.loop-spec/features/corrupt-feat"
mkdir -p "$CDIR"
echo 'not json' > "$CDIR/feature.json"
echo 'not json' > "$CDIR/events.jsonl"
ec=0; bash "$LIB" append "$CDIR" >/dev/null 2>&1 || ec=$?
check "5: corrupt inputs exit 0" "0" "$ec"
check "5: digest written with dirname slug" "corrupt-feat" \
  "$(jq -r '.slug' "$PROJ/docs/loop-spec/telemetry/runs/corrupt-feat.json" 2>/dev/null)"

# ── Case 6: pre-delivery candidate can be committed before exact-SHA delivery ─
printf '%s\n' "$(jq '.currentPhase="deliver" | .warnings=[]' "$FDIR/feature.json")" > "$FDIR/feature.json"
bash "$LIB" append "$FDIR" --candidate >/dev/null 2>&1
check "6: candidate status is completed" "completed" "$(jq -r '.status' "$DIGEST")"
check "6: candidate convergence derived" "true" "$(jq -r '.converged' "$DIGEST")"
check "6: candidate ignores stale result iterations" "5" "$(jq -r '.iterations.used' "$DIGEST")"
check "6: candidate timestamp comes from durable state" "2026-07-08T11:59:00Z" "$(jq -r '.finishedAt' "$DIGEST")"
candidate_first="$(<"$DIGEST")"
sleep 1
bash "$LIB" append "$FDIR" --candidate >/dev/null 2>&1
check "6: candidate retry is byte-stable" "$candidate_first" "$(<"$DIGEST")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
