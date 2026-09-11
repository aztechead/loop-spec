#!/usr/bin/env bash
# Tests for task-008's final-candidate observer: `cycle-driver.sh verification run
# --final-candidate SHA|--final-candidates PATH` (lib/graph/driver.py) and the
# deliver.sh/delivery-reconcile.sh/cycle-result.sh gates that require its record for
# the exact target SHA before any PR adapter call or terminal completed result.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DRIVER="$ROOT/lib/cycle-driver.sh"
DELIVER="$ROOT/lib/deliver.sh"
RECONCILE="$ROOT/lib/delivery-reconcile.sh"
RESULT="$ROOT/lib/cycle-result.sh"
PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL + 1))
  fi
}

WORK="${TMPDIR:-/tmp}/loop-spec-final-candidate.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/shims"

# simplicity: the init_repo/shim shape below duplicates tests/lib/deliver.test.sh's
# own fixtures on purpose -- task-008's own instructions name that suite's shim
# pattern as the offline delivery adapter to reuse, and no shared test-fixture
# helper is in this task's file-ownership map to extract one into (the laziness
# ladder's YAGNI rung: don't add a file nothing else needs yet).
#
# The same offline delivery adapter shim tests/lib/deliver.test.sh uses: it never
# touches the network, just records every invocation and reports success unless
# told to fail, so "no adapter call" is provable by an empty log.
cat > "$WORK/shims/pr-delivery" <<'SHIM'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "${FAKE_DELIVERY_LOG:?}"
repo=""; branch=""; base=""; sha=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -C) repo="$2"; shift 2 ;;
    --branch) branch="$2"; shift 2 ;;
    --base) base="$2"; shift 2 ;;
    --sha) sha="$2"; shift 2 ;;
    --body-file) shift 2 ;;
    *) shift ;;
  esac
done
url="https://github.com/test/repo/pull/7"
jq -cn --arg repo "$repo" --arg branch "$branch" --arg base "$base" --arg sha "$sha" --arg url "$url" \
  '{schema:1,ok:true,mode:"final",outcome:"delivered",repo:$repo,branch:$branch,
    baseBranch:$base,targetSha:$sha,remoteSha:$sha,headSha:$sha,prNumber:7,prUrl:$url,
    prAction:"reused",metadataAction:"unchanged",readinessAction:"marked_ready",isDraft:false,
    checks:{status:"passed",required:[{name:"test",bucket:"pass"}]},
    observedAt:"2026-01-01T00:00:00Z",errorCode:null,error:null}'
SHIM
chmod +x "$WORK/shims/pr-delivery"

init_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email t@t
  git -C "$repo" config user.name t
  printf 'base\n' > "$repo/a"
  git -C "$repo" add a
  git -C "$repo" commit -q -m base
}

# init_feature REPO SLUG TESTCMD CRITERIONCMD: a schema-7 single-repo feature at
# currentPhase=deliver, one committed source file `b`, one GE-001 bound to
# CRITERIONCMD, and commands.test = TESTCMD. Prints the feature dir.
init_feature() {
  local repo="$1" slug="$2" testcmd="$3" critcmd="$4" base fdir docs
  base="$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" checkout -q -b "feat/$slug"
  fdir="$repo/.loop-spec/features/$slug"; docs="$repo/docs/loop-spec/features/$slug"
  mkdir -p "$fdir" "$docs"
  cat > "$repo/.gitignore" <<'EOF'
/.loop-spec/features/*/*
!/.loop-spec/features/*/feature.json
EOF
  printf -- '---\ncriteria:\n  GE-001: %s\n---\n# Spec\n\n### Good Enough\n- [ ] b exists.\n' "$(jq -cn --arg c "$critcmd" '$c')" > "$docs/SPEC.md"
  printf '# Verification\n' > "$docs/VERIFICATION.md"
  printf '# Iteration\nConverged.\n' > "$docs/ITERATION.md"
  printf 'feature\n' > "$repo/b"
  git -C "$repo" add b .gitignore "docs/loop-spec/features/$slug"
  git -C "$repo" commit -q -m feature
  jq -n --arg base "$base" --arg slug "$slug" --arg test "$testcmd" \
    --arg spec "docs/loop-spec/features/$slug/SPEC.md" \
    --arg verification "docs/loop-spec/features/$slug/VERIFICATION.md" \
    --arg iteration "docs/loop-spec/features/$slug/ITERATION.md" \
    '{schemaVersion:7,slug:$slug,feature_title:$slug,currentPhase:"deliver",
      branch:("feat/" + $slug),baseSha:$base,baseBranch:"main",workspace:null,
      prUrl:null,checkpointPrUrl:null,warnings:[],commands:{test:$test},
      artifacts:{spec:$spec,verification:$verification,iteration:$iteration},
      artifactPublication:{version:1,generation:0,evidenceEpoch:0,migration:null,participantsVersion:1},
      delivery:{status:"pending",attemptedAt:null,finishedAt:null,targets:[]}}' > "$fdir/feature.json"
  git -C "$repo" add ".loop-spec/features/$slug/feature.json"
  git -C "$repo" commit -q -m "final candidate"
  printf '%s' "$fdir"
}

