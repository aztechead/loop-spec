#!/usr/bin/env bash
# Git helpers used across loop-spec skills.
#
# Usage:
#   git-ops.sh [-C <path>] <subcommand> [args...]
#
# Global option:
#   -C <path>   Run git commands as if started in <path>. When given,
#               create-feature-worktree prints an absolute worktree path
#               inside <path>/.claude/worktrees/<slug>. Without -C the
#               relative path .claude/worktrees/<slug> is printed (preserving
#               existing caller behavior).
#
# Worktree LOCATION is not hard-coded: `lib/worktree-base.sh` resolves it (and
# reports why). The default stays in-repo; it moves outside the repository when the
# in-repo base cannot hold the checkout — e.g. a sandboxed harness that denies writes
# to `.claude/commands/**` inside the active repo — or when the operator points
# LOOP_SPEC_WORKTREE_DIR somewhere else.
#
# Subcommands:
#   detect-base-branch                  Print the project's base branch (origin/HEAD or fallback).
#   slugify <text>                      Print kebab-case slug of <text>.
#   ensure-clean-or-stash               Print "clean" if working tree clean apart from
#                                       loop-spec's pre-feature runtime cache, else "dirty".
#   current-sha                         Print HEAD short sha.
#   create-feature-worktree <slug> <base_sha>
#                                       Create a worktree at the resolved feature base
#                                       (default .claude/worktrees/<slug>, relative without -C
#                                       and absolute with -C) on branch feat/<slug> rooted at
#                                       <base_sha>. Exits 1 if the worktree path or branch
#                                       already exists, or if no base can hold the checkout.
#                                       A failed checkout is cleaned up (no partial worktree,
#                                       no orphan branch). Prints the worktree path on success.
#   attach-feature-worktree <slug> <branch>
#                                       Attach a worktree at the same resolved feature
#                                       base to an EXISTING branch (an adopted PR head).
#                                       Does not mint feat/<slug>. Reuses the checkout if
#                                       <branch> is already checked out. Prints the
#                                       worktree path.
#   checkout-path-for-branch <branch>
#                                       Print the worktree path that currently has
#                                       <branch> checked out, or empty if none.
#   list-feature-worktrees              Print one "<path>\t<branch>" line per worktree that is
#                                       on a feat/* branch or under any candidate feature base
#                                       for this repo (including "/.claude/worktrees/").
#                                       No output if none.
#   remove-task-worktree <path>         Remove a task worktree that already had a successful
#                                       checkout. Never --force: if git refuses because of
#                                       modified or untracked files, print them and exit 1.
#                                       Partial-add rollback still uses --force inline.
#
# Exit codes:
#   0 success (the answer is on stdout)
#   1 bad invocation, or remove-task-worktree refused (uncommitted/untracked files)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse optional leading -C <path>
G=(git)
if [[ "${1:-}" == "-C" ]]; then
  if [[ -z "${2:-}" ]]; then
    echo "git-ops.sh: -C requires a path argument" >&2
    exit 1
  fi
  G=(git -C "$2")
  shift 2
fi

cmd="${1:-}"

# Sets _repo_root and _wt (path to print). Returns 1 after printing why.
_feature_worktree_location() {
  local slug="$1"
  if [[ "${#G[@]}" -gt 1 ]]; then
    _repo_root="${G[2]}"
  else
    _repo_root="$("${G[@]}" rev-parse --show-toplevel)"
  fi
  local location
  location="$(bash "$SCRIPT_DIR/worktree-base.sh" resolve "$_repo_root" feature "$slug")"
  if [[ "$(jq -r '.writable' <<<"$location")" != "true" ]]; then
    echo "$cmd: no usable worktree location for $_repo_root" >&2
    echo "$cmd: $(jq -r '.reason' <<<"$location")" >&2
    echo "$cmd: a sandboxed harness can deny writing harness-config paths (e.g. .claude/commands/**) into an in-repo worktree." >&2
    echo "$cmd: set LOOP_SPEC_WORKTREE_DIR to a writable path outside the repository, or LOOP_SPEC_WORKTREES=0 to work in place." >&2
    return 1
  fi
  if [[ "$(jq -r '.relocated' <<<"$location")" == "true" ]]; then
    _wt="$(jq -r '.path' <<<"$location")"
    echo "$cmd: $(jq -r '.reason' <<<"$location")" >&2
  elif [[ "${#G[@]}" -gt 1 ]]; then
    _wt="${_repo_root}/.claude/worktrees/${slug}"
  else
    _wt=".claude/worktrees/${slug}"
  fi
  return 0
}

