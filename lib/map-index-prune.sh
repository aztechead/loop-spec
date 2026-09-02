#!/usr/bin/env bash
# map-index-prune.sh - Drop map-index entries whose file no longer exists.
#
# Why: skills/map-codebase updates the index by adding domains to a file's
# entry, so without pruning the index only ever grows and a deleted source
# file keeps voting on which domains are stale forever (F3 in
# the map trust contract, lib/map-trust.sh). The map skill used to carry this as
# an instruction; an instruction is followed on a good day, a script every day.
#
# `lib/map-audit.sh orphans` DETECTS these entries and never rewrites; this is
# the paired repair, and the only edit it makes is removal of keys whose path
# is verifiably absent from the tree.
#
# Usage:
#   map-index-prune.sh
#
# Reads $LOOP_SPEC_MAP_INDEX (default .loop-spec/codebase/index.json).
#
# Exit codes:
#   0  pruned (possibly zero entries), or no index to prune
#   2  index exists but is not valid JSON -- rewriting it would destroy it
set -euo pipefail

[[ $# -eq 0 ]] || { echo "usage: map-index-prune.sh" >&2; exit 2; }

index="${LOOP_SPEC_MAP_INDEX:-.loop-spec/codebase/index.json}"

if [[ ! -f "$index" ]]; then
  echo "pruned=0 kept=0 reason=$index does not exist"
  exit 0
fi

jq -e . "$index" >/dev/null 2>&1 || {
  echo "map-index-prune: $index is not valid JSON; refusing to rewrite it" >&2
  exit 2
}

gone='[]'
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  [[ -e "$path" ]] || gone="$(jq -cn --argjson acc "$gone" --arg path "$path" '$acc + [$path]')"
done < <(jq -r '(.files // {}) | keys[]' "$index")

kept="$(jq -r --argjson gone "$gone" '((.files // {}) | length) - ($gone | length)' "$index")"

if [[ "$(jq -r 'length' <<<"$gone")" -eq 0 ]]; then
  echo "pruned=0 kept=$kept reason=every indexed file exists"
  exit 0
fi

while IFS=$'\t' read -r path domains; do
  echo "pruned path=$path domains=$domains reason=file no longer exists"
done < <(jq -r --argjson gone "$gone" '
  .files as $files
  | $gone[]
  | [., ($files[.] | if type == "array" then join(",") else tostring end)]
  | @tsv' "$index")

tmp="$(mktemp "$(dirname "$index")/.map-index-prune.XXXXXX")"
jq --argjson gone "$gone" '.files |= (with_entries(select(.key as $k | $gone | index($k) | not)))' \
  "$index" > "$tmp" || { rm -f "$tmp"; echo "map-index-prune: rewrite failed" >&2; exit 2; }
mv "$tmp" "$index"

echo "pruned=$(jq -r 'length' <<<"$gone") kept=$kept reason=$index"
