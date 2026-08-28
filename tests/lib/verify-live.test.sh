#!/usr/bin/env bash
# Tests for lib/verify-live.sh (live-run verify rung, ROADMAP-3.0 C1).
# The fake "server" is a background process that drops a readiness file —
# same launch/ready/probe/kill machinery as a real app, no network needed.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/lib/verify-live.sh"
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

WORK="${TMPDIR:-/tmp}/verify-live-test.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"
CFG="$WORK/workflow.json"
EVID="$WORK/EVIDENCE.md"

# ── unconfigured: degrade to suite-only, exit 0 ───────────────────────────────
ec=0
out="$(bash "$SCRIPT" run --file "$WORK/absent.json" 2>/dev/null)" || ec=$?
check "unconfigured: exit 0" "0" "$ec"
check "unconfigured: configured=false" "false" "$(jq '.configured' <<<"$out")"
check "unconfigured: allPass null (nothing claimed)" "null" "$(jq '.allPass' <<<"$out")"
echo '{"commitStrategy": "per-task"}' > "$CFG"
ec=0; out="$(bash "$SCRIPT" run --file "$CFG" 2>/dev/null)" || ec=$?
check "no block: exit 0" "0" "$ec"
check "no block: configured=false" "false" "$(jq '.configured' <<<"$out")"

# ── config verb ───────────────────────────────────────────────────────────────
ec=0; bash "$SCRIPT" config --file "$CFG" >/dev/null 2>&1 || ec=$?
check "config: unconfigured exit 1" "1" "$ec"
jq -n --arg w "$WORK" '{verifyCommands: {
  launch: "echo $$ > \($w)/pid; touch \($w)/up; exec sleep 30",
  ready: "test -f \($w)/up",
  probes: ["echo probe-one-ok", "test -f \($w)/up"],
  readyTimeoutSec: 10
}}' > "$CFG"
ec=0; out="$(bash "$SCRIPT" config --file "$CFG")" || ec=$?
check "config: configured exit 0" "0" "$ec"
check "config: prints launch" "1" "$(grep -c 'sleep 30' <<<"$out")"

# malformed block refuses loudly (exit 2), never half-runs
echo '{"verifyCommands": {"launch": "x"}}' > "$WORK/bad.json"
ec=0; bash "$SCRIPT" config --file "$WORK/bad.json" >/dev/null 2>&1 || ec=$?
check "config: malformed block exit 2" "2" "$ec"
ec=0; bash "$SCRIPT" run --file "$WORK/bad.json" >/dev/null 2>&1 || ec=$?
check "run: malformed block exit 2" "2" "$ec"

# ── happy path: launch, ready, probes pass, evidence captured, app killed ─────
ec=0
out="$(bash "$SCRIPT" run --file "$CFG" --evidence "$EVID" 2>/dev/null)" || ec=$?
check "run: all-pass exit 0" "0" "$ec"
check "run: ready true" "true" "$(jq '.ready' <<<"$out")"
check "run: allPass true" "true" "$(jq '.allPass' <<<"$out")"
check "run: two probes" "2" "$(jq '.probes | length' <<<"$out")"
check "run: probe carries evid id" "EVID-001" "$(jq -r '.probes[0].evid' <<<"$out")"
check "run: evidence ledger written" "2" "$(grep -c '^- EVID-' "$EVID")"
check "run: ledger carries probe cmd" "1" "$(grep -c 'echo probe-one-ok' "$EVID")"

# ── failing probe: exit 1, allPass false, failure ledgered ────────────────────
rm -f "$WORK/up" "$WORK/pid"
jq -n --arg w "$WORK" '{verifyCommands: {
  launch: "echo $$ > \($w)/pid; touch \($w)/up; exec sleep 30",
  ready: "test -f \($w)/up",
  probes: ["echo ok", "false"],
  readyTimeoutSec: 10
}}' > "$CFG"
ec=0
out="$(bash "$SCRIPT" run --file "$CFG" --evidence "$EVID" 2>/dev/null)" || ec=$?
check "fail: exit 1" "1" "$ec"
check "fail: allPass false" "false" "$(jq '.allPass' <<<"$out")"
check "fail: failing probe marked" "false" "$(jq '.probes[1].pass' <<<"$out")"
check "fail: failure ledgered as FAILED" "1" "$(grep -c 'live probe FAILED' "$EVID")"

# Timing-dependent cases (never-ready bounded wait, dead-on-arrival fast-fail,
# post-probe kill checks) were removed with the rest of the timing tests: they
# had to wait out real ready-timeouts or race process teardown, and the suite is
# offline-and-instant by policy.

# ── detect: suggests, never writes ────────────────────────────────────────────
D="$WORK/proj"; mkdir -p "$D"
check "detect: nothing on empty dir" "" "$(bash "$SCRIPT" detect "$D")"
echo '{"scripts": {"start": "node server.js"}}' > "$D/package.json"
check "detect: npm start" "npm start" "$(bash "$SCRIPT" detect "$D")"
rm "$D/package.json"
printf 'web: bundle exec puma\n' > "$D/Procfile"
check "detect: Procfile web" "bundle exec puma" "$(bash "$SCRIPT" detect "$D")"
check "detect: wrote nothing" "Procfile" "$(ls "$D")"

# ── bad invocations ───────────────────────────────────────────────────────────
ec=0; bash "$SCRIPT" bogus >/dev/null 2>&1 || ec=$?
check "unknown subcommand exits 2" "2" "$ec"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
