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
mkdir -p "$REPO/.loop-spec"
printf '{}\n' > "$REPO/.loop-spec/last-result.json"

# Pin every probe so the test is hermetic (no `claude` binary needed).
run_preflight() {
  # The execution-profile probe reads the ambient CLAUDE_CODE_ENTRYPOINT stamp,
  # so clear it (and the mode flags) and let each case opt in explicitly.
  env -u CLAUDE_CODE_ENTRYPOINT -u LOOP_SPEC_AUTONOMOUS -u LOOP_SPEC_NON_INTERACTIVE \
    ${ENTRYPOINT:+CLAUDE_CODE_ENTRYPOINT="$ENTRYPOINT"} \
    ${AUTONOMOUS:+LOOP_SPEC_AUTONOMOUS="$AUTONOMOUS"} \
    LOOP_SPEC_HARNESS="${HARNESS:-claude}" \
    LOOP_SPEC_TEAMS_MODE=none \
    LOOP_SPEC_WORKFLOWS_AVAILABLE=0 \
    bash "$SCRIPT" run "$REPO"
}

headless_warnings() {
  jq -r '[.warnings[] | select(startswith("headless invocation"))] | length' <<<"$1"
}

# bad invocation
ec=0; bash "$SCRIPT" >/dev/null 2>&1 || ec=$?
check "no subcommand exits 1" "1" "$ec"
ec=0; bash "$SCRIPT" run "$WORK/nope" >/dev/null 2>&1 || ec=$?
check "missing dir exits 1" "1" "$ec"

# clean repo: single mode, empty resume, zero backlog
out="$(run_preflight)"
check "entry clears stale terminal result" "0" "$([[ -f "$REPO/.loop-spec/last-result.json" ]] && echo 1 || echo 0)"
check "workspace mode single" "single" "$(jq -r '.workspace.mode' <<<"$out")"
check "harness reported" "claude" "$(jq -r '.harness.name' <<<"$out")"
check "teams mode pinned" "none" "$(jq -r '.teams.mode' <<<"$out")"
check "teams available false" "false" "$(jq -r '.teams.available' <<<"$out")"
check "workflows pinned off" "false" "$(jq -r '.workflows.available' <<<"$out")"
check "backlog zero" "0" "$(jq -r '.backlog.count' <<<"$out")"
check "no resume candidates" "0" "$(jq -r '.resume.candidates | length' <<<"$out")"
check "no warnings" "0" "$(jq -r '.warnings | length' <<<"$out")"


# adk harness flows through the blob
out="$(HARNESS=adk run_preflight)"
check "adk harness reported" "adk" "$(jq -r '.harness.name' <<<"$out")"

# --- execution profile ---------------------------------------------------------
out="$(run_preflight)"
check "unstamped entrypoint reported" "unknown" "$(jq -r '.execution.entrypoint' <<<"$out")"
check "unstamped run is not headless" "false" "$(jq -r '.execution.headless' <<<"$out")"
check "no headless warning when interactive" "0" "$(headless_warnings "$out")"

out="$(ENTRYPOINT=cli run_preflight)"
check "interactive entrypoint reported" "cli" "$(jq -r '.execution.entrypoint' <<<"$out")"
check "interactive TUI is not headless" "false" "$(jq -r '.execution.headless' <<<"$out")"

out="$(ENTRYPOINT=sdk-cli run_preflight)"
check "claude -p entrypoint reported" "sdk-cli" "$(jq -r '.execution.entrypoint' <<<"$out")"
check "claude -p is headless" "true" "$(jq -r '.execution.headless' <<<"$out")"
check "unattended run without a mode warns" "1" "$(headless_warnings "$out")"

out="$(ENTRYPOINT=sdk-py run_preflight)"
check "python SDK is headless" "true" "$(jq -r '.execution.headless' <<<"$out")"

# Autonomous mode self-answers every question, so a headless run is expected there.
out="$(ENTRYPOINT=sdk-py AUTONOMOUS=1 run_preflight)"
check "autonomous headless run does not warn" "0" "$(headless_warnings "$out")"

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

# ordering: most recently updated first (distinct fixed timestamps; the sort
# key is the updatedAt field, so no wall-clock separation is needed)
mk_feature fresher-one spec 7 null "2026-01-01T00:00:00Z"
mk_feature freshest-one discuss 7 null "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
out="$(run_preflight)"
first="$(jq -r '.resume.candidates[0].slug' <<<"$out")"
check "most recent first" "freshest-one" "$first"

# State created only inside a registered feature worktree is discoverable from main.
WT="$REPO/.claude/worktrees/wt-only"
git -C "$REPO" worktree add -q -b feat/wt-only "$WT" main
WT="$(cd "$WT" && pwd -P)"
mkdir -p "$WT/.loop-spec/features/wt-only"
jq -n --arg u "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{schemaVersion:7,currentPhase:"deliver",currentTeamName:null,updatedAt:$u,
    stalenessHours:48,worktreePath:".claude/worktrees/wt-only",workspace:null}' \
  > "$WT/.loop-spec/features/wt-only/feature.json"
