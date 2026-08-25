#!/usr/bin/env bash
# Transactionally verify and fast-forward a task branch into a feature branch.
# stdout is always one compact JSON result; command output is redirected to stderr.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

feature_root=""
feature_branch=""
task_worktree=""
task_branch=""
verify_command="true"
prepare_command=""
cleanup_requested=false
preflight_only=false
parse_error=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --feature-root|--feature-branch|--task-worktree|--task-branch|--verify|--verify-command|--prepare|--prepare-command)
      if [[ $# -lt 2 ]]; then parse_error=missing-option-value; break; fi
      case "$1" in
        --feature-root) feature_root="$2" ;;
        --feature-branch) feature_branch="$2" ;;
        --task-worktree) task_worktree="$2" ;;
        --task-branch) task_branch="$2" ;;
        --verify|--verify-command) verify_command="$2" ;;
        --prepare|--prepare-command) prepare_command="$2" ;;
      esac
      shift 2
      ;;
    --cleanup) cleanup_requested=true; shift ;;
    --preflight-only) preflight_only=true; shift ;;
    *) parse_error=unknown-option; break ;;
  esac
done

feature_before=""
candidate=""
rebased=false
published=false
cleaned_up=false

emit() {
  local status="$1" reason="$2" detail="$3"
  jq -cn \
    --arg status "$status" --arg reason "$reason" --arg detail "$detail" \
    --arg featureBranch "$feature_branch" --arg taskBranch "$task_branch" \
    --arg featureBefore "$feature_before" --arg candidate "$candidate" \
    --argjson rebased "$rebased" --argjson published "$published" \
    --argjson cleanedUp "$cleaned_up" \
    '{schema:1,status:$status,reason:$reason,detail:$detail,
      featureBranch:$featureBranch,taskBranch:$taskBranch,
      featureBefore:(if $featureBefore == "" then null else $featureBefore end),
      candidate:(if $candidate == "" then null else $candidate end),
      rebased:$rebased,published:$published,cleanedUp:$cleanedUp}'
}

fail() {
  emit failed "$1" "$2"
  exit "${3:-1}"
}

if [[ -n "$parse_error" ]]; then
  fail invalid-arguments "$parse_error" 2
fi
if [[ -z "$feature_root" || -z "$feature_branch" || -z "$task_worktree" || -z "$task_branch" ]]; then
  fail invalid-arguments missing-required-option 2
fi
if [[ ! -d "$feature_root" || ! -d "$task_worktree" ]]; then
  fail invalid-arguments worktree-not-found 2
fi
feature_root="$(cd "$feature_root" && pwd -P)" \
  || fail invalid-arguments feature-not-worktree 2
task_worktree="$(cd "$task_worktree" && pwd -P)" \
  || fail invalid-arguments task-not-worktree 2
if ! git check-ref-format "refs/heads/$feature_branch" >/dev/null 2>&1 \
    || ! git check-ref-format "refs/heads/$task_branch" >/dev/null 2>&1; then
  fail invalid-arguments invalid-branch 2
fi

feature_top="$(git -C "$feature_root" rev-parse --show-toplevel 2>/dev/null)" \
  || fail invalid-arguments feature-not-worktree 2
task_top="$(git -C "$task_worktree" rev-parse --show-toplevel 2>/dev/null)" \
  || fail invalid-arguments task-not-worktree 2
if [[ "$feature_top" != "$feature_root" || "$task_top" != "$task_worktree" ]]; then
  fail invalid-arguments worktree-root-mismatch 2
fi