_require_worktrees_enabled() {
  local in_place_hint="$1"
  case "${LOOP_SPEC_WORKTREES:-1}" in
    0)
      echo "$cmd: LOOP_SPEC_WORKTREES=0 forbids worktree creation; $in_place_hint" >&2
      exit 1
      ;;
    1) ;;
    *)
      echo "$cmd: LOOP_SPEC_WORKTREES must be 0 or 1" >&2
      exit 1
      ;;
  esac
}

# Path of the worktree that currently has <branch> checked out, or empty.
_checkout_path_for_branch() {
  local branch="$1"
  local want_ref="refs/heads/$branch"
  local checkout_path="" cur_path=""
  while IFS= read -r line; do
    case "$line" in
      worktree\ *) cur_path="${line#worktree }" ;;
      branch\ *)
        if [[ "${line#branch }" == "$want_ref" ]]; then
          checkout_path="$cur_path"
        fi
        ;;
      "") cur_path="" ;;
    esac
  done < <("${G[@]}" worktree list --porcelain)
  printf '%s' "$checkout_path"
}

case "$cmd" in
  detect-base-branch)
    if branch=$("${G[@]}" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null); then
      printf '%s\n' "${branch#refs/remotes/origin/}"
    else
      printf 'main\n'
    fi
    ;;
  slugify)
    text="${2:-}"
    if [[ -z "$text" ]]; then
      echo "slugify: empty input" >&2
      exit 1
    fi
    printf '%s' "$text" \
      | tr '[:upper:]' '[:lower:]' \
      | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g; s/-+/-/g'
    printf '\n'
    ;;
  ensure-clean-or-stash)
    # Startup writes these local files before the feature branch/worktree exists.
    # They are not user work and must not make the clean-base guard reject itself.
    status_output=""
    if ! status_output="$("${G[@]}" status --porcelain --untracked-files=all -- . \
      ':(top,exclude).loop-spec/runtime.json' \
      ':(top,exclude).loop-spec/decisions-staging/**')"; then
      printf 'dirty\n'
    elif [[ -z "$status_output" ]]; then
      printf 'clean\n'
    else
      printf 'dirty\n'
    fi
    ;;
  current-sha)
    "${G[@]}" rev-parse --short HEAD
    ;;
  create-feature-worktree)
    slug="${2:-}"
    base_sha="${3:-}"
    if [[ -z "$slug" || -z "$base_sha" ]]; then
      echo "create-feature-worktree: usage: git-ops.sh create-feature-worktree <slug> <base_sha>" >&2
      exit 1
    fi
    _require_worktrees_enabled "use the clean in-place feature branch"
    branch="feat/${slug}"
    _feature_worktree_location "$slug" || exit 1
    wt="$_wt"
    if [[ -e "$wt" ]]; then
      echo "create-feature-worktree: worktree path already exists: $wt" >&2
      exit 1
    fi
    if "${G[@]}" show-ref --verify --quiet "refs/heads/${branch}"; then
      echo "create-feature-worktree: branch already exists: $branch" >&2
      exit 1
    fi
    if ! "${G[@]}" worktree add "$wt" -b "$branch" "$base_sha" >&2; then
      # git aborts a denied or interrupted checkout part-way through, leaving the
      # worktree dir, its registration, and the new branch behind. Roll all three
      # back so the next attempt is not blocked by the debris of this one.
      "${G[@]}" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
      "${G[@]}" worktree prune >/dev/null 2>&1 || true
      "${G[@]}" branch -D "$branch" >/dev/null 2>&1 || true
      echo "create-feature-worktree: git worktree add failed for $wt (cleaned up the partial worktree and branch)." >&2
      echo "create-feature-worktree: if the harness sandbox denied a harness-config path, set LOOP_SPEC_WORKTREE_DIR to a writable path outside the repository, or LOOP_SPEC_WORKTREES=0 to work in place." >&2
      exit 1
    fi
    printf '%s\n' "$wt"
    ;;
  attach-feature-worktree)
    slug="${2:-}"
    branch="${3:-}"
    if [[ -z "$slug" || -z "$branch" ]]; then
      echo "attach-feature-worktree: usage: git-ops.sh attach-feature-worktree <slug> <branch>" >&2
      exit 1
    fi
    _require_worktrees_enabled "check out $branch in place"
    _feature_worktree_location "$slug" || exit 1
    wt="$_wt"
    checkout_path="$(_checkout_path_for_branch "$branch")"
    if [[ -n "$checkout_path" ]]; then
      printf '%s\n' "$checkout_path"
      exit 0
    fi
    if [[ -e "$wt" ]]; then
      echo "attach-feature-worktree: worktree path already exists: $wt" >&2
      exit 1
    fi
    if "${G[@]}" show-ref --verify --quiet "refs/heads/${branch}"; then
      if ! "${G[@]}" worktree add "$wt" "$branch" >&2; then
        "${G[@]}" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
        "${G[@]}" worktree prune >/dev/null 2>&1 || true
        echo "attach-feature-worktree: git worktree add failed for $wt (cleaned up the partial worktree)." >&2
        exit 1
      fi
    elif "${G[@]}" rev-parse --verify "refs/remotes/origin/${branch}^{commit}" >/dev/null 2>&1; then
      if ! "${G[@]}" worktree add -b "$branch" "$wt" "origin/$branch" >&2; then
        "${G[@]}" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
        "${G[@]}" worktree prune >/dev/null 2>&1 || true
        "${G[@]}" branch -D "$branch" >/dev/null 2>&1 || true
        echo "attach-feature-worktree: git worktree add failed for origin/$branch (cleaned up the partial worktree and branch)." >&2
        exit 1
      fi
    else
      echo "attach-feature-worktree: branch not found locally or on origin: $branch" >&2
      exit 1
    fi
    printf '%s\n' "$wt"
    ;;
  checkout-path-for-branch)
    branch="${2:-}"
    if [[ -z "$branch" ]]; then
      echo "checkout-path-for-branch: usage: git-ops.sh checkout-path-for-branch <branch>" >&2
      exit 1
    fi
    _checkout_path_for_branch "$branch"
    printf '\n'
    ;;
  list-feature-worktrees)
    if [[ "${#G[@]}" -gt 1 ]]; then
      repo_root="${G[2]}"
    else
      repo_root="$("${G[@]}" rev-parse --show-toplevel)"
    fi
    # A feature worktree may sit under any candidate base, not just the in-repo
    # default, so discovery matches all of them (bash 3.2-safe read loop).
    bases=()
    while IFS= read -r base_line; do
      [[ -n "$base_line" ]] && bases+=("$base_line")
    done < <(bash "$SCRIPT_DIR/worktree-base.sh" bases "$repo_root" feature 2>/dev/null || true)
    "${G[@]}" worktree list --porcelain | awk '
      /^worktree / { path = substr($0, 10) }
      /^branch /   { branch = substr($0, 8) }
      /^$/         {
        if (path != "") {
          sub(/^refs\/heads\//, "", branch)
          print path "\t" branch
        }
        path = ""; branch = ""
      }
    ' | while IFS=$'\t' read -r wt_path wt_branch; do
      matched=0
      if [[ "$wt_path" == *"/.claude/worktrees/"* || "$wt_branch" == feat/* ]]; then
        # `feat/<slug>` is loop-spec's feature-branch contract, so it identifies a
        # feature worktree wherever it lives — including one created under an
        # operator override that is no longer exported at resume time. Foreign
        # feat/ worktrees carry no .loop-spec/features state and are ignored by
        # the resume scan that consumes this listing.
        matched=1
      else
        # Compare resolved forms: git records the real path, while a candidate
        # base may be reached through a symlinked parent (/var vs /private/var).
        wt_real="$wt_path"
        [[ -d "$wt_path" ]] && wt_real="$(cd "$wt_path" && pwd -P)"
        for base in ${bases[@]+"${bases[@]}"}; do
          if [[ "$wt_path" == "$base"/* || "$wt_real" == "$base"/* ]]; then
            matched=1
            break
          fi
        done
      fi
      [[ "$matched" -eq 1 ]] && printf '%s\t%s\n' "$wt_path" "$wt_branch"
    done
    ;;
  remove-task-worktree)
    wt="${2:-}"
    if [[ -z "$wt" ]]; then
      echo "remove-task-worktree: usage: git-ops.sh remove-task-worktree <path>" >&2
      exit 1
    fi
    if "${G[@]}" worktree remove "$wt" >/dev/null 2>&1; then
      echo "removed"
      exit 0
    fi
    echo "remove-task-worktree: git refused to remove $wt (uncommitted or untracked files). Not using --force." >&2
    if [[ -d "$wt" ]]; then
      git -C "$wt" status --porcelain >&2 || true
    fi
    exit 1
    ;;
  *)
    echo "usage: git-ops.sh [-C <path>] {detect-base-branch|slugify <text>|ensure-clean-or-stash|current-sha|create-feature-worktree <slug> <base_sha>|attach-feature-worktree <slug> <branch>|checkout-path-for-branch <branch>|list-feature-worktrees|remove-task-worktree <path>}" >&2
    exit 1
    ;;
esac
