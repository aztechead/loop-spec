#!/usr/bin/env bash
# Tests for lib/cycle-result.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/lib/cycle-result.sh"
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

WORK="${TMPDIR:-/tmp}/loop-spec-cycle-result.$$"
trap 'rm -rf "$WORK"' EXIT

# Build a minimal feature.json fixture shaped like .loop-spec/features/<slug>/
# (two levels deep so ../../ resolves to $WORK/.loop-spec)
LOOP_DIR="$WORK/.loop-spec"
FEAT_DIR="$LOOP_DIR/features/my-feature"
mkdir -p "$FEAT_DIR"

FIXTURE_FJ="$(jq -n '{
  schemaVersion: 7,
  slug: "my-feature",
  feature_title: "Add rate limiting",
  currentPhase: "completed",
  branch: "feat/my-feature",
  baseBranch: "main",
  prUrl: "https://github.com/test/repo/pull/1",
  checkpointPrUrl: null,
  delivery: {status:"ready-for-review",attemptedAt:"2026-01-01T01:00:00Z",
    finishedAt:"2026-01-01T01:05:00Z",targets:[{name:"my-feature",ok:true,
      outcome:"delivered",targetSha:"abc",remoteSha:"abc",headSha:"abc",
      prUrl:"https://github.com/test/repo/pull/1",checks:{status:"passed"}}]},
  autonomous: false,
  createdAt: "2026-01-01T00:00:00Z",
  updatedAt: "2026-01-01T01:00:00Z",
  warnings: [],
  iterate: {used: 2, maxIterations: 10}
}')"
printf '%s\n' "$FIXTURE_FJ" > "$FEAT_DIR/feature.json"

# Case A: write --status completed produces valid result.json
bash "$LIB" write "$FEAT_DIR" --status completed --summary "Rate limiting was implemented and verified." >/dev/null 2>&1
check "A: result.json created" "1" "$([[ -f "$FEAT_DIR/result.json" ]] && echo 1 || echo 0)"
check "A: valid JSON" "0" "$(jq . "$FEAT_DIR/result.json" >/dev/null 2>&1; echo $?)"
check "A: schema=1" "1" "$(jq '.schema' "$FEAT_DIR/result.json")"
# Every terminal result dates itself, so a report from an unattended harness can
# be checked against the version that fixed what it describes.
check "A: loopSpecVersion matches manifest" \
  "$(jq -r '.version' "$REPO_ROOT/.claude-plugin/plugin.json")" \
  "$(jq -r '.loopSpecVersion' "$FEAT_DIR/result.json")"
check "A: status=completed" "completed" "$(jq -r '.status' "$FEAT_DIR/result.json")"
check "A: slug" "my-feature" "$(jq -r '.slug' "$FEAT_DIR/result.json")"
check "A: feature_title" "Add rate limiting" "$(jq -r '.feature_title' "$FEAT_DIR/result.json")"
check "A: iterations.used=2" "2" "$(jq '.iterations.used' "$FEAT_DIR/result.json")"
check "A: iterations.max=10" "10" "$(jq '.iterations.max' "$FEAT_DIR/result.json")"
check "A: branch" "feat/my-feature" "$(jq -r '.branch' "$FEAT_DIR/result.json")"
check "A: baseBranch" "main" "$(jq -r '.baseBranch' "$FEAT_DIR/result.json")"
check "A: finishedAt present" "1" "$([[ "$(jq -r '.finishedAt' "$FEAT_DIR/result.json")" != "null" ]] && echo 1 || echo 0)"
check "A: delivery status exposed" "ready-for-review" "$(jq -r '.delivery.status' "$FEAT_DIR/result.json")"
check "A: summary exposed" "Rate limiting was implemented and verified." "$(jq -r '.summary' "$FEAT_DIR/result.json")"
check "A: no-change reason defaults null" "null" "$(jq -r '.noChangeReason' "$FEAT_DIR/result.json")"
check "A: legacy result omits compact observability" "false" \
  "$(jq 'has("classification") or has("gatePlan")' "$FEAT_DIR/result.json")"

# Case B: converged=true with empty warnings
check "B: converged=true on clean completion" "true" "$(jq '.converged' "$FEAT_DIR/result.json")"
check "A: outcome delivered" "delivered" "$(jq -r '.outcome' "$FEAT_DIR/result.json")"
check "A: workDelivered true" "true" "$(jq '.workDelivered' "$FEAT_DIR/result.json")"

# Case C: converged=false when warnings contains iterate-budget-spent:
printf '%s\n' "$(jq '.warnings = ["iterate-budget-spent: foo gap"]' "$FEAT_DIR/feature.json")" > "$FEAT_DIR/feature.json"
bash "$LIB" write "$FEAT_DIR" --status completed --summary "Completed with iteration warnings." >/dev/null 2>&1
check "C: converged=false with iterate-budget-spent warning" "false" "$(jq '.converged' "$FEAT_DIR/result.json")"
check "C: outcome completed-with-gaps" "completed-with-gaps" "$(jq -r '.outcome' "$FEAT_DIR/result.json")"
check "C: workDelivered true despite gaps" "true" "$(jq '.workDelivered' "$FEAT_DIR/result.json")"
check "C: warnings array present" "1" "$(jq '.warnings | length' "$FEAT_DIR/result.json")"

# Restore clean warnings
printf '%s\n' "$FIXTURE_FJ" > "$FEAT_DIR/feature.json"

# Case D: --pr-url wins over feature.json .prUrl
printf '%s\n' "$(jq '.prUrl = "https://github.com/old/pr/1"' "$FEAT_DIR/feature.json")" > "$FEAT_DIR/feature.json"
bash "$LIB" write "$FEAT_DIR" --status completed --pr-url "https://github.com/new/pr/2" \
  --summary "Completed through the replacement PR." >/dev/null 2>&1
check "D: --pr-url wins over feature.json prUrl" "https://github.com/new/pr/2" "$(jq -r '.prUrl' "$FEAT_DIR/result.json")"

# Restore fixture
printf '%s\n' "$FIXTURE_FJ" > "$FEAT_DIR/feature.json"

# Case E: feature.json .prUrl used when no --pr-url arg
printf '%s\n' "$(jq '.prUrl = "https://github.com/feat/pr/5"' "$FEAT_DIR/feature.json")" > "$FEAT_DIR/feature.json"
bash "$LIB" write "$FEAT_DIR" --status completed --summary "Completed through the feature PR." >/dev/null 2>&1
check "E: feature.json prUrl used when no arg" "https://github.com/feat/pr/5" "$(jq -r '.prUrl' "$FEAT_DIR/result.json")"

# Restore fixture
printf '%s\n' "$FIXTURE_FJ" > "$FEAT_DIR/feature.json"

# Case F: last-result.json copy created at the right relative location
bash "$LIB" write "$FEAT_DIR" --status completed --summary "Completed and copied to the stable pointer." >/dev/null 2>&1
check "F: last-result.json created" "1" "$([[ -f "$LOOP_DIR/last-result.json" ]] && echo 1 || echo 0)"
check "F: last-result.json has same slug" "my-feature" "$(jq -r '.slug' "$LOOP_DIR/last-result.json")"

# Case G: missing feature.json → exit 0 + no result.json written
mkdir -p "$WORK/empty-feat"
rm -f "$WORK/empty-feat/result.json"
ec=0
bash "$LIB" write "$WORK/empty-feat" --status completed --summary "Missing fixture." >/dev/null 2>&1 || ec=$?
check "G: missing feature.json exits 0" "0" "$ec"
check "G: no result.json on missing feature.json" "0" "$([[ -f "$WORK/empty-feat/result.json" ]] && echo 1 || echo 0)"

# Case H: bad --status → exit 0 + no result.json written
printf '%s\n' "$FIXTURE_FJ" > "$FEAT_DIR/feature.json"
rm -f "$FEAT_DIR/result.json"
ec=0
bash "$LIB" write "$FEAT_DIR" --status invalid_status --summary "Invalid status." >/dev/null 2>&1 || ec=$?
check "H: bad --status exits 0" "0" "$ec"
check "H: no result.json on bad status" "0" "$([[ -f "$FEAT_DIR/result.json" ]] && echo 1 || echo 0)"

# Case I: the matching event line appears in events.jsonl
printf '%s\n' "$FIXTURE_FJ" > "$FEAT_DIR/feature.json"
rm -f "$FEAT_DIR/events.jsonl"
bash "$LIB" write "$FEAT_DIR" --status completed --summary "Completed with a matching event." >/dev/null 2>&1
check "I: events.jsonl written" "1" "$([[ -f "$FEAT_DIR/events.jsonl" ]] && echo 1 || echo 0)"
evt_event="$(tail -1 "$FEAT_DIR/events.jsonl" | jq -r '.event' 2>/dev/null || echo MISSING)"
check "I: event matches status" "completed" "$evt_event"

