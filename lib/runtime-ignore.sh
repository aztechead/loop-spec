#!/usr/bin/env bash
# runtime-ignore.sh - Keep loop-spec and Graphify machine-local artifacts out of Git.
#
# Writes to the repository's common info/exclude file so consumer projects do not
# need a tracked .gitignore change and linked worktrees share one policy.
#
# Usage:
#   runtime-ignore.sh ensure <repo>
#   runtime-ignore.sh revise-state <repo> <slug>
set -euo pipefail

cmd="${1:-}"
repo="${2:-}"
[[ -n "$repo" ]] || {
  echo "usage: runtime-ignore.sh <ensure|revise-state> <repo> [slug]" >&2
  exit 2
}
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
  '/.loop-spec/active-run.json'
  '/.loop-spec/decisions-staging/'
  '/.loop-spec/last-result.json'
  '/.loop-spec/results/'
  '/.loop-spec/worktrees/'
  '/.loop-spec/learnings.jsonl'
  '/docs/loop-spec/telemetry/'
  '/.loop/'
  # Graphify output is a local, derived navigation cache. It is intentionally
  # excluded from feature branches: semantic updates can rewrite the whole graph
  # for a small source change, which makes a delivery PR unreviewable. Refresh it
  # after merge or from a dedicated maintenance checkout instead.
  '/graphify-out/'
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

case "$cmd" in
  ensure)
    [[ $# -eq 2 ]] || {
      echo "usage: runtime-ignore.sh ensure <repo>" >&2
      exit 2
    }
    ;;
  revise-state)
    slug="${3:-}"
    [[ $# -eq 3 && "$slug" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
      echo "usage: runtime-ignore.sh revise-state <repo> <safe-slug>" >&2
      exit 2
    }
    # /revise needs a feature-shaped runtime record to reuse EXECUTE, but that
    # record is operational state, not reviewable PR content. Ignore new state and
    # mark any historical tracked state skip-worktree in this checkout's index so
    # feature-write/event updates cannot be swept into a remediation commit.
    runtime_prefix=".loop-spec/features/$slug/"
    ensure_line "/$runtime_prefix"
    while IFS= read -r -d '' path; do
      git -C "$repo" update-index --skip-worktree -- "$path"
    done < <(git -C "$repo" ls-files -z -- "$runtime_prefix" 2>/dev/null || true)
    ;;
  *)
    echo "usage: runtime-ignore.sh <ensure|revise-state> <repo> [slug]" >&2
    exit 2
    ;;
esac
