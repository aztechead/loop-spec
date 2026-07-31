#!/usr/bin/env bash
# Tests for lib/feature-init.sh -- the single source of truth for the schema-7
# feature.json skeleton + phase-aware models map. Also exercises the activation
# merge used at each phase boundary.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO_ROOT/lib/feature-init.sh"
PASS=0
FAIL=0

check() {
  local name="$1" cond="$2"
  if [[ "$cond" == "1" ]]; then PASS=$((PASS+1)); echo "PASS: $name"
  else FAIL=$((FAIL+1)); echo "FAIL: $name"; fi
}

# --- models subcommand ---
models="$(bash "$LIB" models)"
check "models is valid JSON" "$(echo "$models" | jq -e . >/dev/null 2>&1 && echo 1 || echo 0)"
check "models includes iterateJudge=opus" "$(echo "$models" | jq -e '.iterateJudge == "opus"' >/dev/null 2>&1 && echo 1 || echo 0)"
check "models includes codeReviewer=opus" "$(echo "$models" | jq -e '.codeReviewer == "opus"' >/dev/null 2>&1 && echo 1 || echo 0)"
check "models includes implementer=sonnet" "$(echo "$models" | jq -e '.implementer == "sonnet"' >/dev/null 2>&1 && echo 1 || echo 0)"

# --- skeleton single ---
single="$(bash "$LIB" skeleton --mode single --slug demo --now 2026-06-29T00:00:00Z \
  --style auto --title "add CSV export with progress bar" \
  --branch feat/demo --base-sha abc --base-branch main \
  --worktree .claude/worktrees/demo \
  --prepare "npm ci" --test "npm test" --lint "" --typecheck "tsc")"
check "single is valid JSON" "$(echo "$single" | jq -e . >/dev/null 2>&1 && echo 1 || echo 0)"
check "single schemaVersion==7" "$(echo "$single" | jq -e '.schemaVersion == 7' >/dev/null 2>&1 && echo 1 || echo 0)"
check "single carries iterateJudge" "$(echo "$single" | jq -e '.models.iterateJudge == "opus"' >/dev/null 2>&1 && echo 1 || echo 0)"
check "single worktreePath set" "$(echo "$single" | jq -e '.worktreePath == ".claude/worktrees/demo"' >/dev/null 2>&1 && echo 1 || echo 0)"
check "single execution root is worktree" "$(echo "$single" | jq -e '.executionRootMode == "worktree"' >/dev/null 2>&1 && echo 1 || echo 0)"
check "single workspace null" "$(echo "$single" | jq -e '.workspace == null' >/dev/null 2>&1 && echo 1 || echo 0)"
check "single tier field ABSENT (hard cutover)" "$(echo "$single" | jq -e 'has("tier") | not' >/dev/null 2>&1 && echo 1 || echo 0)"
check "single iterate.maxIterations==10" "$(echo "$single" | jq -e '.iterate.maxIterations == 10' >/dev/null 2>&1 && echo 1 || echo 0)"
check "single retryBudget ABSENT (full bore)" "$(echo "$single" | jq -e 'has("retryBudget") | not' >/dev/null 2>&1 && echo 1 || echo 0)"
check "single commands.test set" "$(echo "$single" | jq -e '.commands.test == "npm test"' >/dev/null 2>&1 && echo 1 || echo 0)"
check "single commands.prepare set" "$(echo "$single" | jq -e '.commands.prepare == "npm ci"' >/dev/null 2>&1 && echo 1 || echo 0)"
check "single verification baseline starts null" "$(echo "$single" | jq -e '.verificationBaseline == null' >/dev/null 2>&1 && echo 1 || echo 0)"
check "single currentPhase==spec" "$(echo "$single" | jq -e '.currentPhase == "spec"' >/dev/null 2>&1 && echo 1 || echo 0)"
check "single has all seven phase model slots" "$(echo "$single" | jq -e '(.phaseModels | keys | sort) == ["deliver","discuss","execute","iterate","plan","spec","verify"]' >/dev/null 2>&1 && echo 1 || echo 0)"
check "single phase model slots default null" "$(echo "$single" | jq -e '[.phaseModels[]] | all(. == null)' >/dev/null 2>&1 && echo 1 || echo 0)"
check "single currentPhaseStartedAt null" "$(echo "$single" | jq -e '.currentPhaseStartedAt == null' >/dev/null 2>&1 && echo 1 || echo 0)"
check "single phase handoff starts disabled" "$(echo "$single" | jq -e '.phaseHandoff == false' >/dev/null 2>&1 && echo 1 || echo 0)"
check "single iterate.confirmationUsed false" "$(echo "$single" | jq -e '.iterate.confirmationUsed == false' >/dev/null 2>&1 && echo 1 || echo 0)"
check "single feature_title persisted verbatim" "$(echo "$single" | jq -e '.feature_title == "add CSV export with progress bar"' >/dev/null 2>&1 && echo 1 || echo 0)"
check "single PR fields start null" "$(echo "$single" | jq -e '.prUrl == null and .checkpointPrUrl == null' >/dev/null 2>&1 && echo 1 || echo 0)"
check "single delivery starts pending" "$(echo "$single" | jq -e '.delivery.status == "pending" and .delivery.nextPhase == null and .delivery.ciRemediationAttempts == 0 and .delivery.ciRemediationLimit == 2 and (.delivery.targets | length) == 0' >/dev/null 2>&1 && echo 1 || echo 0)"