# Case J: --reason persisted in result.json; no --reason arg produces null
printf '%s\n' "$FIXTURE_FJ" > "$FEAT_DIR/feature.json"
bash "$LIB" write "$FEAT_DIR" --status paused --reason "user pause" \
  --summary "The run paused at the user's request." >/dev/null 2>&1
check "J: reason in result.json" "user pause" "$(jq -r '.reason' "$FEAT_DIR/result.json")"
printf '%s\n' "$FIXTURE_FJ" > "$FEAT_DIR/feature.json"
bash "$LIB" write "$FEAT_DIR" --status completed --summary "Completed without a failure reason." >/dev/null 2>&1
check "J2: no reason arg → reason is null" "null" "$(jq -r '.reason' "$FEAT_DIR/result.json")"

# Case K: converged=false for iterate-terminal: warning
printf '%s\n' "$(jq '.warnings = ["iterate-terminal: gap closed as terminal"]' "$FEAT_DIR/feature.json")" > "$FEAT_DIR/feature.json"
bash "$LIB" write "$FEAT_DIR" --status completed --summary "Completed with a terminal iteration warning." >/dev/null 2>&1
check "K: converged=false with iterate-terminal warning" "false" "$(jq '.converged' "$FEAT_DIR/result.json")"

# Case L: no --status → exit 0
printf '%s\n' "$FIXTURE_FJ" > "$FEAT_DIR/feature.json"
ec=0
bash "$LIB" write "$FEAT_DIR" >/dev/null 2>&1 || ec=$?
check "L: missing --status exits 0" "0" "$ec"

# Case M: successful DELIVER sidecar supplies logical completion without changing HEAD state.
printf '%s\n' "$(jq '.currentPhase = "deliver" | .prUrl = null | .delivery = {status:"pending",targets:[]}' \
  <<<"$FIXTURE_FJ")" > "$FEAT_DIR/feature.json"
jq -n '{schema:1,ok:true,status:"ready-for-review",nextPhase:"completed",
  prUrl:"https://github.com/sidecar/pr/9",attemptedAt:"2026-01-01T01:00:00Z",
  finishedAt:"2026-01-01T01:05:00Z",targets:[{name:"my-feature",ok:true}]}' \
  > "$FEAT_DIR/delivery.json"
bash "$LIB" write "$FEAT_DIR" --status completed --summary "Delivery completed from the sidecar." >/dev/null 2>&1
check "M: sidecar advances logical phase" "completed" "$(jq -r '.phaseReached' "$FEAT_DIR/result.json")"
check "M: sidecar PR exposed" "https://github.com/sidecar/pr/9" "$(jq -r '.prUrl' "$FEAT_DIR/result.json")"
check "M: sidecar delivery exposed" "ready-for-review" "$(jq -r '.delivery.status' "$FEAT_DIR/result.json")"
jq '(.targets[0].feedback) = {observationStatus:"complete",changesRequested:true}' \
  "$FEAT_DIR/delivery.json" > "$FEAT_DIR/delivery.json.tmp"
mv "$FEAT_DIR/delivery.json.tmp" "$FEAT_DIR/delivery.json"
bash "$LIB" write "$FEAT_DIR" --status completed --summary "Delivery completed with requested changes." >/dev/null 2>&1
check "M2: blocking feedback prevents convergence" "false" "$(jq '.converged' "$FEAT_DIR/result.json")"
check "M2: blocking feedback becomes a warning" "pr-feedback-changes-requested:my-feature" \
  "$(jq -r '.warnings[] | select(startswith("pr-feedback-changes-requested:"))' "$FEAT_DIR/result.json")"

# Case N: an explicit control root receives the stable pointer even when the
# feature state lives under a separate Claude worktree.
CONTROL="$WORK/control"
WT_FEAT="$WORK/worktree/.loop-spec/features/wt-feature"
mkdir -p "$CONTROL/.loop-spec" "$WT_FEAT"
printf '%s\n' "$(jq '.slug = "wt-feature"' <<<"$FIXTURE_FJ")" > "$WT_FEAT/feature.json"
LOOP_SPEC_RESULT_ROOT="$CONTROL" bash "$LIB" write "$WT_FEAT" --status completed \
  --summary "Worktree delivery completed." >/dev/null 2>&1
check "N: control-root pointer created" "1" "$([[ -f "$CONTROL/.loop-spec/last-result.json" ]] && echo 1 || echo 0)"
check "N: worktree pointer not substituted" "0" "$([[ -f "$WORK/worktree/.loop-spec/last-result.json" ]] && echo 1 || echo 0)"

# Legacy feature states without resultRoot recover the control checkout from Git's
# linked-worktree registry.
LEGACY_CONTROL="$WORK/legacy-control"
mkdir -p "$LEGACY_CONTROL"
git -C "$LEGACY_CONTROL" init -q
git -C "$LEGACY_CONTROL" -c user.name=Test -c user.email=test@example.com commit --allow-empty -qm init
LEGACY_WT="$WORK/legacy-worktree"
git -C "$LEGACY_CONTROL" worktree add -q -b legacy-feature "$LEGACY_WT"
LEGACY_FEAT="$LEGACY_WT/.loop-spec/features/legacy"
mkdir -p "$LEGACY_FEAT"
printf '%s\n' "$(jq 'del(.resultRoot) | .slug = "legacy"' <<<"$FIXTURE_FJ")" > "$LEGACY_FEAT/feature.json"
bash "$LIB" write "$LEGACY_FEAT" --status completed --summary "Legacy worktree delivery completed." >/dev/null 2>&1
check "N2: legacy worktree finds control pointer" "1" \
  "$([[ -f "$LEGACY_CONTROL/.loop-spec/last-result.json" ]] && echo 1 || echo 0)"
rm -f "$LEGACY_CONTROL/.loop-spec/last-result.json"
bash "$LIB" write-terminal --result-root "$LEGACY_WT" --cycle-type micro \
  --status completed --outcome verified --title "Linked micro" --pr-url https://example/pr/3 \
  --converged true --verification-status passed --summary "The linked micro task was delivered." >/dev/null
check "N3: reduced cycle resolves linked worktree control pointer" "1" \
  "$([[ -f "$LEGACY_CONTROL/.loop-spec/last-result.json" ]] && echo 1 || echo 0)"
check "N3: reduced cycle leaves no disposable pointer" "0" \
  "$([[ -f "$LEGACY_WT/.loop-spec/last-result.json" ]] && echo 1 || echo 0)"

# Case O: micro/debug use the same compatibility keys at the stable root.
GENERIC_ROOT="$WORK/generic"
mkdir -p "$GENERIC_ROOT"
bash "$LIB" write-terminal --result-root "$GENERIC_ROOT" --cycle-type micro \
  --status completed --outcome verified --slug doc-refresh --title "Refresh docs" \
  --branch micro/doc-refresh --base-branch main --pr-url https://github.com/test/repo/pull/8 \
  --converged true --verification-status passed --verification-command "bash tests/run-all.sh" \
  --autonomous true --summary "Documentation was refreshed and verified." >/dev/null
GENERIC_RESULT="$GENERIC_ROOT/.loop-spec/last-result.json"
check "O: generic pointer created" "1" "$([[ -f "$GENERIC_RESULT" ]] && echo 1 || echo 0)"
check "O: cycle type" "micro" "$(jq -r '.cycleType' "$GENERIC_RESULT")"
check "O: compatibility branch" "micro/doc-refresh" "$(jq -r '.branch' "$GENERIC_RESULT")"
check "O: compatibility PR" "https://github.com/test/repo/pull/8" "$(jq -r '.prUrl' "$GENERIC_RESULT")"
check "O: explicit convergence" "true" "$(jq -r '.converged' "$GENERIC_RESULT")"
check "O: workDelivered true" "true" "$(jq '.workDelivered' "$GENERIC_RESULT")"
check "O: verification command" "bash tests/run-all.sh" "$(jq -r '.verification.command' "$GENERIC_RESULT")"
check "O: reduced summary exposed" "Documentation was refreshed and verified." "$(jq -r '.summary' "$GENERIC_RESULT")"
check "O: reduced no-change reason defaults null" "null" "$(jq -r '.noChangeReason' "$GENERIC_RESULT")"
check "O: no temporary pointer remains" "0" "$([[ -f "$GENERIC_RESULT.tmp" ]] && echo 1 || echo 0)"

# A checkpoint PR is the interruption salvage, not shipped work: the terminal
# writer must not report it as workDelivered.
rm -f "$GENERIC_RESULT"
bash "$LIB" write-terminal --result-root "$GENERIC_ROOT" --cycle-type micro \
  --status failed --outcome interrupted --slug doc-refresh --title "Refresh docs" \
  --pr-url https://github.com/test/repo/pull/9 \
  --checkpoint-pr-url https://github.com/test/repo/pull/9 \
  --converged false --verification-status not-run --summary "Run was interrupted." >/dev/null
