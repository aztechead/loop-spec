#!/usr/bin/env bash
# Unit tests for lib/task-route.sh
set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/task-route.sh"
PASS=0
FAIL=0

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CLEAN_REPO="$TMP/clean"
DIRTY_REPO="$TMP/dirty"
NON_REPO="$TMP/not-a-repo"
CORRUPT_REPO="$TMP/corrupt"
mkdir -p "$CLEAN_REPO" "$DIRTY_REPO" "$NON_REPO" "$CORRUPT_REPO"
git -C "$CLEAN_REPO" init -q
git -C "$CLEAN_REPO" -c user.name=Test -c user.email=test@example.com commit --allow-empty -qm init
mkdir -p "$CLEAN_REPO/.loop-spec/decisions-staging"
touch "$CLEAN_REPO/.loop-spec/runtime.json" "$CLEAN_REPO/.loop-spec/decisions-staging/decision.jsonl"
git -C "$DIRTY_REPO" init -q
git -C "$DIRTY_REPO" -c user.name=Test -c user.email=test@example.com commit --allow-empty -qm init
touch "$DIRTY_REPO/uncommitted.txt"
git -C "$CORRUPT_REPO" init -q
git -C "$CORRUPT_REPO" -c user.name=Test -c user.email=test@example.com commit --allow-empty -qm init
printf 'corrupt-index' > "$CORRUPT_REPO/.git/index"
printf '{}\n' > "$CLEAN_REPO/.loop-spec/last-result.json"

pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }

candidate() {
  jq -nc \
    --arg route "${1:-micro}" \
    --arg task_kind "${2:-maintenance}" \
    --argjson confidence "${3:-0.9}" \
    --argjson estimated_files "${4:-2}" \
    --argjson criteria_count "${5:-2}" \
    --arg ambiguity "${6:-low}" \
    --argjson introduces_seam "${7:-false}" \
    --argjson introduces_dependency "${8:-false}" \
    --argjson changes_interface "${9:-false}" \
    --argjson security_sensitive "${10:-false}" \
    --argjson data_migration "${11:-false}" \
    --argjson multi_repo "${12:-false}" \
    --argjson destructive "${13:-false}" \
    '{route: $route, taskKind: $task_kind, confidence: $confidence,
      estimatedFiles: $estimated_files, criteriaCount: $criteria_count,
      ambiguity: $ambiguity, introducesSeam: $introduces_seam,
      introducesDependency: $introduces_dependency,
      changesInterface: $changes_interface, securitySensitive: $security_sensitive,
      dataMigration: $data_migration, multiRepo: $multi_repo,
      destructive: $destructive, reason: "test candidate"}'
}

compact_gate_plan() {
  jq -nc '{
    specInterview: {run: false, reason: "bounded change has grounded requirements"},
    discuss: {run: false, reason: "classifier found no unresolved product decision"},
    specCritique: {run: false, reason: "bounded scope makes a separate critique unnecessary"},
    planCritique: {run: true, reason: "review the compact execution plan"},
    repositoryValidation: {run: true, reason: "validate the target repository before change"},
    placeholderScan: {run: true, reason: "scan generated artifacts for placeholders"},
    tamperScan: {run: true, reason: "verify the compact run artifacts"},
    acceptance: {run: true, reason: "run the stated acceptance checks"},
    codeReview: {run: true, reason: "review the bounded implementation"},
    iterate: {run: true, reason: "judge the result against the request"}
  }'
}

compact_candidate() {
  candidate compact refactor 0.8 12 6 medium \
    | jq --argjson gate_plan "$(compact_gate_plan)" '. + {gatePlan: $gate_plan}'
}

route() {
  local input="$1" repo="${2:-$CLEAN_REPO}"
  printf '%s\n' "$input" | (cd "$repo" && bash "$SCRIPT" validate -) | jq -r '.route'
}

normalized() {
  local input="$1" repo="${2:-$CLEAN_REPO}"
  printf '%s\n' "$input" | (cd "$repo" && bash "$SCRIPT" validate -)
}

reason_code() {
  printf '%s\n' "$1" | (cd "$CLEAN_REPO" && bash "$SCRIPT" validate -) | jq -r '.reasonCode'
}

assert_route() {
  local name="$1" expected="$2" input="$3" repo="${4:-$CLEAN_REPO}" actual
  actual="$(route "$input" "$repo")"
  [[ "$actual" == "$expected" ]] && pass "$name" || fail "$name (expected $expected, got $actual)"
}

