#!/usr/bin/env bash
# runtime-ignore.sh - Keep loop-spec and Graphify machine-local artifacts out of Git.
#
# Writes to the repository's common info/exclude file so consumer projects do not
# need a tracked .gitignore change and linked worktrees share one policy.
#
# Usage: runtime-ignore.sh ensure <repo>
set -euo pipefail

[[ "${1:-}" == "ensure" && -n "${2:-}" ]] || {
  echo "usage: runtime-ignore.sh ensure <repo>" >&2
  exit 2
}

repo="$2"
git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "runtime-ignore: not a git work tree: $repo" >&2
  exit 1
}

common_dir="$(git -C "$repo" rev-parse --git-common-dir)"
[[ "$common_dir" == /* ]] || common_dir="$(cd "$repo" && cd "$common_dir" && pwd)"
exclude_file="$common_dir/info/exclude"
mkdir -p "$(dirname "$exclude_file")"
touch "$exclude_file"

ensure_line() {
  local line="$1"
  grep -qxF -- "$line" "$exclude_file" 2>/dev/null || printf '%s\n' "$line" >> "$exclude_file"
}

ensure_line "# loop-spec managed local artifacts"
patterns=(
  '/.loop-spec/features/*/*'
  '!/.loop-spec/features/*/feature.json'
  '!/.loop-spec/features/*/PROGRESS.md'
  '/.loop-spec/runtime.json'
  '/.loop-spec/decisions-staging/'
  '/.loop-spec/last-result.json'
  '/.loop-spec/results/'
  '/.loop-spec/worktrees/'
  '/.loop-spec/learnings.jsonl'
  '/.loop/'
  '/graphify-out/cost.json'
  '/graphify-out/cache/'
  '/graphify-out/.graphify_python'
  '/graphify-out/.graphify_root'
  '/graphify-out/.graphify_chunk_*.json'
  '/graphify-out/.graphify_detect*.json'
  '/graphify-out/.graphify_extract*.json'
  '/graphify-out/.graphify_ast*.json'
  '/graphify-out/.graphify_semantic*.json'
  '/graphify-out/.graphify_cached*.json'
  '/graphify-out/.graphify_incremental*.json'
  '/graphify-out/.graphify_old*.json'
  '/graphify-out/.graphify_uncached.txt'
  '/graphify-out/.graphify_pending*'
  '/graphify-out/.needs_update'
  '/graphify-out/*.tmp'
  '/graphify-out/*.lock'
  '/graphify-out/????-??-??/'
)
for pattern in "${patterns[@]}"; do
  ensure_line "$pattern"
done
