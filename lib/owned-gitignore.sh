#!/usr/bin/env bash
# Validate that .gitignore dirt consists only of loop-spec's durable exceptions.
set -euo pipefail

[[ "${1:-}" == "check" && -n "${2:-}" ]] || {
  echo "usage: owned-gitignore.sh check <repo>" >&2
  exit 2
}
repo="$2"
git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 2

status="$(git -C "$repo" status --porcelain --untracked-files=all -- .gitignore)"
[[ -n "$status" ]] || exit 0

allowed_line() {
  case "$1" in
    '!/.loop-spec/features/*/PROGRESS.md'|'!/.loop-spec/RULES.md') return 0 ;;
    *) return 1 ;;
  esac
}

if ! git -C "$repo" ls-files --error-unmatch -- .gitignore >/dev/null 2>&1; then
  [[ -f "$repo/.gitignore" ]] || exit 1
  while IFS= read -r line; do
    [[ -z "$line" ]] || allowed_line "$line" || exit 1
  done < "$repo/.gitignore"
  exit 0
fi

validate_diff() {
  local mode="$1" line
  local args=(diff --no-ext-diff --unified=0)
  [[ "$mode" == "cached" ]] && args+=(--cached)
  args+=(-- .gitignore)
  while IFS= read -r line; do
    case "$line" in
      ""|"+++ "*|"--- "*|@@*|"diff "*|"index "*) ;;
      +*) allowed_line "${line:1}" || return 1 ;;
      -*) return 1 ;;
      *) return 1 ;;
    esac
  done < <(git -C "$repo" "${args[@]}")
}

validate_diff worktree && validate_diff cached