assert_route "small maintenance task remains micro" "micro" "$(candidate micro maintenance)"
[[ ! -f "$CLEAN_REPO/.loop-spec/last-result.json" ]] \
  && pass "route entry clears stale terminal result" \
  || fail "route entry clears stale terminal result"
assert_route "canonical loop-spec runtime files do not force full" "micro" "$(candidate micro maintenance)"
assert_route "concrete bounded bug uses debug" "debug" "$(candidate debug bug 0.85 4 2 medium)"
assert_route "explicit full proposal remains full" "full" "$(candidate full feature 0.95 2 2 low)"
assert_route "bounded refactor with a typed gate plan selects compact" "compact" "$(compact_candidate)"

assert_route "security work promotes to full" "full" "$(candidate micro config 0.95 1 1 low false false false true)"
assert_route "dependency work promotes to full" "full" "$(candidate micro maintenance 0.95 2 2 low false true)"
version_update="$(candidate micro maintenance 0.95 2 2 low false true | jq '. + {
  introducesNewDependency:false, updatesDependencyVersion:true}')"
assert_route "existing dependency version update remains micro" "micro" "$version_update"
generated_lockfiles="$(candidate micro maintenance 0.95 8 2 low | jq '. + {generatedFiles:6}')"
assert_route "generated lockfiles do not inflate reviewable scope" "micro" "$generated_lockfiles"
reviewable_count="$(normalized "$generated_lockfiles" | jq -r '.reviewableEstimatedFiles')"
[[ "$reviewable_count" == "2" ]] \
  && pass "normalized route records reviewable file count" \
  || fail "normalized route records reviewable file count (got $reviewable_count)"
assert_route "interface work promotes to full" "full" "$(candidate micro maintenance 0.95 2 2 low false false true)"
assert_route "data migration promotes to full" "full" "$(candidate micro maintenance 0.95 2 2 low false false false false true)"
assert_route "multi-repo work promotes to full" "full" "$(candidate micro maintenance 0.95 2 2 low false false false false false true)"
assert_route "destructive work promotes to full" "full" "$(candidate micro maintenance 0.95 2 2 low false false false false false false true)"
assert_route "dirty worktree promotes to full from measured state" "full" "$(candidate micro maintenance)" "$DIRTY_REPO"
assert_route "non-repository path promotes to full" "full" "$(candidate micro maintenance)" "$NON_REPO"
assert_route "unreadable repository state promotes to full" "full" "$(candidate micro maintenance)" "$CORRUPT_REPO"

clean_conflict="$(normalized "$(candidate micro maintenance)" | jq -r '.workingTreeConflict')"
[[ "$clean_conflict" == "false" ]] && pass "clean state is recorded by validator" || fail "clean state is recorded by validator"
dirty_conflict="$(normalized "$(candidate micro maintenance)" "$DIRTY_REPO" | jq -r '.workingTreeConflict')"
[[ "$dirty_conflict" == "true" ]] && pass "dirty state is recorded by validator" || fail "dirty state is recorded by validator"
assert_route "new seam promotes to full" "full" "$(candidate micro maintenance 0.95 2 2 low true)"
assert_route "more than five files promotes to full" "full" "$(candidate micro maintenance 0.95 6)"
assert_route "more than three criteria promotes to full" "full" "$(candidate micro maintenance 0.95 2 4)"
assert_route "ambiguous micro proposal promotes to full" "full" "$(candidate micro maintenance 0.95 2 2 medium)"
assert_route "low-confidence proposal promotes to full" "full" "$(candidate micro maintenance 0.79)"
assert_route "non-bug debug proposal promotes to full" "full" "$(candidate debug maintenance 0.9 2 2 low)"
assert_route "unknown task kind cannot use micro" "full" "$(candidate micro unknown 0.95 1 1 low)"
assert_route "greenfield task cannot use micro" "full" "$(candidate micro greenfield 0.95 1 1 low)"
assert_route "malformed JSON fails closed" "full" '{not-json'
assert_route "compact without gate plan fails closed" "full" "$(candidate compact refactor)"
assert_route "generated file count cannot exceed total estimate" "full" \
  "$(candidate micro maintenance | jq '. + {generatedFiles:3}')"
assert_route "dependency detail fields must agree with compatibility field" "full" \
  "$(candidate micro maintenance | jq '. + {
    introducesNewDependency:false, updatesDependencyVersion:true}')"