normalize_common_dir() {
  local root="$1" common
  common="$(git -C "$root" rev-parse --git-common-dir 2>/dev/null)" || return 1
  if [[ "$common" == /* ]]; then
    (cd "$common" && pwd -P)
  else
    (cd "$root/$common" && pwd -P)
  fi
}

feature_common="$(normalize_common_dir "$feature_root")" \
  || fail invalid-arguments feature-not-worktree 2
task_common="$(normalize_common_dir "$task_worktree")" \
  || fail invalid-arguments task-not-worktree 2
if [[ "$feature_common" != "$task_common" ]]; then
  fail invalid-arguments unrelated-worktrees 2
fi

active_feature="$(git -C "$feature_root" symbolic-ref --quiet --short HEAD 2>/dev/null)" \
  || fail invalid-arguments feature-detached 2
active_task="$(git -C "$task_worktree" symbolic-ref --quiet --short HEAD 2>/dev/null)" \
  || fail invalid-arguments task-detached 2
if [[ "$active_feature" != "$feature_branch" ]]; then
  fail invalid-arguments feature-branch-mismatch 2
fi
if [[ "$active_task" != "$task_branch" ]]; then
  fail invalid-arguments task-branch-mismatch 2
fi

feature_before="$(git -C "$feature_root" rev-parse --verify "refs/heads/$feature_branch^{commit}" 2>/dev/null)" \
  || fail invalid-arguments feature-ref-not-found 2
task_before="$(git -C "$task_worktree" rev-parse --verify "refs/heads/$task_branch^{commit}" 2>/dev/null)" \
  || fail invalid-arguments task-ref-not-found 2

clean_detail=""
is_known_runtime_path() {
  case "$1" in
    .loop-spec/features/*/feature.json|.loop-spec/features/*/PROGRESS.md) return 1 ;;
    .loop-spec/features/*/*|.loop-spec/runtime.json|.loop-spec/decisions-staging/*|\
    .loop-spec/last-result.json|.loop-spec/results/*|.loop-spec/worktrees/*|\
    .loop-spec/learnings.jsonl|.loop/*|graphify-out/*|\
    graphify-out/.graphify_python|graphify-out/.graphify_root|\
    graphify-out/.graphify_chunk_*.json|graphify-out/.graphify_detect*.json|\
    graphify-out/.graphify_extract*.json|graphify-out/.graphify_ast*.json|\
    graphify-out/.graphify_semantic*.json|graphify-out/.graphify_cached*.json|\
    graphify-out/.graphify_incremental*.json|graphify-out/.graphify_old*.json|\
    graphify-out/.graphify_uncached.txt|graphify-out/.graphify_pending*|\
    graphify-out/.needs_update|graphify-out/*.tmp|graphify-out/*.lock|\
    graphify-out/????-??-??/*) return 0 ;;
    *) return 1 ;;
  esac
}

check_clean() {
  local root="$1" label="$2" status_output line path
  if ! status_output="$(git -C "$root" status --porcelain=v1 --untracked-files=all 2>/dev/null)"; then
    clean_detail="${label}-status-failed"
    return 1
  fi
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$line" == "?? "* ]]; then
      path="${line:3}"
      is_known_runtime_path "$path" && continue
    fi
    clean_detail="${label}-dirty"
    return 1
  done <<< "$status_output"
  return 0
}

if ! check_clean "$task_worktree" task; then
  fail check-dirty-worktree "$clean_detail"
fi

ahead="$(git -C "$feature_root" rev-list --count "$feature_before..$task_before" 2>/dev/null)" \
  || fail invalid-arguments commit-range-failed 2
if [[ "$ahead" -eq 0 ]]; then
  fail zero-commit task-has-no-unintegrated-commits
fi

if ! git -C "$feature_root" merge-base --is-ancestor "$feature_before" "$task_before" 2>/dev/null; then
  if git -C "$task_worktree" rebase "$feature_before" >&2; then
    rebased=true
  else
    abort_detail=rebase-aborted
    git -C "$task_worktree" rebase --abort >&2 || abort_detail=rebase-abort-failed
    fail rebase-conflict "$abort_detail"
  fi
fi

candidate="$(git -C "$task_worktree" rev-parse --verify "refs/heads/$task_branch^{commit}" 2>/dev/null)" \
  || fail invalid-arguments task-ref-not-found 2
if ! git -C "$feature_root" merge-base --is-ancestor "$feature_before" "$candidate" 2>/dev/null \
    || [[ "$(git -C "$feature_root" rev-list --count "$feature_before..$candidate" 2>/dev/null)" -eq 0 ]]; then
  fail zero-commit rebase-produced-no-candidate
fi

if [[ -n "$prepare_command" ]]; then
  prepare_rc=0
  (cd "$task_worktree" && LOOP_SPEC_INTEGRATION_CANDIDATE="$candidate" bash -o pipefail -c "$prepare_command") >&2 \
    || prepare_rc=$?
  if ! check_clean "$task_worktree" task-after-prepare; then
    fail check-dirty-worktree "$clean_detail"
  fi
  if [[ "$prepare_rc" -ne 0 ]]; then
    fail prepare-failed command-exited-nonzero
  fi
fi

verify_rc=0
(cd "$task_worktree" && LOOP_SPEC_INTEGRATION_CANDIDATE="$candidate" bash -o pipefail -c "$verify_command") >&2 \
  || verify_rc=$?
if ! check_clean "$task_worktree" task-after-verify; then
  fail check-dirty-worktree "$clean_detail"
fi
if [[ "$verify_rc" -ne 0 ]]; then
  fail verify-failed command-exited-nonzero
fi
if [[ "$(git -C "$task_worktree" rev-parse HEAD 2>/dev/null)" != "$candidate" ]]; then
  fail candidate-changed verify-moved-task-head
fi

# Recheck the immutable candidate contract after arbitrary prepare/verify commands.
current_feature="$(git -C "$feature_root" rev-parse --verify "refs/heads/$feature_branch^{commit}" 2>/dev/null)" \
  || fail feature-moved feature-ref-unreadable
if [[ "$current_feature" != "$feature_before" ]]; then
  fail feature-moved feature-ref-changed
fi
if ! check_clean "$feature_root" feature; then
  fail check-dirty-worktree "$clean_detail"
fi
if [[ "$(git -C "$task_worktree" rev-parse --verify "refs/heads/$task_branch^{commit}" 2>/dev/null)" != "$candidate" ]]; then
  fail candidate-changed task-ref-changed
fi
if ! check_clean "$task_worktree" task-before-publication; then
  fail check-dirty-worktree "$clean_detail"
fi

if [[ "$preflight_only" == true ]]; then
  emit success ready preflight-complete
  exit 0
fi

publish_rc=0
git -C "$feature_root" merge --ff-only "$candidate" >&2 || publish_rc=$?
published_sha="$(git -C "$feature_root" rev-parse --verify "refs/heads/$feature_branch^{commit}" 2>/dev/null || true)"
if [[ "$published_sha" == "$candidate" ]]; then
  published=true
fi
if [[ "$publish_rc" -ne 0 || "$published" != true ]]; then
  fail publish-failed fast-forward-failed
fi

if [[ "$cleanup_requested" == true ]]; then
  if ! bash "$SCRIPT_DIR/git-ops.sh" -C "$feature_root" remove-task-worktree "$task_worktree" >/dev/null; then
    dirty="$(git -C "$task_worktree" status --porcelain 2>/dev/null | tr '\n' ' ')"
    fail cleanup-failed "worktree-remove-refused:${dirty:-unknown}"
  fi
  if ! git -C "$feature_root" branch -d "$task_branch" >&2; then
    fail cleanup-failed branch-delete-failed
  fi
  cleaned_up=true
fi

emit success published integration-complete
