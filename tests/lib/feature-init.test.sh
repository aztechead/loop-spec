#!/usr/bin/env bash
# Tests for lib/feature-init.sh -- the single source of truth for the schema-7
# feature.json skeleton + canonical models map. Also exercises the cycle Step 5.9
# normalize merge against this same source: this is the path that previously dropped
# iterateJudge, so it is asserted explicitly here (regression guard for finding #5).
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
  --worktree .claude/worktrees/demo --test "npm test" --lint "" --typecheck "tsc")"
check "single is valid JSON" "$(echo "$single" | jq -e . >/dev/null 2>&1 && echo 1 || echo 0)"
check "single schemaVersion==7" "$(echo "$single" | jq -e '.schemaVersion == 7' >/dev/null 2>&1 && echo 1 || echo 0)"
check "single carries iterateJudge" "$(echo "$single" | jq -e '.models.iterateJudge == "opus"' >/dev/null 2>&1 && echo 1 || echo 0)"
check "single worktreePath set" "$(echo "$single" | jq -e '.worktreePath == ".claude/worktrees/demo"' >/dev/null 2>&1 && echo 1 || echo 0)"
check "single workspace null" "$(echo "$single" | jq -e '.workspace == null' >/dev/null 2>&1 && echo 1 || echo 0)"
check "single tier field ABSENT (hard cutover)" "$(echo "$single" | jq -e 'has("tier") | not' >/dev/null 2>&1 && echo 1 || echo 0)"
check "single iterate.maxIterations==10" "$(echo "$single" | jq -e '.iterate.maxIterations == 10' >/dev/null 2>&1 && echo 1 || echo 0)"
check "single retryBudget ABSENT (full bore)" "$(echo "$single" | jq -e 'has("retryBudget") | not' >/dev/null 2>&1 && echo 1 || echo 0)"
check "single commands.test set" "$(echo "$single" | jq -e '.commands.test == "npm test"' >/dev/null 2>&1 && echo 1 || echo 0)"
check "single currentPhase==spec" "$(echo "$single" | jq -e '.currentPhase == "spec"' >/dev/null 2>&1 && echo 1 || echo 0)"
check "single currentPhaseStartedAt null" "$(echo "$single" | jq -e '.currentPhaseStartedAt == null' >/dev/null 2>&1 && echo 1 || echo 0)"
check "single iterate.confirmationUsed false" "$(echo "$single" | jq -e '.iterate.confirmationUsed == false' >/dev/null 2>&1 && echo 1 || echo 0)"
check "single feature_title persisted verbatim" "$(echo "$single" | jq -e '.feature_title == "add CSV export with progress bar"' >/dev/null 2>&1 && echo 1 || echo 0)"

# --- no-title fallback + legacy flag rejection ---
plain="$(bash "$LIB" skeleton --mode single --slug q --now N --style auto --branch feat/q --base-sha a --base-branch main --worktree wt)"
check "missing --title falls back to slug" "$(echo "$plain" | jq -e '.feature_title == "q"' >/dev/null 2>&1 && echo 1 || echo 0)"
bash "$LIB" skeleton --mode single --slug x --now N --tier quick --style auto >/dev/null 2>&1
check "legacy --tier flag is rejected (hard cutover)" "$([[ $? -ne 0 ]] && echo 1 || echo 0)"

# --- skeleton workspace ---
ws="$(bash "$LIB" skeleton --mode workspace --slug demo --now N --style auto \
  --ws-root /ws --repos '[{"name":"fe","path":"fe","branch":"feat/demo","baseSha":"x","baseBranch":"main","commands":{"test":"t","lint":"","typecheck":""}}]')"
check "workspace is valid JSON" "$(echo "$ws" | jq -e . >/dev/null 2>&1 && echo 1 || echo 0)"
check "workspace branch null" "$(echo "$ws" | jq -e '.branch == null' >/dev/null 2>&1 && echo 1 || echo 0)"
check "workspace worktreePath null" "$(echo "$ws" | jq -e '.worktreePath == null' >/dev/null 2>&1 && echo 1 || echo 0)"
check "workspace root set" "$(echo "$ws" | jq -e '.workspace.root == "/ws"' >/dev/null 2>&1 && echo 1 || echo 0)"
check "workspace repo passed through" "$(echo "$ws" | jq -e '.workspace.repos[0].name == "fe"' >/dev/null 2>&1 && echo 1 || echo 0)"
check "workspace top commands empty" "$(echo "$ws" | jq -e '.commands.test == ""' >/dev/null 2>&1 && echo 1 || echo 0)"
check "workspace carries iterateJudge" "$(echo "$ws" | jq -e '.models.iterateJudge == "opus"' >/dev/null 2>&1 && echo 1 || echo 0)"

# --- feature_title backfill (cycle Step 5.9) ---
# Pre-2.4.0 feature.json lacks feature_title; the resume path backfills it from slug
# and never overwrites an existing value.
old='{"slug":"legacy-slug"}'
backfilled="$(echo "$old" | jq 'if (.feature_title // "") == "" then .feature_title = .slug else . end')"
check "backfill sets feature_title from slug" "$(echo "$backfilled" | jq -e '.feature_title == "legacy-slug"' >/dev/null 2>&1 && echo 1 || echo 0)"
keep='{"slug":"s","feature_title":"the real goal"}'
kept="$(echo "$keep" | jq 'if (.feature_title // "") == "" then .feature_title = .slug else . end')"
check "backfill never overwrites existing title" "$(echo "$kept" | jq -e '.feature_title == "the real goal"' >/dev/null 2>&1 && echo 1 || echo 0)"

# --- Step 5.9 normalize regression (finding #5) ---
# A stale feature.json whose models map LACKS iterateJudge and carries an extra role +
# a vestigial preset field. The Step 5.9 merge must (a) restore iterateJudge, (b) keep
# the extra role, (c) force canonical IDs, (d) drop preset.
canonical="$(bash "$LIB" models)"
stale='{"models":{"implementer":"old-model","extraRole":"keep"},"preset":"balanced","slug":"x"}'
normalized="$(echo "$stale" | jq --argjson m "$canonical" '.models = ((.models // {}) * $m) | del(.preset)')"
check "normalize restores iterateJudge" "$(echo "$normalized" | jq -e '.models.iterateJudge == "opus"' >/dev/null 2>&1 && echo 1 || echo 0)"
check "normalize forces canonical implementer" "$(echo "$normalized" | jq -e '.models.implementer == "sonnet"' >/dev/null 2>&1 && echo 1 || echo 0)"
check "normalize preserves extra role" "$(echo "$normalized" | jq -e '.models.extraRole == "keep"' >/dev/null 2>&1 && echo 1 || echo 0)"
check "normalize drops preset" "$(echo "$normalized" | jq -e 'has("preset") == false' >/dev/null 2>&1 && echo 1 || echo 0)"

# --- invalid invocation ---
bash "$LIB" skeleton --mode bogus --slug x --now N --style auto >/dev/null 2>&1
check "bad mode exits non-zero" "$([[ $? -ne 0 ]] && echo 1 || echo 0)"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
