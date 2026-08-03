#!/usr/bin/env bash
# Prepare a safe execution root for /loop-spec:revise.
#
# A local PR branch that is simply ahead of origin is not a history conflict: it is
# a fast-forwardable, unpushed commit and can be reconciled with an ordinary push.
# Only histories that each contain unique commits are a real divergence. This helper
# makes that distinction before any checkout, worktree creation, or feature runtime
# state write can mutate the user's branch.
#
# Usage:
#   revise-branch.sh prepare <repo> <branch> <0|1> [revision-worktree]
#
# Output: one JSON object {revisionRoot, branch, sync, mode}.
# Exit: 0 prepared; 2 bad invocation/precondition; 3 genuine divergence or failed
#       fast-forward reconciliation; 4 worktree setup failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=bounded-run.sh
. "$SCRIPT_DIR/bounded-run.sh"
loop_spec_disable_interactive_prompts

die() { echo "revise-branch: $*" >&2; exit 2; }
sync_fail() { echo "revise-branch: $*" >&2; exit 3; }
worktree_fail() { echo "revise-branch: $*" >&2; exit 4; }

[[ "${1:-}" == "prepare" ]] || die "usage: revise-branch.sh prepare <repo> <branch> <0|1> [revision-worktree]"
[[ $# -ge 4 && $# -le 5 ]] || die "prepare requires <repo> <branch> <0|1> [revision-worktree]"
repo="$2"
branch="$3"
mode="$4"
revision_root="${5:-}"
[[ "$mode" == "0" || "$mode" == "1" ]] || die "mode must be 0 or 1"
repo="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || die "not a git repository: $2"
git -C "$repo" remote get-url origin >/dev/null 2>&1 || die "origin remote is required"
[[ -n "$branch" ]] || die "branch must be non-empty"
if [[ "$mode" == "1" ]]; then
  [[ -n "$revision_root" ]] || die "worktree mode requires a revision-worktree path"
  [[ ! -e "$revision_root" ]] || worktree_fail "revision worktree path already exists: $revision_root"
else
  [[ -z "$(git -C "$repo" status --porcelain --untracked-files=all)" ]] \
    || die "LOOP_SPEC_WORKTREES=0 requires a clean dedicated checkout for revise"
fi

timeout_secs="$(loop_spec_resolve_timeout "${LOOP_SPEC_GH_COMMAND_TIMEOUT_SECONDS:-}" 60)" || timeout_secs=60
tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/loop-spec-revise-branch-XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
fetch_rc=0
loop_spec_run_bounded "$timeout_secs" "$tmp_dir/fetch.out" "$tmp_dir/fetch.err" \
  git -C "$repo" fetch origin "$branch" || fetch_rc=$?
if [[ "$fetch_rc" -ne 0 ]]; then
  sed -n '1,20p' "$tmp_dir/fetch.err" >&2 || true
  sync_fail "could not fetch origin/$branch (rc=$fetch_rc)"
fi
git -C "$repo" rev-parse --verify "refs/remotes/origin/$branch^{commit}" >/dev/null 2>&1 \
  || sync_fail "origin/$branch was not found after fetch"

sync="already-current"
local_exists=false
if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
  local_exists=true
  if git -C "$repo" merge-base --is-ancestor "origin/$branch" "$branch"; then
    if ! git -C "$repo" merge-base --is-ancestor "$branch" "origin/$branch"; then
      # Local-only commits are safe only when origin is their ancestor. Push without
      # force; a concurrent remote advance makes push fail and remains an abort.
      push_rc=0
      loop_spec_run_bounded "$timeout_secs" "$tmp_dir/push.out" "$tmp_dir/push.err" \
        git -C "$repo" push origin "refs/heads/$branch:refs/heads/$branch" || push_rc=$?
      if [[ "$push_rc" -ne 0 ]]; then
        sed -n '1,20p' "$tmp_dir/push.err" >&2 || true
        sync_fail "local $branch is ahead but fast-forward push failed (rc=$push_rc)"
      fi
      sync="pushed-local-ahead"
    fi
  elif git -C "$repo" merge-base --is-ancestor "$branch" "origin/$branch"; then
    sync="fast-forwarded-remote"
  else
    sync_fail "local $branch and origin/$branch have unique commits; refusing to rewrite either history"
  fi
fi

if [[ "$mode" == "1" ]]; then
  if [[ "$local_exists" == "true" ]]; then
    git -C "$repo" worktree add "$revision_root" "$branch" >/dev/null 2>&1 \
      || worktree_fail "could not add $branch at $revision_root (it may already be checked out)"
  else
    git -C "$repo" worktree add -b "$branch" "$revision_root" "origin/$branch" >/dev/null 2>&1 \
      || worktree_fail "could not create revision worktree for origin/$branch"
  fi
else
  revision_root="$repo"
  if [[ "$local_exists" == "true" ]]; then
    git -C "$revision_root" checkout "$branch" >/dev/null 2>&1 \
      || worktree_fail "could not check out $branch in the dedicated revise checkout"
  else
    git -C "$revision_root" checkout -b "$branch" --track "origin/$branch" >/dev/null 2>&1 \
      || worktree_fail "could not create local tracking branch for origin/$branch"
  fi
fi

if [[ "$sync" == "fast-forwarded-remote" ]]; then
  git -C "$revision_root" merge --ff-only "origin/$branch" >/dev/null 2>&1 \
    || sync_fail "origin/$branch could not be fast-forwarded into the revision checkout"
fi

jq -cn --arg root "$revision_root" --arg branch "$branch" --arg sync "$sync" --arg mode "$mode" \
  '{revisionRoot:$root,branch:$branch,sync:$sync,mode:($mode|tonumber)}'