for risk in introducesSeam introducesNewDependency changesInterface securitySensitive dataMigration multiRepo; do
  proposal="$(compact_candidate | jq --arg risk "$risk" '
    .[$risk] = true |
    if $risk == "introducesNewDependency" then
      .introducesDependency = true | .updatesDependencyVersion = false
    else . end')"
  assert_route "compact classifier may select a bounded $risk change" "compact" "$proposal"
done
assert_route "compact classifier may select a bounded dirty-tree change" "compact" "$(compact_candidate)" "$DIRTY_REPO"
assert_route "destructive compact proposal promotes to full" "full" \
  "$(compact_candidate | jq '.destructive = true')"
assert_route "compact requires confidence of at least 0.7" "full" \
  "$(compact_candidate | jq '.confidence = 0.69')"
assert_route "compact rejects high ambiguity" "full" \
  "$(compact_candidate | jq '.ambiguity = "high"')"
assert_route "compact rejects more than twelve reviewable files" "full" \
  "$(compact_candidate | jq '.estimatedFiles = 13')"
assert_route "compact rejects more than six criteria" "full" \
  "$(compact_candidate | jq '.criteriaCount = 7')"
assert_route "compact requires every named gate" "full" \
  "$(compact_candidate | jq 'del(.gatePlan.iterate)')"
assert_route "compact requires typed gates" "full" \
  "$(compact_candidate | jq '.gatePlan.acceptance.run = "yes"')"
assert_route "compact gate entries cannot carry undeclared fields" "full" \
  "$(compact_candidate | jq '.gatePlan.acceptance.extra = true')"
assert_route "compact gate reasons cannot be blank" "full" \
  "$(compact_candidate | jq '.gatePlan.acceptance.reason = "  "')"
assert_route "compact gate reasons cannot inject a second probe line" "full" \
  "$(compact_candidate | jq '.gatePlan.acceptance.reason = "line one\nline two"')"
assert_route "compact gate reasons have a bounded probe-safe length" "full" \
  "$(compact_candidate | jq '.gatePlan.acceptance.reason = ("x" * 241)')"
assert_route "compact cannot run spec critique after skipping discuss" "full" \
  "$(compact_candidate | jq '.gatePlan.specCritique.run = true')"

# Routing arms the run: from here on, an exit with no terminal result is detectable.
armed="$CLEAN_REPO/.loop-spec/active-run.json"
rm -f "$armed"
route "$(candidate micro maintenance)" >/dev/null
[[ -f "$armed" ]] && pass "validation arms the routed run" || fail "validation arms the routed run"
armed_type="$(jq -r '.cycleType' "$armed" 2>/dev/null || echo missing)"
[[ "$armed_type" == "micro" ]] \
  && pass "armed record carries the normalized route" \
  || fail "armed record carries the normalized route (got $armed_type)"
rm -f "$armed"
route '{not-json' >/dev/null
armed_type="$(jq -r '.cycleType' "$armed" 2>/dev/null || echo missing)"
[[ "$armed_type" == "full" ]] \
  && pass "fail-closed routing arms the full route it selected" \
  || fail "fail-closed routing arms the full route it selected (got $armed_type)"
[[ "$(jq -c '.classification' "$armed")" == "null" ]] \
  && pass "fail-closed routing arms without a classification" \
  || fail "fail-closed routing arms without a classification (got $(jq -c '.classification' "$armed"))"
[[ -z "$(git -C "$CLEAN_REPO" status --porcelain)" ]] \
  && pass "arming leaves the tracked tree clean" \
  || fail "arming leaves the tracked tree clean"
rm -f "$armed"
out="$(normalized "$(candidate micro maintenance)")"
stored="$(jq -c '.classification' "$armed")"
[[ "$stored" == "$(jq -c . <<<"$out")" ]] \
  && pass "validation persists the normalized classification" \
  || fail "validation persists the normalized classification"
profile="$(jq -c '.classification' "$armed" \
  | bash "$(cd "$(dirname "$SCRIPT")" && pwd)/cycle-profile.sh" select - \
  | sed -E 's/^profile=([a-z]+).*/\1/')"
[[ "$profile" == "maintenance" ]] \
  && pass "persisted micro-maintenance classification selects maintenance" \
  || fail "persisted micro-maintenance classification selects maintenance (got $profile)"
rm -f "$armed"

invalid_reason="$(reason_code '{not-json')"
[[ "$invalid_reason" == "invalid-classification" ]] \
  && pass "malformed classification has an audit reason" \
  || fail "malformed classification reason (got $invalid_reason)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