check "O: checkpoint-only PR is not workDelivered" "false" "$(jq '.workDelivered' "$GENERIC_RESULT")"
rm -f "$GENERIC_RESULT"
bash "$LIB" write-terminal --result-root "$GENERIC_ROOT" --cycle-type micro \
  --status completed --outcome verified --slug doc-refresh --title "Refresh docs" \
  --branch micro/doc-refresh --base-branch main \
  --pr-url https://github.com/test/repo/pull/8 \
  --checkpoint-pr-url https://github.com/test/repo/pull/9 \
  --converged true --verification-status passed --summary "Documentation was refreshed." >/dev/null
check "O: delivered PR beside a checkpoint is workDelivered" "true" \
  "$(jq '.workDelivered' "$GENERIC_RESULT")"

# Case P: contradictory success claims are rejected and clear removes stale pointers.
rm -f "$GENERIC_RESULT"
bash "$LIB" write-terminal --result-root "$GENERIC_ROOT" --cycle-type micro \
  --status failed --outcome verification-failed --title "Bad claim" --pr-url https://example/pr/1 \
  --converged true --verification-status passed --summary "Contradictory claim." >/dev/null 2>&1
check "P: contradictory convergence rejected" "0" "$([[ -f "$GENERIC_RESULT" ]] && echo 1 || echo 0)"
bash "$LIB" write-terminal --result-root "$GENERIC_ROOT" --cycle-type debug \
  --status completed --outcome fixed --title "Fixed" --pr-url https://example/pr/2 \
  --converged true --verification-status passed --summary "The defect was fixed and verified." >/dev/null
bash "$LIB" clear --result-root "$GENERIC_ROOT"
check "P: clear removes stale pointer" "0" "$([[ -f "$GENERIC_RESULT" ]] && echo 1 || echo 0)"

# Case Q: result operations never follow a symlinked .loop-spec directory.
SYMLINK_ROOT="$WORK/symlink-root"
EXTERNAL_ROOT="$WORK/external-loop-spec"
mkdir -p "$SYMLINK_ROOT" "$EXTERNAL_ROOT"
printf 'keep\n' > "$EXTERNAL_ROOT/last-result.json"
ln -s "$EXTERNAL_ROOT" "$SYMLINK_ROOT/.loop-spec"
ec=0
bash "$LIB" clear --result-root "$SYMLINK_ROOT" >/dev/null 2>&1 || ec=$?
check "Q: unsafe clear fails loudly" "1" "$ec"
check "Q: unsafe clear preserves external pointer" "keep" "$(<"$EXTERNAL_ROOT/last-result.json")"
bash "$LIB" write-terminal --result-root "$SYMLINK_ROOT" --cycle-type micro \
  --status completed --outcome verified --title "Unsafe" --pr-url https://example/pr/4 \
  --converged true --verification-status passed --summary "Unsafe destination test." >/dev/null 2>&1
check "Q: unsafe write preserves external pointer" "keep" "$(<"$EXTERNAL_ROOT/last-result.json")"
SYMLINK_FEATURE="$SYMLINK_ROOT/.loop-spec/features/unsafe"
mkdir -p "$SYMLINK_FEATURE"
printf '%s\n' "$(jq '.slug = "unsafe"' <<<"$FIXTURE_FJ")" > "$SYMLINK_FEATURE/feature.json"
bash "$LIB" write "$SYMLINK_FEATURE" --status completed --summary "Unsafe full destination test." >/dev/null 2>&1
check "Q: unsafe full write preserves external pointer" "keep" "$(<"$EXTERNAL_ROOT/last-result.json")"
check "Q: unsafe full write creates no external result" "0" \
  "$([[ -f "$SYMLINK_FEATURE/result.json" ]] && echo 1 || echo 0)"
check "Q: unsafe full write creates no external events" "0" \
  "$([[ -f "$SYMLINK_FEATURE/events.jsonl" ]] && echo 1 || echo 0)"

# Case R: a SHA-bound DELIVER failure is a retryable delivery block, not an
# implementation failure or successful end-to-end convergence.
printf '%s\n' "$(jq '.currentPhase = "deliver" | .delivery = {status:"pending",targets:[]}' \
  <<<"$FIXTURE_FJ")" > "$FEAT_DIR/feature.json"
jq -n '{schema:1,ok:false,status:"push-failed",nextPhase:"deliver",
  attemptedAt:"2026-01-01T01:00:00Z",finishedAt:null,
  targets:[
    {name:"my-feature",ok:false,branch:"feat/delivery-target",
      targetSha:"immutable123",checks:{status:"not-run"},errorCode:"push_failed",
      error:"push failed"},
    {name:"auth-target",ok:false,branch:"feat/auth",targetSha:"auth456",
      bindingEligible:true,checks:{status:"not-run"},errorCode:"authentication_failed",
      error:"authentication failed"}
  ]}' > "$FEAT_DIR/delivery.json"
bash "$LIB" write "$FEAT_DIR" --status escalated --reason "push failed" \
  --summary "Implementation verified, but delivery was blocked by the push failure." >/dev/null 2>&1
check "R: delivery block status is failed" "failed" "$(jq -r '.status' "$FEAT_DIR/result.json")"
check "R: delivery block outcome" "delivery-blocked" "$(jq -r '.outcome' "$FEAT_DIR/result.json")"
check "R: delivery phase reached" "deliver" "$(jq -r '.phaseReached' "$FEAT_DIR/result.json")"
check "R: implementation converged" "true" "$(jq -r '.implementationConverged' "$FEAT_DIR/result.json")"
check "R: end-to-end convergence remains false" "false" "$(jq -r '.converged' "$FEAT_DIR/result.json")"
check "R: pre-delivery verification passed" "passed" "$(jq -r '.verification.status' "$FEAT_DIR/result.json")"
check "R: delivery block is retryable" "true" "$(jq -r '.retryable' "$FEAT_DIR/result.json")"
check "R: retry phase" "deliver" "$(jq -r '.retryPhase' "$FEAT_DIR/result.json")"
check "R: branch comes from bound delivery target" "feat/delivery-target" "$(jq -r '.branch' "$FEAT_DIR/result.json")"
check "R: verified SHA is the immutable delivery target" "immutable123" "$(jq -r '.verifiedSha' "$FEAT_DIR/result.json")"
check "R: legacy transport target is exposed as eligible" "immutable123" \
  "$(jq -r '.eligibleTargets[0].targetSha' "$FEAT_DIR/result.json")"
check "R: explicit eligible auth target is exposed" "auth456" \
  "$(jq -r '.eligibleTargets[] | select(.name == "auth-target") | .targetSha' "$FEAT_DIR/result.json")"
check "R: matching event uses normalized failed status" "failed" "$(tail -1 "$FEAT_DIR/events.jsonl" | jq -r '.event')"

# nextPhase=execute is remediation, not a terminal delivery block.
jq '.nextPhase = "execute"' "$FEAT_DIR/delivery.json" > "$FEAT_DIR/delivery.json.tmp"
mv "$FEAT_DIR/delivery.json.tmp" "$FEAT_DIR/delivery.json"
bash "$LIB" write "$FEAT_DIR" --status escalated --reason "checks failed" \
  --summary "Required checks failed and need remediation." >/dev/null 2>&1
check "R2: execute rewind is not delivery-blocked" "escalated" "$(jq -r '.outcome' "$FEAT_DIR/result.json")"
check "R2: execute rewind is not marked retryable delivery" "false" "$(jq -r '.retryable' "$FEAT_DIR/result.json")"

# A nextPhase=deliver sidecar containing only local-preflight failures has no
# immutable delivery candidate and must remain a conservative escalation.
jq -n '{schema:1,ok:false,status:"no-changes",nextPhase:"deliver",
  attemptedAt:"2026-01-01T01:00:00Z",finishedAt:null,
  targets:[
    {name:"my-feature",ok:false,branch:"feat/my-feature",targetSha:"local123",
      errorCode:"no_commits",error:"no commits"},
    {name:"dirty-sibling",ok:false,branch:"feat/dirty",targetSha:"dirty456",
      bindingEligible:false,errorCode:"dirty_worktree",error:"dirty"},
    {name:"explicitly-ineligible",ok:false,branch:"feat/no-bind",targetSha:"noBind789",
      bindingEligible:false,errorCode:"push_failed",error:"not eligible"}
  ]}' > "$FEAT_DIR/delivery.json"
bash "$LIB" write "$FEAT_DIR" --status failed --reason "local preflight failed" \
  --summary "Local delivery preflight could not establish a deliverable candidate." >/dev/null 2>&1
check "R3: local-only failure remains escalated" "escalated" "$(jq -r '.status' "$FEAT_DIR/result.json")"
check "R3: local-only outcome remains escalated" "escalated" "$(jq -r '.outcome' "$FEAT_DIR/result.json")"
check "R3: local-only failure is not implementation-converged" "false" \
  "$(jq -r '.implementationConverged' "$FEAT_DIR/result.json")"
check "R3: delivery phase still records passed verification" "passed" \
  "$(jq -r '.verification.status' "$FEAT_DIR/result.json")"