out="$(run_preflight)"
check "worktree-only feature discovered" "1" "$(jq -r '[.resume.candidates[] | select(.slug == "wt-only")] | length' <<<"$out")"
check "worktree-only source recorded" "worktree" "$(jq -r '.resume.candidates[] | select(.slug == "wt-only") | .source' <<<"$out")"
check "worktree-only absolute root recorded" "$WT" "$(jq -r '.resume.candidates[] | select(.slug == "wt-only") | .featureRoot' <<<"$out")"
check "deliver phase is resumable" "deliver" "$(jq -r '.resume.candidates[] | select(.slug == "wt-only") | .currentPhase' <<<"$out")"

# A ready sidecar still resumes DELIVER so cycle completion finalization (result,
# summary, autonomous chaining, worktree exit) can recover after a crash.
jq -n '{schema:1,status:"ready-for-review",nextPhase:"completed",targets:[]}' \
  > "$WT/.loop-spec/features/wt-only/delivery.json"
out="$(run_preflight)"
check "delivered sidecar remains resumable" "1" \
  "$(jq -r '[.resume.candidates[] | select(.slug == "wt-only")] | length' <<<"$out")"

# Once a matching no-change result has been emitted, the otherwise resumable
# deliver state is terminal and must not be offered again.
jq -n '{schema:1,status:"no-changes",nextPhase:"deliver",
  attemptedAt:"2026-07-30T10:00:00Z",targets:[{errorCode:"no_commits"}]}' \
  > "$WT/.loop-spec/features/wt-only/delivery.json"
jq -n '{schema:1,cycleType:"full",slug:"wt-only",status:"completed",outcome:"no-change-needed",
  summary:"The requested state was already present.",noChangeReason:"already-satisfied",
  converged:true,prUrl:null,checkpointPrUrl:null,
  verification:{status:"passed",command:"bash tests/run-all.sh"},
  finishedAt:"2026-07-30T10:01:00Z",
  delivery:{status:"no-changes",nextPhase:"deliver",attemptedAt:"2026-07-30T10:00:00Z",
    targets:[{errorCode:"no_commits"}]}}' \
  > "$WT/.loop-spec/features/wt-only/result.json"
out="$(run_preflight)"
check "terminal no-change sidecar is not resumable" "0" \
  "$(jq -r '[.resume.candidates[] | select(.slug == "wt-only")] | length' <<<"$out")"

jq '.slug = "copied-from-another-feature"' "$WT/.loop-spec/features/wt-only/result.json" \
  > "$WT/.loop-spec/features/wt-only/result.json.tmp"
mv "$WT/.loop-spec/features/wt-only/result.json.tmp" "$WT/.loop-spec/features/wt-only/result.json"
out="$(run_preflight)"
check "mismatched no-change result cannot hide feature" "1" \
  "$(jq -r '[.resume.candidates[] | select(.slug == "wt-only")] | length' <<<"$out")"

# --- Recovery breadcrumb is placed BEFORE the stale pointer is cleared -----------
# Preflight clears the previous run's terminal pointer, then can still abort (the
# a preflight abort). Without a breadcrumb first, that abort left NEITHER a
# terminal result NOR a recovery record, and cycle-reconcile.sh had nothing to
# reconcile -- the exact "process exits, no state" hole this file exists to close.
BC="$WORK/breadcrumb"
mkdir -p "$BC/.loop-spec"
git -C "$BC" init -q 2>/dev/null
printf '{"status":"completed","stale":true}' > "$BC/.loop-spec/last-result.json"
REPO="$BC" run_preflight >/dev/null 2>&1 || true
check "stale terminal pointer is still cleared" "0" \
  "$([[ -f "$BC/.loop-spec/last-result.json" ]] && echo 1 || echo 0)"
check "a recovery breadcrumb exists after preflight" "1" \
  "$([[ -f "$BC/.loop-spec/active-run.json" ]] && echo 1 || echo 0)"
check "breadcrumb names the preflight phase" "preflight" \
  "$(jq -r '.phase' "$BC/.loop-spec/active-run.json" 2>/dev/null)"

# The real `begin` must supersede the placeholder while preserving startedAt, so
# elapsed time still measures the whole run.
bc_started="$(jq -r '.startedAt' "$BC/.loop-spec/active-run.json")"
bash "$REPO_ROOT/lib/cycle-result.sh" begin --result-root "$BC" --cycle-type full \
  --title "Real feature" --slug real --phase spec >/dev/null 2>&1
check "real begin supersedes the placeholder title" "Real feature" \
  "$(jq -r '.title' "$BC/.loop-spec/active-run.json")"
check "real begin preserves startedAt" "$bc_started" \
  "$(jq -r '.startedAt' "$BC/.loop-spec/active-run.json")"

# End to end: an abort right after preflight is now recoverable.
recon="$(bash "$REPO_ROOT/lib/cycle-reconcile.sh" --result-root "$BC" \
  --reason "preflight abort" 2>/dev/null | head -1)"
check "reconcile turns a preflight abort into a failed terminal result" "failed" \
  "$(jq -r '.status' <<<"${recon#LOOP_SPEC_RESULT }" 2>/dev/null)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
