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
# Subcommands:
#   detect-base-branch                  Print the project's base branch (origin/HEAD or fallback).
#   slugify <text>                      Print kebab-case slug of <text>.
#   ensure-clean-or-stash               Print "clean" if working tree clean apart from
#                                       loop-spec's pre-feature runtime cache, else "dirty".
#   current-sha                         Print HEAD short sha.
#   create-feature-worktree <slug> <base_sha>
#                                       Create a worktree at .claude/worktrees/<slug> (relative,
#                                       no -C) or <path>/.claude/worktrees/<slug> (absolute, -C)
#                                       on branch feat/<slug> rooted at <base_sha>. Exits 1 if
#                                       the worktree path or branch already exists. Prints the
#                                       worktree path on success.
#   list-feature-worktrees              Print one "<path>\t<branch>" line per worktree whose path
#                                       contains "/.claude/worktrees/". No output if none.
#
# Exit codes:
#   0 success (always; the answer is on stdout)
#   1 bad invocation
set -euo pipefail

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
    branch="feat/${slug}"
    if [[ "${#G[@]}" -gt 1 ]]; then
      # -C mode: build absolute path inside the target repo dir
      repo_root="${G[2]}"
      wt="${repo_root}/.claude/worktrees/${slug}"
    else
      wt=".claude/worktrees/${slug}"
    fi
    if [[ -e "$wt" ]]; then
      echo "create-feature-worktree: worktree path already exists: $wt" >&2
      exit 1
    fi
    if "${G[@]}" show-ref --verify --quiet "refs/heads/${branch}"; then
      echo "create-feature-worktree: branch already exists: $branch" >&2
      exit 1
    fi
    "${G[@]}" worktree add "$wt" -b "$branch" "$base_sha" >&2
    printf '%s\n' "$wt"
    ;;
  list-feature-worktrees)
    "${G[@]}" worktree list --porcelain | awk '
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
    echo "usage: git-ops.sh [-C <path>] {detect-base-branch|slugify <text>|ensure-clean-or-stash|current-sha|create-feature-worktree <slug> <base_sha>|list-feature-worktrees}" >&2
    exit 1
    ;;
esac