# --- Scenario A: a real single-repo feature with one bound criterion and a real
# commands.test, delivered through deliver.sh with the real finalizer. -------------
REPO_A="$WORK/repo-a"
init_repo "$REPO_A"
FDIR_A="$(init_feature "$REPO_A" demo "true" "test -f b")"

LOG="$WORK/calls.log"; : > "$LOG"
ec=0
out="$(FAKE_DELIVERY_LOG="$LOG" LOOP_SPEC_PR_DELIVERY_BIN="$WORK/shims/pr-delivery" bash "$DELIVER" run "$FDIR_A")" || ec=$?
check "A: deliver succeeds" "0" "$ec"
check "A: adapter called once" "1" "$(wc -l < "$LOG" | tr -d ' ')"
A_SHA="$(git -C "$REPO_A" rev-parse HEAD)"
A_DIGEST_DIR="$(find "$FDIR_A/observations/final" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)"
# finalize-delivery-candidate.sh's own commit is opt-in per artifact (rules/ignore/
# telemetry) and this fixture needs none of it, so HEAD may legitimately be unchanged
# by finalization; the artifact-only-finalizer-commit case (a real HEAD move) is
# exercised deliberately below, in the sink scenario, where the sink store's own
# commit does change HEAD before the observer runs.
check "A: final projection written" "1" "$([[ -f "$A_DIGEST_DIR/record.json" && -f "$A_DIGEST_DIR/VERIFICATION.md" ]] && echo 1 || echo 0)"
check "A: final record ok" "true" "$(jq -r '.ok' "$A_DIGEST_DIR/record.json" 2>/dev/null)"
check "A: final record binds exact SHA" "$A_SHA" "$(jq -r '.shas.demo' "$A_DIGEST_DIR/record.json" 2>/dev/null)"
check "A: two executions recorded (criterion + commands.test)" "2" \
  "$(jq -r '.executions | length' "$A_DIGEST_DIR/record.json" 2>/dev/null)"

# Bound-resume: re-running deliver.sh for the same delivered candidate revalidates
# but creates no new tracked commit (PLAN "unchanged final B observations pass
# without creating another tracked commit").
COMMITS_BEFORE_RESUME="$(git -C "$REPO_A" rev-list --count HEAD)"
: > "$LOG"
ec=0
out="$(FAKE_DELIVERY_LOG="$LOG" LOOP_SPEC_PR_DELIVERY_BIN="$WORK/shims/pr-delivery" bash "$DELIVER" run "$FDIR_A")" || ec=$?
check "bound resume: delivers again" "0" "$ec"
check "bound resume: HEAD unchanged" "$A_SHA" "$(git -C "$REPO_A" rev-parse HEAD)"
check "bound resume: creates no new commit" "$COMMITS_BEFORE_RESUME" "$(git -C "$REPO_A" rev-list --count HEAD)"

# --- Scenario B: observations recorded directly against an earlier commit (as if a
# caller held onto its PASS) cannot authorize a later source commit; no adapter call
# happens until B's OWN fresh final-candidate checks pass. --------------------------
REPO_B="$WORK/repo-b"
init_repo "$REPO_B"
FDIR_B="$(init_feature "$REPO_B" stale "true" "test -f b")"
SHA_OLD="$(git -C "$REPO_B" rev-parse HEAD)"
old_out="$(bash "$DRIVER" verification run --final-candidate "$SHA_OLD" --feature-dir "$FDIR_B")"
check "B: observations recorded on the old commit" "true" "$(jq -r '.ok' <<<"$old_out")"
OLD_DIGEST="$(jq -r '.candidate' <<<"$old_out")"
OLD_EXECUTIONS="$(jq -r '.executions[]' <<<"$old_out" | sort)"

