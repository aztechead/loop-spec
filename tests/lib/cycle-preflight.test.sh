#!/usr/bin/env bash
# Tests for lib/cycle-preflight.sh (the batched silent startup).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/lib/cycle-preflight.sh"
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

WORK="${TMPDIR:-/tmp}"; WORK="${WORK%/}/cycle-preflight-test.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/repo"
REPO="$WORK/repo"
git -C "$REPO" init -q -b main
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

# Pin every probe so the test is hermetic (no `claude`, no graphify binary needed).
run_preflight() {
  LOOP_SPEC_TEAMS_MODE=none \
  LOOP_SPEC_WORKFLOWS_AVAILABLE=0 \
  LOOP_SPEC_REQUIRE_GRAPHIFY="${REQUIRE_GRAPHIFY:-1}" \
  GRAPHIFY_BIN="${GRAPHIFY_BIN:-definitely-not-a-real-binary}" \
  bash "$SCRIPT" run "$REPO"
}

# bad invocation
ec=0; bash "$SCRIPT" >/dev/null 2>&1 || ec=$?
check "no subcommand exits 1" "1" "$ec"
ec=0; bash "$SCRIPT" run "$WORK/nope" >/dev/null 2>&1 || ec=$?
check "missing dir exits 1" "1" "$ec"

# clean repo: single mode, empty resume, zero backlog
out="$(run_preflight)"
check "workspace mode single" "single" "$(jq -r '.workspace.mode' <<<"$out")"
check "teams mode pinned" "none" "$(jq -r '.teams.mode' <<<"$out")"
check "teams available false" "false" "$(jq -r '.teams.available' <<<"$out")"
check "workflows pinned off" "false" "$(jq -r '.workflows.available' <<<"$out")"
check "graphify missing reported" "false" "$(jq -r '.graphify.ok' <<<"$out")"
check "graphify required by default" "true" "$(jq -r '.graphify.required' <<<"$out")"
check "graph status missing" "missing" "$(jq -r '.graphify.graph' <<<"$out")"
check "backlog zero" "0" "$(jq -r '.backlog.count' <<<"$out")"
check "no resume candidates" "0" "$(jq -r '.resume.candidates | length' <<<"$out")"
check "no warnings" "0" "$(jq -r '.warnings | length' <<<"$out")"

# graphify bypass reported (never exits non-zero either way)
out="$(REQUIRE_GRAPHIFY=0 run_preflight)"
check "graphify bypass reported" "false" "$(jq -r '.graphify.required' <<<"$out")"

# backlog count flows through
LOOP_SPEC_BACKLOG_FILE="$REPO/.loop-spec/BACKLOG.md" bash "$REPO_ROOT/lib/backlog.sh" add s manual "one thing" >/dev/null
out="$(run_preflight)"
check "backlog counted" "1" "$(jq -r '.backlog.count' <<<"$out")"

# resume scan
FEATS="$REPO/.loop-spec/features"
now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

mk_feature() { # slug phase schema team updatedAt
  mkdir -p "$FEATS/$1"
  jq -n --arg p "$2" --argjson s "$3" --argjson t "$4" --arg u "$5" \
    '{schemaVersion: $s, currentPhase: $p, currentTeamName: $t, updatedAt: $u, stalenessHours: 48}' \
    > "$FEATS/$1/feature.json"
}

mk_feature fresh-one execute 7 null "$now_iso"
mk_feature done-one completed 7 null "$now_iso"
mk_feature old-schema plan 5 null "$now_iso"
mk_feature stale-one verify 7 null "2020-01-01T00:00:00Z"
mk_feature orphan-one plan 7 '"team-x"' "$now_iso"
mkdir -p "$FEATS/broken-one"
echo "{ nope" > "$FEATS/broken-one/feature.json"

out="$(run_preflight)"
check "two candidates" "2" "$(jq -r '.resume.candidates | length' <<<"$out")"
check "fresh feature is a candidate" "1" "$(jq -r '[.resume.candidates[] | select(.slug == "fresh-one")] | length' <<<"$out")"
check "orphan needs probe" "true" "$(jq -r '.resume.candidates[] | select(.slug == "orphan-one") | .needs_probe' <<<"$out")"
check "fresh does not need probe" "false" "$(jq -r '.resume.candidates[] | select(.slug == "fresh-one") | .needs_probe' <<<"$out")"
check "completed silently dropped" "0" "$(jq -r '[.resume.candidates[], .resume.skipped[] | select(.slug == "done-one")] | length' <<<"$out")"
check "old schema skipped" "schema-version" "$(jq -r '.resume.skipped[] | select(.slug == "old-schema") | .why' <<<"$out")"
check "old schema warned" "1" "$(jq -r '[.warnings[] | select(test("old-schema.*schemaVersion 5"))] | length' <<<"$out")"
check "stale skipped" "stale" "$(jq -r '.resume.skipped[] | select(.slug == "stale-one") | .why' <<<"$out")"
check "broken skipped" "unparseable" "$(jq -r '.resume.skipped[] | select(.slug == "broken-one") | .why' <<<"$out")"
check "broken warned" "1" "$(jq -r '[.warnings[] | select(test("broken-one"))] | length' <<<"$out")"

# .bak recovery
cp "$FEATS/fresh-one/feature.json" "$FEATS/broken-one/feature.json.bak"
out="$(run_preflight)"
check "bak recovery makes candidate" "1" "$(jq -r '[.resume.candidates[] | select(.slug == "broken-one")] | length' <<<"$out")"
check "bak recovery recorded" "feature.json.bak" "$(jq -r '.resume.candidates[] | select(.slug == "broken-one") | .parse_source' <<<"$out")"

# ordering: most recently updated first
mk_feature fresher-one spec 7 null "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
sleep 1
mk_feature freshest-one discuss 7 null "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
out="$(run_preflight)"
first="$(jq -r '.resume.candidates[0].slug' <<<"$out")"
check "most recent first" "freshest-one" "$first"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
