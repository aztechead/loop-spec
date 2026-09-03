#!/usr/bin/env bash
# store-mirror.sh - State-store adapter that mirrors each feature directory to a path.
#
# For a supervisor whose durable storage is a mounted volume: LOOP_SPEC_STORE_DIR
# names it. persist copies the whole feature directory there; open restores it when
# the checkout lacks the working copy (a fresh container resuming a run). The copy
# lands under a temporary name and is renamed into place, so a death mid-copy leaves
# the previous mirror intact.
#
# Usage:
#   LOOP_SPEC_STORE=lib/supervisor/store-mirror.sh LOOP_SPEC_STORE_DIR=/mnt/runs ...
#   store-mirror.sh open <feature-dir>
#   store-mirror.sh persist <feature-dir> <reason>
#   store-mirror.sh list [<project-root>]
#   store-mirror.sh describe
#
# Exit codes: 0 done, 1 open found the slug in neither place, 2 bad invocation or
# LOOP_SPEC_STORE_DIR unset, unwritable, or a copy that failed.
set -euo pipefail

usage() { echo "usage: store-mirror.sh open <feature-dir> | persist <feature-dir> <reason> | list | describe" >&2; exit 2; }

mirror="${LOOP_SPEC_STORE_DIR:-}"
[[ -n "$mirror" ]] || { echo "store-mirror: LOOP_SPEC_STORE_DIR is unset; name the directory to mirror into" >&2; exit 2; }

# copy_dir SRC DST: replace DST with a copy of SRC, keeping the old DST until the
# new one is complete.
copy_dir() {
  local src="$1" dst="$2" tmp="$2.tmp.$$" old="$2.old.$$"
  rm -rf "$tmp"
  cp -R "$src" "$tmp" || { rm -rf "$tmp"; echo "store-mirror: copy of $src to $dst failed" >&2; return 2; }
  if [[ -d "$dst" ]]; then mv "$dst" "$old"; fi
  mv "$tmp" "$dst" || { echo "store-mirror: cannot rename $tmp into place" >&2; return 2; }
  rm -rf "$old"
}

case "${1:-}" in
  open)
    [[ $# -eq 2 && -n "$2" ]] || usage
    feature_dir="$2"; slug="$(basename "$feature_dir")"
    if [[ -f "$feature_dir/feature.json" ]]; then
      printf 'opened=%s source=working-copy\n' "$slug"
    elif [[ -f "$mirror/$slug/feature.json" ]]; then
      mkdir -p "$(dirname "$feature_dir")"
      copy_dir "$mirror/$slug" "$feature_dir"
      printf 'opened=%s source=mirror\n' "$slug"
    else
      echo "store-mirror: $slug is in neither $feature_dir nor $mirror" >&2
      exit 1
    fi
    ;;
  persist)
    [[ $# -eq 3 && -n "$2" && -n "$3" ]] || usage
    feature_dir="$2"; slug="$(basename "$feature_dir")"
    [[ -d "$feature_dir" ]] || { echo "store-mirror: nothing to persist; $feature_dir is not a directory" >&2; exit 2; }
    mkdir -p "$mirror" 2>/dev/null && [[ -w "$mirror" ]] \
      || { echo "store-mirror: LOOP_SPEC_STORE_DIR=$mirror is not a writable directory" >&2; exit 2; }
    copy_dir "$feature_dir" "$mirror/$slug"
    printf 'persisted=%s store=mirror reason=%s\n' "$slug" "$3"
    ;;
  list)
    # The project root the port passes is the checkout's; the mirror lists itself.
    [[ $# -le 2 ]] || usage
    for d in "$mirror"/*/; do
      [[ -f "$d/feature.json" ]] || continue
      basename "$d"
    done
    ;;
  describe)
    [[ $# -eq 1 ]] || usage
    echo "store=mirror reason=dir:$mirror"
    ;;
  *) usage ;;
esac