printf 'more\n' >> "$REPO_B/b"
git -C "$REPO_B" add b
git -C "$REPO_B" commit -q -m "source change past the recorded observations"

: > "$LOG"
ec=0
out="$(FAKE_DELIVERY_LOG="$LOG" LOOP_SPEC_PR_DELIVERY_BIN="$WORK/shims/pr-delivery" bash "$DELIVER" run "$FDIR_B")" || ec=$?
check "B: the source commit still delivers, on its own fresh evidence" "0" "$ec"
NEW_SHA="$(git -C "$REPO_B" rev-parse HEAD)"
check "B: adapter called with the new SHA, never the stale one" "1" "$(grep -c -- "--sha $NEW_SHA" "$LOG" || true)"
check "B: adapter never called with the stale recorded SHA" "0" "$(grep -c -- "--sha $SHA_OLD" "$LOG" || true)"
NEW_DIGEST_DIR="$FDIR_B/observations/final"
NEW_DIGEST="$(find "$NEW_DIGEST_DIR" -mindepth 1 -maxdepth 1 -type d | xargs -n1 basename | grep -v "^$OLD_DIGEST\$")"
check "B: a distinct candidate digest was written for the new SHA" "1" "$([[ -n "$NEW_DIGEST" ]] && echo 1 || echo 0)"
NEW_EXECUTIONS="$(jq -r '.executions[]' "$NEW_DIGEST_DIR/$NEW_DIGEST/record.json" 2>/dev/null | sort)"
check "B: the new candidate's executions are fresh, never the stale record's" "1" \
  "$([[ -n "$NEW_EXECUTIONS" && "$NEW_EXECUTIONS" != "$OLD_EXECUTIONS" ]] && echo 1 || echo 0)"

# --- Scenario C: a first-ever candidate whose bound criterion fails blocks
# delivery outright; the adapter is never called. -----------------------------------
REPO_C="$WORK/repo-c"
init_repo "$REPO_C"
FDIR_C="$(init_feature "$REPO_C" broken "true" "test -f does-not-exist")"
: > "$LOG"
ec=0
out="$(FAKE_DELIVERY_LOG="$LOG" LOOP_SPEC_PR_DELIVERY_BIN="$WORK/shims/pr-delivery" bash "$DELIVER" run "$FDIR_C")" || ec=$?
check "C: broken candidate exits non-zero" "1" "$ec"
check "C: adapter never called for the broken candidate" "0" "$(wc -l < "$LOG" | tr -d ' ')"
check "C: delivery sidecar records the block reason" "final_candidate_unverified" \
  "$(jq -r '.targets[0].errorCode' "$FDIR_C/delivery.json" 2>/dev/null)"
C_DIGEST_DIR="$(find "$FDIR_C/observations/final" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)"
check "C: the broken candidate's own record says not ok" "false" "$(jq -r '.ok' "$C_DIGEST_DIR/record.json" 2>/dev/null)"

# --- HEAD-mismatch refusal: the observer never checks anything out and never writes
# a record for a SHA that is not the root's current HEAD. --------------------------
ec=0
final_out="$(bash "$DRIVER" verification run --final-candidate "0000000000000000000000000000000000dead" --feature-dir "$FDIR_A" 2>&1)" || ec=$?
check "HEAD mismatch: refuses" "1" "$ec"
check "HEAD mismatch: names no checkout" "1" "$(grep -c 'no checkout performed' <<<"$final_out" || true)"
DIGEST_COUNT_BEFORE="$(find "$FDIR_A/observations/final" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
check "HEAD mismatch: writes no new final record" "$DIGEST_COUNT_BEFORE" \
  "$(find "$FDIR_A/observations/final" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"

# --- delivery-reconcile.sh requires the same checked binding for an out-of-band PR
# (a headless `gh pr create` that never ran through deliver.sh at all). -------------
REPO_R="$WORK/repo-r"
init_repo "$REPO_R"
FDIR_R="$(init_feature "$REPO_R" recon "false" "test -f b")"
RSHA="$(git -C "$REPO_R" rev-parse HEAD)"
cat > "$WORK/shims/pr-delivery-observe" <<SHIM2
#!/usr/bin/env bash
jq -cn --arg sha "$RSHA" '{schema:1,ok:true,outcome:"delivered",prUrl:"https://github.com/test/recon/pull/1",targetSha:\$sha}'
SHIM2
chmod +x "$WORK/shims/pr-delivery-observe"
ec=0
recon_out="$(LOOP_SPEC_PR_DELIVERY_BIN="$WORK/shims/pr-delivery-observe" bash "$RECONCILE" observe "$FDIR_R" 2>&1)" || ec=$?
check "reconcile: refuses an unverified out-of-band PR (commands.test fails)" "1" "$ec"
check "reconcile: writes no delivery.json" "0" "$([[ -e "$FDIR_R/delivery.json" ]] && echo 1 || echo 0)"