check "R3: local-only failure is not retryable" "false" "$(jq -r '.retryable' "$FEAT_DIR/result.json")"
check "R3: local-only failure has no retry phase" "null" "$(jq -r '.retryPhase' "$FEAT_DIR/result.json")"
check "R3: local-only failure has no verified SHA" "null" "$(jq -r '.verifiedSha' "$FEAT_DIR/result.json")"
check "R3: local-only failure exposes no eligible targets" "0" \
  "$(jq '.eligibleTargets | length' "$FEAT_DIR/result.json")"
check "R3: matching event remains escalated" "escalated" \
  "$(tail -1 "$FEAT_DIR/events.jsonl" | jq -r '.event')"

# Case S: workspace delivery records retain each target's own branch and bound SHA.
printf '%s\n' "$(jq '.currentPhase = "deliver" | .branch = null |
  .workspace = {root:"/workspace",repos:[{name:"api",path:"api"},{name:"web",path:"web"}]}' \
  <<<"$FIXTURE_FJ")" > "$FEAT_DIR/feature.json"
jq -n '{schema:1,ok:false,status:"partial",nextPhase:"deliver",
  attemptedAt:"2026-01-01T01:00:00Z",finishedAt:null,
  targets:[
    {name:"api",ok:false,branch:"feat/api",targetSha:"api123",errorCode:"push_failed"},
    {name:"web",ok:false,branch:"feat/web",targetSha:"web456",errorCode:"branch_mismatch"}
  ]}' > "$FEAT_DIR/delivery.json"
bash "$LIB" write "$FEAT_DIR" --status escalated \
  --summary "Workspace delivery was blocked before all targets were eligible." >/dev/null 2>&1
check "S: workspace top-level branch remains null" "null" "$(jq -r '.branch' "$FEAT_DIR/result.json")"
check "S: workspace top-level SHA remains null" "null" "$(jq -r '.verifiedSha' "$FEAT_DIR/result.json")"
check "S: workspace target branches preserved" 'api:feat/api,web:feat/web' \
  "$(jq -r '.delivery.targets | map(.name + ":" + .branch) | join(",")' "$FEAT_DIR/result.json")"
check "S: workspace target SHAs preserved" 'api:api123,web:web456' \
  "$(jq -r '.delivery.targets | map(.name + ":" + .targetSha) | join(",")' "$FEAT_DIR/result.json")"
check "S: workspace exposes only eligible immutable targets" 'api:feat/api:api123' \
  "$(jq -r '.eligibleTargets | map(.name + ":" + .branch + ":" + .targetSha) | join(",")' "$FEAT_DIR/result.json")"
check "S: mixed local and transport failure remains escalation" "escalated" \
  "$(jq -r '.outcome' "$FEAT_DIR/result.json")"
check "S: mixed local and transport failure is not retryable" "false" \
  "$(jq -r '.retryable' "$FEAT_DIR/result.json")"

# Case T: every newly written record requires a non-empty human synthesis.
rm -f "$FEAT_DIR/result.json"
bash "$LIB" write "$FEAT_DIR" --status completed >/dev/null 2>&1
check "T: full result without summary rejected" "0" \
  "$([[ -f "$FEAT_DIR/result.json" ]] && echo 1 || echo 0)"
rm -f "$GENERIC_RESULT"
bash "$LIB" write-terminal --result-root "$GENERIC_ROOT" --cycle-type micro \
  --status completed --outcome verified --title "Missing summary" --pr-url https://example/pr/5 \
  --converged true --verification-status passed >/dev/null 2>&1
check "T2: reduced result without summary rejected" "0" \
  "$([[ -f "$GENERIC_RESULT" ]] && echo 1 || echo 0)"

# Case U: an explicit already-satisfied conclusion converts deterministic
# no-commit delivery evidence into a successful no-change result.
printf '%s\n' "$(jq '.currentPhase = "deliver" | .prUrl = null |
  .checkpointPrUrl = "https://example/stale-checkpoint" |
  .iterate.lastVerdict = {converged:true,deterministic_gate_passed:true,summary:"The requested behavior was already present."} |
  .delivery = {status:"pending",targets:[]}' <<<"$FIXTURE_FJ")" > "$FEAT_DIR/feature.json"
jq -n '{schema:1,ok:false,status:"no-changes",nextPhase:"deliver",prUrl:null,
  attemptedAt:"2026-01-01T01:00:00Z",finishedAt:null,
  targets:[{name:"my-feature",ok:false,branch:"feat/my-feature",targetSha:"local123",
    bindingEligible:false,errorCode:"no_commits",error:"no commits"}]}' > "$FEAT_DIR/delivery.json"
bash "$LIB" write "$FEAT_DIR" --status completed \
  --summary "The requested behavior was already present; verification found no implementation gap." \
  --no-change-reason already-satisfied >/dev/null 2>&1
check "U: intentional no-change is completed" "completed" "$(jq -r '.status' "$FEAT_DIR/result.json")"
check "U: intentional no-change outcome" "no-change-needed" "$(jq -r '.outcome' "$FEAT_DIR/result.json")"
check "U: intentional no-change converged" "true" "$(jq -r '.converged' "$FEAT_DIR/result.json")"
check "U: intentional no-change reason code" "already-satisfied" "$(jq -r '.noChangeReason' "$FEAT_DIR/result.json")"
check "U: intentional no-change has no PR" "null" "$(jq -r '.prUrl' "$FEAT_DIR/result.json")"
check "U: workDelivered false" "false" "$(jq '.workDelivered' "$FEAT_DIR/result.json")"
check "U: intentional no-change has no checkpoint PR" "null" \
  "$(jq -r '.checkpointPrUrl' "$FEAT_DIR/result.json")"

rm -f "$FEAT_DIR/result.json"
jq '.targets[0].errorCode = "dirty_worktree"' "$FEAT_DIR/delivery.json" > "$FEAT_DIR/delivery.json.tmp"
mv "$FEAT_DIR/delivery.json.tmp" "$FEAT_DIR/delivery.json"
bash "$LIB" write "$FEAT_DIR" --status completed --summary "Invalid no-change claim." \
  --no-change-reason already-satisfied >/dev/null 2>&1
check "U2: no-change without no-commit evidence rejected" "0" \
  "$([[ -f "$FEAT_DIR/result.json" ]] && echo 1 || echo 0)"

jq '.targets[0].errorCode = "no_commits"' "$FEAT_DIR/delivery.json" > "$FEAT_DIR/delivery.json.tmp"
mv "$FEAT_DIR/delivery.json.tmp" "$FEAT_DIR/delivery.json"
printf '%s\n' "$(jq '.iterate.lastVerdict.deterministic_gate_passed = false' \
  "$FEAT_DIR/feature.json")" > "$FEAT_DIR/feature.json"
bash "$LIB" write "$FEAT_DIR" --status completed --summary "Model-only convergence." \
  --no-change-reason already-satisfied >/dev/null 2>&1
check "U3: no-change with failed deterministic gate rejected" "0" \
  "$([[ -f "$FEAT_DIR/result.json" ]] && echo 1 || echo 0)"

printf '%s\n' "$(jq '.iterate.lastVerdict.deterministic_gate_passed = true |
  .warnings = ["iterate-budget-spent: unresolved behavior"]' "$FEAT_DIR/feature.json")" \
  > "$FEAT_DIR/feature.json"
bash "$LIB" write "$FEAT_DIR" --status completed --summary "Warning-bearing no-change." \
  --no-change-reason already-satisfied >/dev/null 2>&1
check "U4: no-change with unresolved iteration warning rejected" "0" \
  "$([[ -f "$FEAT_DIR/result.json" ]] && echo 1 || echo 0)"

# Case V: reduced work and diagnostics share the common no-change shape while
# preserving a small, cycle-appropriate reason-code vocabulary.
rm -f "$GENERIC_RESULT"
bash "$LIB" write-terminal --result-root "$GENERIC_ROOT" --cycle-type micro \
  --status completed --outcome no-change-needed --slug existing-config --title "Check config" \
  --converged true --verification-status passed \
  --summary "The requested configuration was already present and passed validation." \
  --no-change-reason already-satisfied >/dev/null
check "V: reduced no-change completed" "completed" "$(jq -r '.status' "$GENERIC_RESULT")"
check "V: reduced no-change reason" "already-satisfied" "$(jq -r '.noChangeReason' "$GENERIC_RESULT")"
check "V: reduced no-change has no PR" "null" "$(jq -r '.prUrl' "$GENERIC_RESULT")"
check "V: workDelivered false" "false" "$(jq '.workDelivered' "$GENERIC_RESULT")"

rm -f "$GENERIC_RESULT"
bash "$LIB" write-terminal --result-root "$GENERIC_ROOT" --cycle-type diagnostic \
  --status completed --outcome no-change-needed --slug forensics --title "Forensic diagnosis" \
  --converged true --verification-status not-run \
  --summary "No workflow anomalies were detected; recorded state is internally consistent." \
  --no-change-reason diagnostic-only >/dev/null
