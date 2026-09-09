#!/usr/bin/env bash
# state-ref.sh - Feature state on its own ref, never on the feature branch.
#
# Why: the driver committed feature.json and PROGRESS.md to feat/<slug> at every phase
# transition and negated two paths in the project's .gitignore to do it. Ten of the
# seventeen commits on a delivered branch were state commits, and they landed in the
# PR (docs/loop-spec/orchestrator-port-plan.md, defects 3 and 4). State still has to
# outlive a worktree: this keeps every top-level file of the feature directory in a
# commit chain under refs/loop-spec/state/<slug>, which every worktree of the
# repository shares and a checkpoint push carries to the remote.
#
# Usage:
#   state-ref.sh commit  <feature-dir> <message>
#       Snapshot the feature directory's top-level files (feature.json, PROGRESS.md,
#       decisions.jsonl, ...; never subdirectories) onto the ref. Prints the commit
#       sha; an unchanged tree prints the current sha and writes nothing.
#   state-ref.sh restore <repo> <slug> [<feature-dir>]
#       Write the ref's files into <feature-dir> (default <repo>/.loop-spec/features/<slug>),
#       creating it. Prints the restored sha.
#   state-ref.sh show    <repo> <slug> [<path>]
#       Print one file from the ref (default feature.json).
#   state-ref.sh ref     <slug>
#       Print the ref name.
#
# Exit codes: 0 done; 1 no such ref or no state to snapshot; 2 bad invocation.
set -euo pipefail

usage() {
  echo "usage: state-ref.sh commit <feature-dir> <message> | restore <repo> <slug> [<feature-dir>] | show <repo> <slug> [<path>] | ref <slug>" >&2
  exit 2
}

cmd="${1:-}"; shift || true
case "$cmd" in
  ref)
    [[ $# -eq 1 && -n "$1" ]] || usage
    echo "refs/loop-spec/state/$1"
    ;;
  commit)
    [[ $# -eq 2 && -n "$1" && -n "$2" ]] || usage
    feature_dir="$(cd "$1" && pwd -P)"; message="$2"
    [[ -f "$feature_dir/feature.json" ]] || { echo "state-ref: no feature.json in $feature_dir" >&2; exit 1; }
    slug="$(jq -r '.slug // ""' "$feature_dir/feature.json")"
    [[ -n "$slug" ]] || { echo "state-ref: feature.json names no slug" >&2; exit 1; }
    root="$(git -C "$feature_dir" rev-parse --show-toplevel)"
    ref="refs/loop-spec/state/$slug"
    index="$(mktemp "${TMPDIR:-/tmp}/state-ref-index.XXXXXX")"
    trap 'rm -f "$index"' EXIT
    rm -f "$index"
    # A fresh index holds only the snapshot; the checkout's own index is never touched.
    count=0
    for path in "$feature_dir"/*; do
      [[ -f "$path" ]] || continue
      blob="$(git -C "$root" hash-object -w "$path")"
      GIT_INDEX_FILE="$index" git -C "$root" update-index --add --cacheinfo "100644,$blob,$(basename "$path")"
      count=$((count + 1))
    done
    (( count > 0 )) || { echo "state-ref: nothing to snapshot in $feature_dir" >&2; exit 1; }
    tree="$(GIT_INDEX_FILE="$index" git -C "$root" write-tree)"
    parent="$(git -C "$root" rev-parse -q --verify "$ref^{commit}" 2>/dev/null || true)"
    if [[ -n "$parent" && "$(git -C "$root" rev-parse "$parent^{tree}")" == "$tree" ]]; then
      echo "$parent"; exit 0
    fi
    if [[ -n "$parent" ]]; then
      commit="$(git -C "$root" commit-tree "$tree" -p "$parent" -m "$message")"
      git -C "$root" update-ref "$ref" "$commit" "$parent"
    else
      commit="$(git -C "$root" commit-tree "$tree" -m "$message")"
      git -C "$root" update-ref "$ref" "$commit"
    fi
    echo "$commit"
    ;;
  restore)
    [[ $# -ge 2 && $# -le 3 && -n "$1" && -n "$2" ]] || usage
    repo="$1"; slug="$2"; feature_dir="${3:-$1/.loop-spec/features/$2}"
    ref="refs/loop-spec/state/$slug"
    sha="$(git -C "$repo" rev-parse -q --verify "$ref^{commit}" 2>/dev/null)" \
      || { echo "state-ref: no state ref for $slug ($ref)" >&2; exit 1; }
    mkdir -p "$feature_dir"
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      git -C "$repo" cat-file -p "$ref:$name" > "$feature_dir/$name"
    done < <(git -C "$repo" ls-tree --name-only "$ref")
    echo "$sha"
    ;;
  show)
    [[ $# -ge 2 && $# -le 3 && -n "$1" && -n "$2" ]] || usage
    git -C "$1" cat-file -p "refs/loop-spec/state/$2:${3:-feature.json}" 2>/dev/null \
      || { echo "state-ref: no ${3:-feature.json} on refs/loop-spec/state/$2" >&2; exit 1; }
    ;;
  *) usage ;;
esac