# --- cycle-result.sh write --status completed requires the same binding: a sidecar
# that claims readiness for a SHA whose commands.test now fails must not publish a
# completed terminal result (the OBSERVABILITY CONTRACT's fail-open: exit 0, no
# pointer). --------------------------------------------------------------------------
REPO_CR="$WORK/repo-cr"
init_repo "$REPO_CR"
FDIR_CR="$(init_feature "$REPO_CR" cr "false" "test -f b")"
CRSHA="$(git -C "$REPO_CR" rev-parse HEAD)"
jq --arg sha "$CRSHA" '.delivery = {status:"ready-for-review",nextPhase:"completed",
    targets:[{name:"cr",ok:true,targetSha:$sha,prUrl:"https://github.com/test/cr/pull/1"}]}' \
  "$FDIR_CR/feature.json" > "$FDIR_CR/feature.json.tmp"
mv "$FDIR_CR/feature.json.tmp" "$FDIR_CR/feature.json"
jq -n --arg sha "$CRSHA" '{schema:1,ok:true,status:"ready-for-review",nextPhase:"completed",
  prUrl:"https://github.com/test/cr/pull/1",targets:[{name:"cr",ok:true,targetSha:$sha,prUrl:"https://github.com/test/cr/pull/1"}]}' \
  > "$FDIR_CR/delivery.json"
ec=0
cr_out="$(LOOP_SPEC_DELIVERY_RECONCILE=0 bash "$RESULT" write "$FDIR_CR" --status completed --summary "done" 2>&1)" || ec=$?
check "cycle-result: fails open (exit 0) without a valid final record" "0" "$ec"
check "cycle-result: does not publish a completed pointer" "0" \
  "$([[ -f "$REPO_CR/.loop-spec/last-result.json" ]] && jq -e '.status == "completed"' "$REPO_CR/.loop-spec/last-result.json" >/dev/null 2>&1 && echo 1 || echo 0)"

# --- artifact-sink mode: the observer resolves preserved SPEC/PLAN from the sink
# manifest and binds their exact hashes once docs are gone from the working tree. --
REPO_S="$WORK/repo-sink"
init_repo "$REPO_S"
FDIR_S="$(init_feature "$REPO_S" sunk "true" "test -f b")"
DOCS_S="$REPO_S/docs/loop-spec/features/sunk"
printf '# Plan\n' > "$DOCS_S/PLAN.md"
git -C "$REPO_S" add "docs/loop-spec/features/sunk/PLAN.md"
git -C "$REPO_S" commit -q -m "add plan"
SINK_STORE="$WORK/sink-store"
ec=0
LOOP_SPEC_ARTIFACTS_IN_PR=0 LOOP_SPEC_ARTIFACT_DIR="$SINK_STORE" \
  bash "$ROOT/lib/artifact-sink.sh" store "$FDIR_S" "$REPO_S" >/dev/null || ec=$?
check "sink: store accepted" "0" "$ec"
git -C "$REPO_S" add -A
git -C "$REPO_S" commit -q -m "sink docs out of the branch" >/dev/null 2>&1 || true
SUNK_SHA="$(git -C "$REPO_S" rev-parse HEAD)"
ec=0
sink_out="$(LOOP_SPEC_ARTIFACT_DIR="$SINK_STORE" bash "$DRIVER" verification run --final-candidate "$SUNK_SHA" \
  --feature-dir "$FDIR_S" 2>&1)" || ec=$?
check "sink: observer resolves the preserved SPEC/PLAN and runs" "0" "$ec"
check "sink: authoritative hashes bound from the sink, not an absent tree file" "1" \
  "$(grep -c '^sink:' <<<"$(jq -r '.authoritativeHashes.source' <<<"$sink_out")" || true)"
check "sink: spec hash bound" "1" "$([[ "$(jq -r '.authoritativeHashes.spec' <<<"$sink_out")" != "null" ]] && echo 1 || echo 0)"
check "sink: plan hash bound" "1" "$([[ "$(jq -r '.authoritativeHashes.plan' <<<"$sink_out")" != "null" ]] && echo 1 || echo 0)"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