check "V2: diagnostic result created" "1" "$([[ -f "$GENERIC_RESULT" ]] && echo 1 || echo 0)"
check "V2: diagnostic cycle type" "diagnostic" "$(jq -r '.cycleType' "$GENERIC_RESULT")"
check "V2: diagnostic summary" "No workflow anomalies were detected; recorded state is internally consistent." \
  "$(jq -r '.summary' "$GENERIC_RESULT")"
check "V2: diagnostic reason code" "diagnostic-only" "$(jq -r '.noChangeReason' "$GENERIC_RESULT")"

rm -f "$GENERIC_RESULT"
bash "$LIB" write-terminal --result-root "$GENERIC_ROOT" --cycle-type diagnostic \
  --status completed --outcome no-change-needed --slug assess --title "Assessment" \
  --converged true --verification-status not-run --summary "Assessment completed." \
  --no-change-reason already-satisfied >/dev/null 2>&1
check "V3: diagnostic rejects work-cycle reason" "0" \
  "$([[ -f "$GENERIC_RESULT" ]] && echo 1 || echo 0)"

rm -f "$GENERIC_RESULT"
bash "$LIB" write-terminal --result-root "$GENERIC_ROOT" --cycle-type micro \
  --status completed --outcome no-change-needed --title "Unverified no-change" \
  --converged true --verification-status not-run --summary "No verification was run." \
  --no-change-reason already-satisfied >/dev/null 2>&1
check "V4: work no-change requires passed verification" "0" \
  "$([[ -f "$GENERIC_RESULT" ]] && echo 1 || echo 0)"

bash "$LIB" write-terminal --result-root "$GENERIC_ROOT" --cycle-type diagnostic \
  --status failed --outcome diagnostic-failed --title "Failed diagnosis" \
  --converged false --verification-status not-run --reason "report write failed" \
  --summary "Forensic diagnosis failed because the report could not be written." >/dev/null
check "V5: diagnostic failure recorded" "failed" "$(jq -r '.status' "$GENERIC_RESULT")"
check "V5: diagnostic failure has no no-change reason" "null" \
  "$(jq -r '.noChangeReason' "$GENERIC_RESULT")"

# Case W: a full cycle publishes an active pointer before feature state exists,
# and an out-of-band reconciler can turn it into a terminal result.
ACTIVE_RESULT="$GENERIC_ROOT/.loop-spec/active-run.json"
bash "$LIB" begin --result-root "$GENERIC_ROOT" --cycle-type full \
  --title "Cloud task" --slug cloud-task --branch feat/cloud-task --base-branch main \
  --phase startup --autonomous true
check "W: active pointer created" "1" "$([[ -f "$ACTIVE_RESULT" ]] && echo 1 || echo 0)"
check "W: active pointer names phase" "startup:true" \
  "$(jq -r '.phase + ":" + (.autonomous | tostring)' "$ACTIVE_RESULT")"
bash "$REPO_ROOT/lib/cycle-reconcile.sh" --result-root "$GENERIC_ROOT" \
  --reason "container terminated" >/dev/null
check "W2: reconciler writes full result" "full:failed:interrupted" \
  "$(jq -r '.cycleType + ":" + .status + ":" + .outcome' "$GENERIC_RESULT")"
check "W2: reconciler keeps phase" "startup" "$(jq -r '.phaseReached' "$GENERIC_RESULT")"
check "W2: terminal write clears active pointer" "0" \
  "$([[ -f "$ACTIVE_RESULT" ]] && echo 1 || echo 0)"

bash "$LIB" begin --result-root "$GENERIC_ROOT" --cycle-type full \
  --title "Setup task" --slug setup-task --phase startup
bash "$LIB" write-terminal --result-root "$GENERIC_ROOT" --cycle-type full \
  --status failed --outcome infrastructure-failed --title "Setup task" \
  --slug setup-task --phase-reached startup --converged false \
  --verification-status not-run --reason "idle_timeout" \
  --summary "Environment preparation failed: idle_timeout." >/dev/null
check "W3: startup failure has terminal outcome" "infrastructure-failed:idle_timeout" \
  "$(jq -r '.outcome + ":" + .reason' "$GENERIC_RESULT")"
check "W3: startup failure clears active pointer" "0" \
  "$([[ -f "$ACTIVE_RESULT" ]] && echo 1 || echo 0)"

full_success_ec=0
full_success_hint="$(bash "$LIB" write-terminal --result-root "$GENERIC_ROOT" \
  --cycle-type full --status completed --outcome verified --title "Wrong writer" \
  --converged true --verification-status passed --summary "Done." 2>&1 >/dev/null)" || full_success_ec=$?
check "W4: rejected full success names the correct writer" "1" \
  "$(grep -c 'write <feature_dir> --status completed' <<<"$full_success_hint")"
check "W4: rejected full success names the delivered alias" "1" \
  "$(grep -c 'write-terminal --outcome delivered' <<<"$full_success_hint")"
check "W4: rejected success-shaped full outcome exits 3 (not silent 0)" "3" "$full_success_ec"

# Case W5: --outcome delivered is DELIVER's word; map it onto write --status
# completed, including the sequence that actually bit us (reconcile stamped
# interrupted first, then the agent tried to overwrite with the natural phrasing).
printf '%s\n' "$FIXTURE_FJ" > "$FEAT_DIR/feature.json"
rm -f "$FEAT_DIR/delivery.json"
bash "$LIB" begin --result-root "$WORK" --cycle-type full \
  --title "Add rate limiting" --slug my-feature --feature-dir "$FEAT_DIR" \
  --phase deliver --autonomous true
LOOP_SPEC_RESULT_ROOT="$WORK" bash "$LIB" write "$FEAT_DIR" --status failed \
  --reason "agent process terminated before emitting a terminal result" \
  --summary "Cycle interrupted during deliver: agent process terminated" >/dev/null
check "W5: interrupted pointer lands first" "failed" \
  "$(jq -r '.status' "$LOOP_DIR/last-result.json")"
delivered_ec=0
bash "$LIB" write-terminal --result-root "$WORK" --cycle-type full \
  --outcome delivered --summary "Migrated and opened PR #39." >/dev/null || delivered_ec=$?
check "W5: --outcome delivered exits 0" "0" "$delivered_ec"
check "W5: --outcome delivered overwrites interrupted" "completed:delivered:true" \
  "$(jq -r '.status + ":" + .outcome + ":" + (.converged | tostring)' "$LOOP_DIR/last-result.json")"
check "W5: --outcome delivered keeps the PR" "https://github.com/test/repo/pull/1" \
  "$(jq -r '.prUrl' "$LOOP_DIR/last-result.json")"

rm -f "$FEAT_DIR/result.json" "$LOOP_DIR/last-result.json" "$FEAT_DIR/delivery.json"
bash "$LIB" write "$FEAT_DIR" --outcome delivered \
  --summary "write --outcome delivered is the same alias." >/dev/null
check "W5b: write --outcome delivered is --status completed" "completed:delivered:true" \
  "$(jq -r '.status + ":" + .outcome + ":" + (.converged | tostring)' "$FEAT_DIR/result.json")"

# Case W6: reconcile must not stamp interrupted over a delivered PR.
printf '%s\n' "$FIXTURE_FJ" > "$FEAT_DIR/feature.json"
rm -f "$LOOP_DIR/last-result.json" "$FEAT_DIR/delivery.json"
bash "$LIB" begin --result-root "$WORK" --cycle-type full \
  --title "Add rate limiting" --slug my-feature --feature-dir "$FEAT_DIR" \
  --phase deliver --autonomous true
bash "$REPO_ROOT/lib/cycle-reconcile.sh" --result-root "$WORK" \
  --reason "routed skill ended without emitting a terminal result" >/dev/null
check "W6: reconcile over a delivered PR is completed, not interrupted" \
  "completed:delivered:true" \
  "$(jq -r '.status + ":" + .outcome + ":" + (.converged | tostring)' "$LOOP_DIR/last-result.json")"

# The run that bit us never entered DELIVER, so currentPhase can still be
# execute while feature.json.prUrl already names the opened PR.
printf '%s\n' "$(jq '.currentPhase = "execute" | del(.delivery)' <<<"$FIXTURE_FJ")" \
  > "$FEAT_DIR/feature.json"
rm -f "$LOOP_DIR/last-result.json" "$FEAT_DIR/delivery.json"
bash "$LIB" begin --result-root "$WORK" --cycle-type full \
  --title "Add rate limiting" --slug my-feature --feature-dir "$FEAT_DIR" \
  --phase execute --autonomous true
bash "$REPO_ROOT/lib/cycle-reconcile.sh" --result-root "$WORK" \
  --reason "routed skill ended without emitting a terminal result" >/dev/null
check "W6b: reconcile over a PR with currentPhase still execute is completed" \
  "completed:delivered:true" \
  "$(jq -r '.status + ":" + .outcome + ":" + (.converged | tostring)' "$LOOP_DIR/last-result.json")"

