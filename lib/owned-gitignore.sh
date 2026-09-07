#!/usr/bin/env bash
# Validate that .gitignore dirt consists only of loop-spec's durable exceptions, and
# append those exceptions as one delimited block.
#
# Usage:
#   owned-gitignore.sh check <repo>              exit 0 clean-or-owned, 1 foreign dirt
#   owned-gitignore.sh ensure <repo> <line>...   append each missing <line> under the
#                                                loop-spec header; prints the lines added
#
# Why ensure exists: the driver appended its negations straight after whatever comment
# the user's .gitignore ended with, so a live run's reader saw them as that comment's
# subject and the PLAN spent a task undoing it. A blank line and a header of our own
# make the block read as ours.
set -euo pipefail

HEADER='# loop-spec: keep these tracked despite the ignores above'

case "${1:-}" in
  check|ensure) [[ -n "${2:-}" ]] ;;
  *) false ;;
esac || {
  echo "usage: owned-gitignore.sh check <repo> | ensure <repo> <line>..." >&2
  exit 2
}
mode="$1"
repo="$2"
# ensure edits the file and needs no repository; check reads git's view of it.
[[ "$mode" == "ensure" ]] || git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 2

if [[ "$mode" == "ensure" ]]; then
  file="$repo/.gitignore"
  added=0
  for line in "${@:3}"; do
    grep -qxF -- "$line" "$file" 2>/dev/null && continue
    if ! grep -qxF -- "$HEADER" "$file" 2>/dev/null; then
      # Separate the block from the user's last group when the file does not already
      # end on a blank line.
      if [[ -s "$file" ]]; then
        [[ -z "$(tail -c1 "$file")" ]] || printf '\n' >> "$file"
        [[ -z "$(tail -n1 "$file")" ]] || printf '\n' >> "$file"
      fi
      printf '%s\n' "$HEADER" >> "$file"
    fi
    printf '%s\n' "$line" >> "$file"
    printf '%s\n' "$line"
    added=$((added+1))
  done
  exit 0
fi

status="$(git -C "$repo" status --porcelain --untracked-files=all -- .gitignore)"
[[ -n "$status" ]] || exit 0

allowed_line() {
  case "$1" in
    ''|"$HEADER"|'!/.loop-spec/features/*/PROGRESS.md'|'!/.loop-spec/RULES.md') return 0 ;;
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
