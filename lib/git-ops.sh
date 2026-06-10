#!/usr/bin/env bash
# Git helpers used across loop-spec skills.
#
# Subcommands:
#   detect-base-branch                  Print the project's base branch (origin/HEAD or fallback).
#   slugify <text>                      Print kebab-case slug of <text>.
#   ensure-clean-or-stash               Print "clean" if working tree clean, else "dirty".
#   current-sha                         Print HEAD short sha.
#   create-feature-worktree <slug> <base_sha>
#                                       Create a worktree at .claude/worktrees/<slug> on branch
#                                       feat/<slug> rooted at <base_sha>. Exits 1 if the worktree
#                                       path or branch already exists. Prints the worktree path on
#                                       success.
#   list-feature-worktrees              Print one "<path>\t<branch>" line per worktree whose path
#                                       contains "/.claude/worktrees/". No output if none.
#
# Exit codes:
#   0 success (always; the answer is on stdout)
#   1 bad invocation
set -euo pipefail

cmd="${1:-}"

case "$cmd" in
  detect-base-branch)
    if branch=$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null); then
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
    if [[ -z "$(git status --porcelain)" ]]; then
      printf 'clean\n'
    else
      printf 'dirty\n'
    fi
    ;;
  current-sha)
    git rev-parse --short HEAD
    ;;
  create-feature-worktree)
    slug="${2:-}"
    base_sha="${3:-}"
    if [[ -z "$slug" || -z "$base_sha" ]]; then
      echo "create-feature-worktree: usage: git-ops.sh create-feature-worktree <slug> <base_sha>" >&2
      exit 1
    fi
    wt=".claude/worktrees/${slug}"
    branch="feat/${slug}"
    if [[ -e "$wt" ]]; then
      echo "create-feature-worktree: worktree path already exists: $wt" >&2
      exit 1
    fi
    if git show-ref --verify --quiet "refs/heads/${branch}"; then
      echo "create-feature-worktree: branch already exists: $branch" >&2
      exit 1
    fi
    git worktree add "$wt" -b "$branch" "$base_sha" >&2
    printf '%s\n' "$wt"
    ;;
  list-feature-worktrees)
    git worktree list --porcelain | awk '
      /^worktree / { path = substr($0, 10) }
      /^branch /   { branch = substr($0, 8) }
      /^$/         {
        if (index(path, "/.claude/worktrees/") > 0) {
          sub(/^refs\/heads\//, "", branch)
          print path "\t" branch
        }
        path = ""; branch = ""
      }
    '
    ;;
  *)
    echo "usage: git-ops.sh {detect-base-branch|slugify <text>|ensure-clean-or-stash|current-sha|create-feature-worktree <slug> <base_sha>|list-feature-worktrees}" >&2
    exit 1
    ;;
esac