# A checkpoint PR is the interruption record, not a delivered feature PR.
printf '%s\n' "$(jq '.currentPhase = "execute" | del(.delivery)
  | .checkpointPrUrl = .prUrl' <<<"$FIXTURE_FJ")" > "$FEAT_DIR/feature.json"
rm -f "$LOOP_DIR/last-result.json" "$FEAT_DIR/delivery.json"
bash "$LIB" begin --result-root "$WORK" --cycle-type full \
  --title "Add rate limiting" --slug my-feature --feature-dir "$FEAT_DIR" \
  --phase execute --autonomous true
bash "$REPO_ROOT/lib/cycle-reconcile.sh" --result-root "$WORK" \
  --reason "routed skill ended without emitting a terminal result" >/dev/null
check "W6c: reconcile over a checkpoint-only PR stays interrupted" \
  "failed:false" \
  "$(jq -r '.status + ":" + (.converged | tostring)' "$LOOP_DIR/last-result.json")"

# A SHA-bound green draft is delivered for resume, not a gap and not interrupted.
printf '%s\n' "$(jq '.currentPhase = "deliver" | .delivery = {status:"pending",targets:[]}' \
  <<<"$FIXTURE_FJ")" > "$FEAT_DIR/feature.json"
jq -n '{schema:1,ok:true,status:"delivered-draft",nextPhase:"completed",
  prUrl:"https://github.com/test/repo/pull/1",attemptedAt:"2026-01-01T01:00:00Z",
  finishedAt:"2026-01-01T01:05:00Z",
  targets:[{name:"my-feature",ok:true,outcome:"delivered-draft",
    prUrl:"https://github.com/test/repo/pull/1",targetSha:"abc",
    checks:{status:"passed"}}]}' > "$FEAT_DIR/delivery.json"
rm -f "$LOOP_DIR/last-result.json"
bash "$LIB" begin --result-root "$WORK" --cycle-type full \
  --title "Draft sign-off" --slug my-feature --feature-dir "$FEAT_DIR" \
  --phase deliver --autonomous true
LOOP_SPEC_RESULT_ROOT="$WORK" bash "$REPO_ROOT/lib/cycle-reconcile.sh" \
  --result-root "$WORK" --reason "supervisor recovered a draft delivery" >/dev/null
check "W6d: reconcile over delivered-draft is completed, not interrupted" \
  "completed:delivered-draft:false" \
  "$(jq -r '.status + ":" + .outcome + ":" + (.converged | tostring)' "$LOOP_DIR/last-result.json")"
check "W6d: draft delivery still counts as work shipped" "true" \
  "$(jq '.workDelivered' "$LOOP_DIR/last-result.json")"

# Case X: a phase handoff is terminal for one invocation while preserving
# resumable feature state for the next fresh agent.
printf '%s\n' "$(jq '.currentPhase = "plan"' <<<"$FIXTURE_FJ")" > "$FEAT_DIR/feature.json"
bash "$LIB" begin --result-root "$WORK" --cycle-type full \
  --title "Phase handoff" --slug my-feature --branch feat/my-feature \
  --base-branch main --feature-dir "$FEAT_DIR" --phase discuss
LOOP_SPEC_RESULT_ROOT="$WORK" bash "$LIB" write "$FEAT_DIR" --status paused \
  --reason phase-handoff \
  --summary "Phase discuss completed; plan is ready in durable state." >/dev/null
check "X: phase handoff is a paused result" "paused:phase-handoff:plan" \
  "$(jq -r '.status + ":" + .reason + ":" + .phaseReached' "$LOOP_DIR/last-result.json")"
check "X: phase handoff clears active pointer" "0" \
  "$([[ -f "$LOOP_DIR/active-run.json" ]] && echo 1 || echo 0)"
check "X: feature remains resumable" "plan" "$(jq -r '.currentPhase' "$FEAT_DIR/feature.json")"

# --- Case Y: publication failure is LOUD and preserves the recovery record -------
# Exit 0 with no pointer is how an unattended run gets lost: the supervisor reads
# "success, no result". Publication failures exit 3 and keep active-run.json so
# cycle-reconcile.sh still has something to recover from.
Y="$WORK/pubfail"; mkdir -p "$Y/.loop-spec/features/f1"
git -C "$Y" init -q 2>/dev/null
printf '%s' "$FIXTURE_FJ" | jq '.slug="f1"' > "$Y/.loop-spec/features/f1/feature.json"
printf '{"schema":1,"title":"t"}' > "$Y/.loop-spec/active-run.json"
term_args=(--cycle-type micro --status failed --outcome verification-failed
  --title t --converged false --summary s --verification-status failed)

# An unwritable directory is how this case simulates a publication failure, and
# root ignores the mode bits entirely -- the writes would succeed and every
# assertion below would report a product bug that does not exist. CI containers
# routinely run as root, so detect it and skip loudly rather than fail falsely.
if [[ "$(id -u)" -eq 0 ]]; then
  echo "SKIP: Y: publication-failure cases (running as root; chmod 555 does not deny uid 0)"
else
  chmod 555 "$Y/.loop-spec"
  ec=0; bash "$LIB" write-terminal --result-root "$Y" "${term_args[@]}" >/dev/null 2>&1 || ec=$?
  check "Y: write-terminal publication failure exits 3" "3" "$ec"
  err="$(bash "$LIB" write-terminal --result-root "$Y" "${term_args[@]}" 2>&1 >/dev/null | grep -c 'TERMINAL RESULT NOT PUBLISHED' || true)"
  check "Y: write-terminal failure is loud" "1" "$err"
  check "Y: write-terminal failure preserves active-run.json" "1" \
    "$([[ -f "$Y/.loop-spec/active-run.json" ]] && echo 1 || echo 0)"

  ec=0; LOOP_SPEC_RESULT_ROOT="$Y" bash "$LIB" write "$Y/.loop-spec/features/f1" \
    --status failed --summary s --reason r >/dev/null 2>&1 || ec=$?
  check "Y: write pointer-publication failure exits 3" "3" "$ec"
  check "Y: write failure preserves active-run.json" "1" \
    "$([[ -f "$Y/.loop-spec/active-run.json" ]] && echo 1 || echo 0)"
  chmod 755 "$Y/.loop-spec"
fi

# Success afterwards: pointer lands, exit 0, recovery record consumed.
ec=0; bash "$LIB" write-terminal --result-root "$Y" "${term_args[@]}" >/dev/null 2>&1 || ec=$?
check "Y: publication success still exits 0" "0" "$ec"
check "Y: publication success writes the pointer" "1" \
  "$([[ -f "$Y/.loop-spec/last-result.json" ]] && echo 1 || echo 0)"
check "Y: publication success consumes active-run.json" "0" \
  "$([[ -f "$Y/.loop-spec/active-run.json" ]] && echo 1 || echo 0)"

# --- Case Z: the route-exit contract --------------------------------------------
# A route is armed before its skill starts and disarmed only by a published result,
# so "left the protocol and finished by hand" is detectable instead of silent.
Z="$WORK/route"; mkdir -p "$Z"
git -C "$Z" init -q
git -C "$Z" -c user.name=Test -c user.email=test@example.com commit --allow-empty -qm init
check "Z: idle root reports idle" "idle" "$(bash "$LIB" state --result-root "$Z" | cut -d' ' -f1)"

bash "$LIB" begin --result-root "$Z" --cycle-type micro --title "What is the architecture?" \
  --phase routing --autonomous true
check "Z: reduced routes arm the same record" "micro" "$(jq -r '.cycleType' "$Z/.loop-spec/active-run.json")"
Z_STATE="$(bash "$LIB" state --result-root "$Z")"
check "Z: armed run is unaccounted" "unaccounted" "$(cut -d' ' -f1 <<<"$Z_STATE")"
check "Z: probe reports the armed autonomy" "1" \
  "$(grep -c 'autonomous=true' <<<"$Z_STATE")"
check "Z: probe reports an age" "1" "$(grep -cE 'ageSeconds=[0-9]+' <<<"$Z_STATE")"

# The mismatch record is the honest exit from a genuine non-task, not from a
# rebase/sync/chore the router already accepted.
bash "$LIB" write-terminal --result-root "$Z" --cycle-type micro --status escalated \
  --outcome protocol-mismatch --title "What is the architecture?" --converged false \
  --reason "the request is a question, not a code-change task" \
  --summary "The request is not repository work; no repository work was done." >/dev/null
Z_RESULT="$Z/.loop-spec/last-result.json"
check "Z: mismatch publishes a terminal result" "escalated:protocol-mismatch:false" \
  "$(jq -r '.status + ":" + .outcome + ":" + (.converged | tostring)' "$Z_RESULT")"
check "Z: mismatch disarms the run" "published" "$(bash "$LIB" state --result-root "$Z" | cut -d' ' -f1)"

