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
#   list-feature-worktrees              Print one "<path>\t<branch>" line per worktree that is
#                                       on a feat/* branch or under any candidate feature base
#                                       for this repo (including "/.claude/worktrees/").
#                                       No output if none.
#
# Exit codes:
#   0 success (always; the answer is on stdout)
#   1 bad invocation
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
    case "${LOOP_SPEC_WORKTREES:-1}" in
      0)
        echo "create-feature-worktree: LOOP_SPEC_WORKTREES=0 forbids worktree creation; use the clean in-place feature branch" >&2
        exit 1
        ;;
      1) ;;
      *)
        echo "create-feature-worktree: LOOP_SPEC_WORKTREES must be 0 or 1" >&2
        exit 1
        ;;
    esac
    branch="feat/${slug}"
    if [[ "${#G[@]}" -gt 1 ]]; then
      # -C mode: build absolute paths inside the target repo dir
      repo_root="${G[2]}"
    else
      repo_root="$("${G[@]}" rev-parse --show-toplevel)"
    fi
    location="$(bash "$SCRIPT_DIR/worktree-base.sh" resolve "$repo_root" feature "$slug")"
    if [[ "$(jq -r '.writable' <<<"$location")" != "true" ]]; then
      echo "create-feature-worktree: no usable worktree location for $repo_root" >&2
      echo "create-feature-worktree: $(jq -r '.reason' <<<"$location")" >&2
      echo "create-feature-worktree: a sandboxed harness can deny writing harness-config paths (e.g. .claude/commands/**) into an in-repo worktree." >&2
      echo "create-feature-worktree: set LOOP_SPEC_WORKTREE_DIR to a writable path outside the repository, or LOOP_SPEC_WORKTREES=0 to work in place." >&2
      exit 1
    fi
    if [[ "$(jq -r '.relocated' <<<"$location")" == "true" ]]; then
      # Outside the repo, so there is no meaningful relative form: always absolute.
      wt="$(jq -r '.path' <<<"$location")"
      echo "create-feature-worktree: $(jq -r '.reason' <<<"$location")" >&2
    elif [[ "${#G[@]}" -gt 1 ]]; then
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
  *)
    echo "usage: git-ops.sh [-C <path>] {detect-base-branch|slugify <text>|ensure-clean-or-stash|current-sha|create-feature-worktree <slug> <base_sha>|list-feature-worktrees}" >&2
    exit 1
    ;;
esac
