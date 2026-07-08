#!/usr/bin/env bash
# Tests for lib/status.sh (telemetry reader behind /loop-spec:status)
set -uo pipefail

LIB="$(cd "$(dirname "$0")/../.." && pwd)/lib/status.sh"
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

WORK="${TMPDIR:-/tmp}/loop-spec-status.$$"
trap 'rm -rf "$WORK"' EXIT
ROOT="$WORK/.loop-spec"
mkdir -p "$ROOT/features/feat-a" "$ROOT/features/feat-b"

# ── Fixture: feat-a (finished, converged, rich events) ────────────────────────
cat > "$ROOT/features/feat-a/feature.json" << 'EOF'
{"schemaVersion":7,"slug":"feat-a","feature_title":"Feature A","currentPhase":"completed",
 "iterate":{"used":2,"maxIterations":10},"warnings":["w1"],"prUrl":null,
 "checkpointPrUrl":null,"autonomous":true}
EOF
cat > "$ROOT/features/feat-a/result.json" << 'EOF'
{"schema":1,"slug":"feat-a","status":"completed","converged":true,
 "prUrl":"https://github.com/t/r/pull/7","iterations":{"used":2,"max":10},"warnings":["w1"]}
EOF
cat > "$ROOT/features/feat-a/events.jsonl" << 'EOF'
{"ts":"2026-07-08T10:00:00Z","slug":"feat-a","event":"phase_start","phase":"spec","data":{}}
{"ts":"2026-07-08T10:05:00Z","slug":"feat-a","event":"dispatch","phase":"discuss","data":{"role":"advocate","model":"sonnet","rung":"team"}}
{"ts":"2026-07-08T10:05:01Z","slug":"feat-a","event":"dispatch","phase":"discuss","data":{"role":"challenger","model":"opus","rung":"team"}}
{"ts":"2026-07-08T10:06:00Z","slug":"feat-a","event":"gate_round","phase":"discuss","data":{"gate":"spec-critique","round":1}}
{"ts":"2026-07-08T10:07:00Z","slug":"feat-a","event":"gate_round","phase":"discuss","data":{"gate":"spec-critique","round":2}}
{"ts":"2026-07-08T10:20:00Z","slug":"feat-a","event":"dispatch","phase":"execute","data":{"role":"implementer","model":"sonnet","rung":"subagent"}}
{"ts":"2026-07-08T10:40:00Z","slug":"feat-a","event":"iterate_verdict","phase":"iterate","data":{"verdict":"not-converged","iteration":1,"gap":"execute"}}
{"ts":"2026-07-08T10:55:00Z","slug":"feat-a","event":"iterate_verdict","phase":"iterate","data":{"verdict":"converged","iteration":2,"gap":"none"}}
{"ts":"2026-07-08T11:00:00Z","slug":"feat-a","event":"completed","phase":null,"data":{}}
EOF

# ── Fixture: feat-b (in-flight, minimal) ──────────────────────────────────────
cat > "$ROOT/features/feat-b/feature.json" << 'EOF'
{"schemaVersion":7,"slug":"feat-b","currentPhase":"plan","iterate":{"used":0,"maxIterations":10},"warnings":[]}
EOF

# ── Fixture: fleet result with cost (lives next to .loop-spec) ───────────────
mkdir -p "$WORK/.loop"
echo '{"completed":["t1"],"failed":[],"total_cost_usd":1.25,"tasks":{}}' > "$WORK/.loop/fleet-result.json"

# ── Case 1: human status table ────────────────────────────────────────────────
out="$(bash "$LIB" --root "$ROOT" status)"
check "1: table lists feat-a" "1" "$(grep -c '^feat-a' <<<"$out")"
check "1: table lists feat-b" "1" "$(grep -c '^feat-b' <<<"$out")"
check "1: feat-a shows completed result" "1" "$(grep '^feat-a' <<<"$out" | grep -c 'completed')"
check "1: feat-a shows PR url" "1" "$(grep '^feat-a' <<<"$out" | grep -c 'pull/7')"
check "1: feat-b shows plan phase" "1" "$(grep '^feat-b' <<<"$out" | grep -c 'plan')"