# Mismatch is a declaration about work NOT done, so its preconditions are checked.
rm -f "$Z_RESULT"
bash "$LIB" write-terminal --result-root "$Z" --cycle-type micro --status failed \
  --outcome protocol-mismatch --title "Bad status" --converged false --reason r \
  --summary "Mismatch claimed without escalating." >/dev/null 2>&1
check "Z: mismatch requires escalated status" "0" "$([[ -f "$Z_RESULT" ]] && echo 1 || echo 0)"
bash "$LIB" write-terminal --result-root "$Z" --cycle-type micro --status escalated \
  --outcome protocol-mismatch --title "No reason" --converged false \
  --summary "Mismatch claimed without naming it." >/dev/null 2>&1
check "Z: mismatch requires a reason" "0" "$([[ -f "$Z_RESULT" ]] && echo 1 || echo 0)"
printf 'tracked\n' > "$Z/tracked.txt"
git -C "$Z" add tracked.txt
git -C "$Z" -c user.name=Test -c user.email=test@example.com commit -qm tracked
printf 'changed\n' >> "$Z/tracked.txt"
bash "$LIB" write-terminal --result-root "$Z" --cycle-type micro --status escalated \
  --outcome protocol-mismatch --title "Dirty tree" --converged false \
  --reason "claimed after editing" \
  --summary "Mismatch claimed after changing the repository." >/dev/null 2>&1
check "Z: mismatch refuses a modified tracked tree" "0" "$([[ -f "$Z_RESULT" ]] && echo 1 || echo 0)"
git -C "$Z" checkout -q -- tracked.txt
printf 'untracked\n' > "$Z/scratch.txt"
bash "$LIB" write-terminal --result-root "$Z" --cycle-type micro --status escalated \
  --outcome protocol-mismatch --title "Scratch file" --converged false \
  --reason "the request is a question, not a code-change task" \
  --summary "An unrelated untracked file must not block the record." >/dev/null 2>&1
check "Z: mismatch ignores untracked paths" "1" "$([[ -f "$Z_RESULT" ]] && echo 1 || echo 0)"

# An abandoned reduced route reconciles as its own cycle type, not as a full cycle.
rm -f "$Z_RESULT"
bash "$LIB" begin --result-root "$Z" --cycle-type debug --title "Abandoned debug route" \
  --phase routing --autonomous true
bash "$REPO_ROOT/lib/cycle-reconcile.sh" --result-root "$Z" \
  --reason "routed skill ended without emitting a terminal result" >/dev/null
check "Z: reconciled route keeps its cycle type" "debug:failed:interrupted" \
  "$(jq -r '.cycleType + ":" + .status + ":" + .outcome' "$Z_RESULT")"

# Empty ITERATE summary must still publish a delivered run.
printf '%s\n' "$FIXTURE_FJ" > "$FEAT_DIR/feature.json"
rm -f "$FEAT_DIR/result.json" "$LOOP_DIR/last-result.json" "$FEAT_DIR/delivery.json"
bash "$LIB" write "$FEAT_DIR" --status completed --summary "" >/dev/null 2>&1
check "AA: blank summary falls back on delivered completion" \
  "Cycle completed; PR delivered." "$(jq -r '.summary' "$FEAT_DIR/result.json")"

printf '%s\n' "$(jq '.iterate.lastVerdict.summary = "Iterate said so."' "$FEAT_DIR/feature.json")" \
  > "$FEAT_DIR/feature.json"
rm -f "$FEAT_DIR/result.json"
bash "$LIB" write "$FEAT_DIR" --status completed --summary "" >/dev/null 2>&1
check "AA2: iterate verdict wins over the delivery fallback" \
  "Iterate said so." "$(jq -r '.summary' "$FEAT_DIR/result.json")"

printf '%s\n' "$(jq 'del(.delivery)' <<<"$FIXTURE_FJ")" > "$FEAT_DIR/feature.json"
rm -f "$FEAT_DIR/result.json" "$FEAT_DIR/delivery.json"
bash "$LIB" write "$FEAT_DIR" --status completed --summary "" >/dev/null 2>&1
check "AA3: blank summary without delivery still refuses" "0" \
  "$([[ -f "$FEAT_DIR/result.json" ]] && echo 1 || echo 0)"

# Classification on the armed run survives a later begin that omitted it.
CLASS_JSON='{"route":"full","taskKind":"maintenance","confidence":0.9,"estimatedFiles":2,"reviewableEstimatedFiles":2,"criteriaCount":2,"ambiguity":"low","introducesSeam":false,"introducesDependency":false,"introducesNewDependency":false,"updatesDependencyVersion":false,"changesInterface":false,"securitySensitive":false,"dataMigration":false,"multiRepo":false,"destructive":false,"reason":"sync PR"}'
CLASS_ROOT="$WORK/class-root"
mkdir -p "$CLASS_ROOT"
bash "$LIB" begin --result-root "$CLASS_ROOT" --cycle-type full \
  --title "Sync PR #114" --phase routing --autonomous true \
  --classification "$CLASS_JSON"
check "AB: begin stores the classification object" "maintenance" \
  "$(jq -r '.classification.taskKind' "$CLASS_ROOT/.loop-spec/active-run.json")"
bash "$LIB" begin --result-root "$CLASS_ROOT" --cycle-type full \
  --title "Sync PR #114" --slug sync-pr-114 --branch feat/sync --base-branch main \
  --phase startup --autonomous true
check "AB2: begin without --classification preserves the armed object" "maintenance" \
  "$(jq -r '.classification.taskKind' "$CLASS_ROOT/.loop-spec/active-run.json")"
check "AB2: preserved classification still selects maintenance" "maintenance" \
  "$(jq -c '.classification' "$CLASS_ROOT/.loop-spec/active-run.json" \
     | bash "$REPO_ROOT/lib/cycle-profile.sh" select - | sed -E 's/^profile=([a-z]+).*/\1/')"
bash "$LIB" begin --result-root "$CLASS_ROOT" --cycle-type full \
  --title "Sync PR #114" --phase startup --classification 'not-json'
check "AB3: invalid --classification does not wipe the stored object" "maintenance" \
  "$(jq -r '.classification.taskKind' "$CLASS_ROOT/.loop-spec/active-run.json")"
NULL_ROOT="$WORK/null-class-root"
mkdir -p "$NULL_ROOT"
bash "$LIB" begin --result-root "$NULL_ROOT" --cycle-type full \
  --title "No classification" --phase routing
check "AB4: begin without a classification stores JSON null" "null" \
  "$(jq -c '.classification' "$NULL_ROOT/.loop-spec/active-run.json")"

# Compact routing leaves `autonomousClassification` and its per-gate plan in
# feature state. Terminal telemetry exposes that classifier decision as
# `classification`, preserving the active-run/public result spelling.
COMPACT_GATE_PLAN="$(jq -nc '{
  specInterview: {run: false, reason: "bounded requirements are grounded"},
  discuss: {run: false, reason: "no unresolved product decision"},
  specCritique: {run: false, reason: "scope is deliberately bounded"},
  planCritique: {run: true, reason: "review the compact plan"},
  repositoryValidation: {run: true, reason: "validate repository state"},
  placeholderScan: {run: true, reason: "scan artifacts for placeholders"},
  tamperScan: {run: true, reason: "verify compact run artifacts"},
  acceptance: {run: true, reason: "run acceptance evidence"},
  codeReview: {run: true, reason: "review implementation"},
  iterate: {run: true, reason: "judge the final result"}
}')"
COMPACT_RESULT_FJ="$(jq --argjson gatePlan "$COMPACT_GATE_PLAN" '
  .autonomous = true |
  .autonomousClassification = {route:"compact",taskKind:"feature",confidence:0.94} |
  .gatePlan = $gatePlan
' <<<"$FIXTURE_FJ")"
printf '%s\n' "$COMPACT_RESULT_FJ" > "$FEAT_DIR/feature.json"
bash "$LIB" write "$FEAT_DIR" --status completed \
  --summary "The compact route was delivered and verified." >/dev/null 2>&1
check "AB5: result preserves compact classification" "compact" \
  "$(jq -r '.classification.route' "$FEAT_DIR/result.json")"
check "AB5: result preserves compact gate plan" "false" \
  "$(jq -r '.gatePlan.specInterview.run' "$FEAT_DIR/result.json")"

# Reduced routes have no feature directory. Their terminal writer must retain
# the classifier record armed at routing time before it consumes that record.
COMPACT_TERMINAL_ROOT="$WORK/compact-terminal-root"
COMPACT_TERMINAL_CLASS="$(jq -nc --argjson gatePlan "$COMPACT_GATE_PLAN" \
  '{route:"compact",taskKind:"refactor",gatePlan:$gatePlan}')"
mkdir -p "$COMPACT_TERMINAL_ROOT"
bash "$LIB" begin --result-root "$COMPACT_TERMINAL_ROOT" --cycle-type micro \
  --title "Compact refactor" --phase routing --autonomous true \
  --classification "$COMPACT_TERMINAL_CLASS"