# --- no-title fallback + legacy flag rejection ---
plain="$(bash "$LIB" skeleton --mode single --slug q --now N --style auto --branch feat/q --base-sha a --base-branch main --worktree wt)"
check "missing --title falls back to slug" "$(echo "$plain" | jq -e '.feature_title == "q"' >/dev/null 2>&1 && echo 1 || echo 0)"
in_place="$(bash "$LIB" skeleton --mode single --slug oc --now N --style auto \
  --branch feat/oc --base-sha a --base-branch main --worktree "")"
check "empty worktree selects in-place root" "$(echo "$in_place" | jq -e '.worktreePath == null and .executionRootMode == "in-place"' >/dev/null 2>&1 && echo 1 || echo 0)"
bash "$LIB" skeleton --mode single --slug x --now N --tier quick --style auto >/dev/null 2>&1
check "legacy --tier flag is rejected (hard cutover)" "$([[ $? -ne 0 ]] && echo 1 || echo 0)"

# --- skeleton workspace ---
ws="$(bash "$LIB" skeleton --mode workspace --slug demo --now N --style auto \
  --ws-root /ws --repos '[{"name":"fe","path":"fe","branch":"feat/demo","baseSha":"x","baseBranch":"main","commands":{"test":"t","lint":"","typecheck":""}}]')"
check "workspace is valid JSON" "$(echo "$ws" | jq -e . >/dev/null 2>&1 && echo 1 || echo 0)"
check "workspace branch null" "$(echo "$ws" | jq -e '.branch == null' >/dev/null 2>&1 && echo 1 || echo 0)"
check "workspace worktreePath null" "$(echo "$ws" | jq -e '.worktreePath == null' >/dev/null 2>&1 && echo 1 || echo 0)"
check "workspace execution root mode" "$(echo "$ws" | jq -e '.executionRootMode == "workspace"' >/dev/null 2>&1 && echo 1 || echo 0)"
check "workspace root set" "$(echo "$ws" | jq -e '.workspace.root == "/ws"' >/dev/null 2>&1 && echo 1 || echo 0)"
check "workspace repo passed through" "$(echo "$ws" | jq -e '.workspace.repos[0].name == "fe"' >/dev/null 2>&1 && echo 1 || echo 0)"
check "workspace repo commands normalize prepare" "$(echo "$ws" | jq -e '.workspace.repos[0].commands.prepare == ""' >/dev/null 2>&1 && echo 1 || echo 0)"
check "workspace repo baseline starts null" "$(echo "$ws" | jq -e '.workspace.repos[0].verificationBaseline == null' >/dev/null 2>&1 && echo 1 || echo 0)"
check "workspace top commands empty" "$(echo "$ws" | jq -e '.commands.test == ""' >/dev/null 2>&1 && echo 1 || echo 0)"
check "workspace top prepare empty" "$(echo "$ws" | jq -e '.commands.prepare == ""' >/dev/null 2>&1 && echo 1 || echo 0)"
check "workspace verification baseline starts empty" "$(echo "$ws" | jq -e '.verificationBaseline == null' >/dev/null 2>&1 && echo 1 || echo 0)"
check "workspace carries iterateJudge" "$(echo "$ws" | jq -e '.models.iterateJudge == "opus"' >/dev/null 2>&1 && echo 1 || echo 0)"
check "workspace delivery starts pending" "$(echo "$ws" | jq -e '.delivery.status == "pending" and .delivery.ciRemediationAttempts == 0 and .delivery.ciRemediationLimit == 2 and (.delivery.targets | length) == 0' >/dev/null 2>&1 && echo 1 || echo 0)"

# --- feature_title backfill (cycle Step 5.9) ---
# Pre-2.4.0 feature.json lacks feature_title; the resume path backfills it from slug
# and never overwrites an existing value.
old='{"slug":"legacy-slug"}'
backfilled="$(echo "$old" | jq 'if (.feature_title // "") == "" then .feature_title = .slug else . end')"
check "backfill sets feature_title from slug" "$(echo "$backfilled" | jq -e '.feature_title == "legacy-slug"' >/dev/null 2>&1 && echo 1 || echo 0)"
keep='{"slug":"s","feature_title":"the real goal"}'
kept="$(echo "$keep" | jq 'if (.feature_title // "") == "" then .feature_title = .slug else . end')"
check "backfill never overwrites existing title" "$(echo "$kept" | jq -e '.feature_title == "the real goal"' >/dev/null 2>&1 && echo 1 || echo 0)"

# --- phase activation regression ---
activate_root="$(mktemp -d)"
mkdir -p "$activate_root/feature"
printf '%s\n' \
  '{"models":{"implementer":"old-model","extraRole":"keep"},"preset":"balanced","slug":"x"}' \
  > "$activate_root/feature/feature.json"
LOOP_SPEC_PHASE_MODEL_EXECUTE=opus \
  bash "$LIB" activate "$activate_root/feature" execute
normalized="$(cat "$activate_root/feature/feature.json")"
check "normalize restores iterateJudge" "$(echo "$normalized" | jq -e '.models.iterateJudge == "opus"' >/dev/null 2>&1 && echo 1 || echo 0)"
check "normalize applies phase model to implementer" "$(echo "$normalized" | jq -e '.models.implementer == "opus"' >/dev/null 2>&1 && echo 1 || echo 0)"
check "normalize preserves extra role" "$(echo "$normalized" | jq -e '.models.extraRole == "keep"' >/dev/null 2>&1 && echo 1 || echo 0)"
check "normalize persists phase map" "$(echo "$normalized" | jq -e '.phaseModels.execute == "opus"' >/dev/null 2>&1 && echo 1 || echo 0)"
rm -rf "$activate_root"

# --- invalid invocation ---
bash "$LIB" skeleton --mode bogus --slug x --now N --style auto >/dev/null 2>&1
check "bad mode exits non-zero" "$([[ $? -ne 0 ]] && echo 1 || echo 0)"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