# ── Case 2: --json status is machine-readable ─────────────────────────────────
out="$(bash "$LIB" --root "$ROOT" --json status)"
check "2: json parses" "1" "$(jq -e 'type == "array"' >/dev/null 2>&1 <<<"$out" && echo 1 || echo 0)"
check "2: two features" "2" "$(jq 'length' <<<"$out")"
check "2: feat-a iterations 2/10" "2" "$(jq -r '.[] | select(.slug=="feat-a") | .iterations.used' <<<"$out")"
check "2: raw events stripped from status" "0" "$(jq '[.[] | has("events")] | map(select(.)) | length' <<<"$out")"

# ── Case 3: slug filter ───────────────────────────────────────────────────────
out="$(bash "$LIB" --root "$ROOT" --json status feat-a)"
check "3: filtered to one" "1" "$(jq 'length' <<<"$out")"
check "3: right slug" "feat-a" "$(jq -r '.[0].slug' <<<"$out")"

# ── Case 4: stats aggregates ──────────────────────────────────────────────────
out="$(bash "$LIB" --root "$ROOT" --json stats)"
check "4: total features" "2" "$(jq '.features.total' <<<"$out")"
check "4: byResultStatus completed" "1" "$(jq '.features.byResultStatus.completed' <<<"$out")"
check "4: byResultStatus in-flight" "1" "$(jq '.features.byResultStatus["in-flight"]' <<<"$out")"
check "4: convergence 1/1" "1" "$(jq '.convergence.converged' <<<"$out")"
check "4: gate rounds spec-critique=2" "2" "$(jq '.gateRounds["spec-critique"]' <<<"$out")"
check "4: iterate gap execute=1" "1" "$(jq '.iterateGaps.execute' <<<"$out")"
check "4: dispatches total=3" "3" "$(jq '.dispatches.total' <<<"$out")"
check "4: dispatches sonnet=2" "2" "$(jq '.dispatches.byModel.sonnet' <<<"$out")"
check "4: dispatches opus=1" "1" "$(jq '.dispatches.byModel.opus' <<<"$out")"
check "4: dispatches byRung team=2" "2" "$(jq '.dispatches.byRung.team' <<<"$out")"
check "4: fleet cost surfaced" "1.25" "$(jq '.loopFleetCostUsd' <<<"$out")"

# ── Case 5: human stats renders ───────────────────────────────────────────────
out="$(bash "$LIB" --root "$ROOT" stats)"
check "5: mentions dispatches" "1" "$(grep -c 'dispatches: 3 total' <<<"$out")"
check "5: mentions fleet cost" "1" "$(grep -c '\$1.25' <<<"$out")"

# ── Case 6: empty root is not an error ────────────────────────────────────────
ec=0
out="$(bash "$LIB" --root "$WORK/nonexistent" status)" || ec=$?
check "6: empty root exit 0" "0" "$ec"
check "6: says no features" "1" "$(grep -c 'no loop-spec features' <<<"$out")"

# ── Case 7: corrupt feature.json tolerated ────────────────────────────────────
mkdir -p "$ROOT/features/feat-corrupt"
echo 'not json' > "$ROOT/features/feat-corrupt/feature.json"
ec=0
out="$(bash "$LIB" --root "$ROOT" --json status)" || ec=$?
check "7: corrupt tolerated exit 0" "0" "$ec"
check "7: corrupt feature still listed" "1" "$(jq '[.[] | select(.slug=="feat-corrupt")] | length' <<<"$out")"
rm -rf "$ROOT/features/feat-corrupt"

# ── Case 8: bad flag → exit 2 ─────────────────────────────────────────────────
ec=0
bash "$LIB" --bogus >/dev/null 2>&1 || ec=$?
check "8: bad flag exit 2" "2" "$ec"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