bash "$LIB" write-terminal --result-root "$COMPACT_TERMINAL_ROOT" --cycle-type micro \
  --status failed --outcome verification-failed --title "Compact refactor" \
  --converged false --verification-status failed \
  --summary "The compact route failed verification." >/dev/null 2>&1
check "AB6: terminal result preserves armed compact classification" "compact" \
  "$(jq -r '.classification.route' "$COMPACT_TERMINAL_ROOT/.loop-spec/last-result.json")"
check "AB6: terminal result preserves armed compact gate plan" "true" \
  "$(jq -r '.gatePlan.acceptance.run' "$COMPACT_TERMINAL_ROOT/.loop-spec/last-result.json")"

# Case AC: a SHA-bound green draft is first-class, not completed-with-gaps.
printf '%s\n' "$(jq '.currentPhase = "deliver" | .delivery = {status:"pending",targets:[]}
  | .warnings = []' <<<"$FIXTURE_FJ")" > "$FEAT_DIR/feature.json"
jq -n '{schema:1,ok:true,status:"delivered-draft",nextPhase:"completed",
  prUrl:"https://github.com/sidecar/pr/22",attemptedAt:"2026-01-01T01:00:00Z",
  finishedAt:"2026-01-01T01:05:00Z",
  targets:[{name:"my-feature",ok:true,outcome:"delivered-draft",
    prUrl:"https://github.com/sidecar/pr/22",targetSha:"abc",
    checks:{status:"passed"}}]}' > "$FEAT_DIR/delivery.json"
LOOP_SPEC_DELIVERY_RECONCILE=0 bash "$LIB" write "$FEAT_DIR" --status completed \
  --summary "Opened a draft PR for human sign-off." >/dev/null 2>&1
check "AC: draft outcome" "delivered-draft" "$(jq -r '.outcome' "$FEAT_DIR/result.json")"
check "AC: draft not converged" "false" "$(jq '.converged' "$FEAT_DIR/result.json")"
check "AC: draft workDelivered" "true" "$(jq '.workDelivered' "$FEAT_DIR/result.json")"
check "AC: draft phaseReached completed" "completed" "$(jq -r '.phaseReached' "$FEAT_DIR/result.json")"
check "AC: draft status completed" "completed" "$(jq -r '.status' "$FEAT_DIR/result.json")"

# Iterate-budget warnings keep a ready PR in the gaps bucket, but work still shipped.
printf '%s\n' "$(jq '.warnings = ["iterate-budget-spent: leftover"]' "$FEAT_DIR/feature.json")" \
  > "$FEAT_DIR/feature.json"
jq -n '{schema:1,ok:true,status:"ready-for-review",nextPhase:"completed",
  prUrl:"https://github.com/sidecar/pr/23",
  targets:[{name:"my-feature",ok:true,outcome:"delivered",
    prUrl:"https://github.com/sidecar/pr/23"}]}' > "$FEAT_DIR/delivery.json"
LOOP_SPEC_DELIVERY_RECONCILE=0 bash "$LIB" write "$FEAT_DIR" --status completed \
  --summary "Completed with leftover iteration gaps." >/dev/null 2>&1
check "AC2: ready PR with iterate gaps stays completed-with-gaps" \
  "completed-with-gaps" "$(jq -r '.outcome' "$FEAT_DIR/result.json")"
check "AC2: gaps do not hide shipped work" "true" "$(jq '.workDelivered' "$FEAT_DIR/result.json")"

# Schema-7 pending delivery + a gh PR URL and no sidecar is a gap until reconcile runs.
printf '%s\n' "$(jq '.currentPhase = "deliver" | .delivery = {status:"pending",targets:[]}
  | .warnings = [] | .prUrl = "https://github.com/bypass/pr/9"' \
  <<<"$FIXTURE_FJ")" > "$FEAT_DIR/feature.json"
rm -f "$FEAT_DIR/delivery.json"
LOOP_SPEC_DELIVERY_RECONCILE=0 bash "$LIB" write "$FEAT_DIR" --status completed \
  --summary "Agent opened a PR without deliver.sh." >/dev/null 2>&1
check "AC3: bypass without sidecar is completed-with-gaps" \
  "completed-with-gaps" "$(jq -r '.outcome' "$FEAT_DIR/result.json")"
check "AC3: bypass PR still counts as workDelivered" "true" \
  "$(jq '.workDelivered' "$FEAT_DIR/result.json")"

# Case AD: write --status completed fail-open-reconciles a gh-created PR into a sidecar.
RECON_ROOT="$WORK/recon-write"
RECON_FEAT="$RECON_ROOT/.loop-spec/features/recon-feat"
mkdir -p "$RECON_FEAT" "$WORK/shims"
git -C "$RECON_ROOT" init -q
git -C "$RECON_ROOT" config user.email t@t
git -C "$RECON_ROOT" config user.name t
git -C "$RECON_ROOT" commit --allow-empty -qm init
printf '%s\n' "$(jq '.slug = "recon-feat" | .branch = "feat/recon"
  | .currentPhase = "deliver" | .delivery = {status:"pending",targets:[]}
  | .prUrl = "https://github.com/test/repo/pull/40" | .warnings = []' \
  <<<"$FIXTURE_FJ")" > "$RECON_FEAT/feature.json"
cat > "$WORK/shims/pr-delivery" <<'SHIM'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "${FAKE_OBSERVE_LOG:?}"
outcome="${FAKE_OBSERVE_OUTCOME:-delivered-draft}"
url="${FAKE_OBSERVE_PR_URL:-https://github.com/test/repo/pull/40}"
code="${FAKE_OBSERVE_ERROR:-}"
ok=true
[[ -z "$code" ]] || ok=false
jq -cn --argjson ok "$ok" --arg outcome "$outcome" --arg url "$url" --arg code "$code" \
  '{schema:1,ok:$ok,mode:"observe",outcome:$outcome,prUrl:$url,prNumber:40,
    isDraft:($outcome == "delivered-draft"),targetSha:"abc",remoteSha:"abc",headSha:"abc",
    checks:{status:"passed",required:[]},errorCode:(if $code == "" then null else $code end),
    error:null}'
[[ -z "$code" ]] || exit 1
exit 0
SHIM
chmod +x "$WORK/shims/pr-delivery"
: > "$WORK/observe.log"
FAKE_OBSERVE_LOG="$WORK/observe.log" LOOP_SPEC_PR_DELIVERY_BIN="$WORK/shims/pr-delivery" \
  bash "$LIB" write "$RECON_FEAT" --status completed \
  --summary "Reconciled a gh-created draft." >/dev/null 2>&1
check "AD: reconcile writes delivery.json" "delivered-draft" \
  "$(jq -r '.status' "$RECON_FEAT/delivery.json")"
check "AD: result outcome delivered-draft" "delivered-draft" \
  "$(jq -r '.outcome' "$RECON_FEAT/result.json")"
check "AD: result workDelivered" "true" "$(jq '.workDelivered' "$RECON_FEAT/result.json")"
check "AD: result not converged" "false" "$(jq '.converged' "$RECON_FEAT/result.json")"
check "AD: observe invoked" "1" "$(grep -c '^observe ' "$WORK/observe.log" || true)"

# Fail-open: a broken observer cannot block publishing the terminal result.
rm -f "$RECON_FEAT/delivery.json" "$RECON_FEAT/result.json"
cat > "$WORK/shims/pr-delivery" <<'SHIM'
#!/usr/bin/env bash
echo 'not-json'
exit 1
SHIM
chmod +x "$WORK/shims/pr-delivery"
FAKE_OBSERVE_LOG="$WORK/observe.log" LOOP_SPEC_PR_DELIVERY_BIN="$WORK/shims/pr-delivery" \
  bash "$LIB" write "$RECON_FEAT" --status completed \
  --summary "Observer crashed; still publish." >/dev/null 2>&1
check "AD2: fail-open still publishes" "completed" \
  "$(jq -r '.status' "$RECON_FEAT/result.json")"
check "AD2: fail-open writes no sidecar" "0" \
  "$([[ -f "$RECON_FEAT/delivery.json" ]] && echo 1 || echo 0)"

# AE: the terminal result reaches the event sink as event "result"
mkdir -p "$WORK/sink"
printf '#!/usr/bin/env bash\ncat >> "%s/sink/received.jsonl"\n' "$WORK" > "$WORK/sink/sink.sh"
chmod +x "$WORK/sink/sink.sh"
LOOP_SPEC_EVENT_SINK="$WORK/sink/sink.sh" bash "$LIB" write "$FEAT_DIR" --status completed \
  --summary "Sink check." >/dev/null 2>&1
check "AE: sink received a result event" "result" "$(tail -1 "$WORK/sink/received.jsonl" | jq -r '.event')"
check "AE: result event carries the slug" "my-feature" "$(tail -1 "$WORK/sink/received.jsonl" | jq -r '.slug')"
check "AE: result event data is the terminal result" "completed" "$(tail -1 "$WORK/sink/received.jsonl" | jq -r '.data.status')"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
