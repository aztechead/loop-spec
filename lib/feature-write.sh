#!/usr/bin/env bash
# Atomic write of .loop-spec/features/{slug}/feature.json with .bak rotation.
#
# Usage:
#   bash lib/feature-write.sh <feature_dir> <feature_json_string>
#   bash lib/feature-write.sh set <feature_dir> <dot_path> <value_json>
#   bash lib/feature-write.sh append <feature_dir> <dot_path> <value_json>
#
# Contract:
#   - Writes to feature.json.tmp first, fsyncs, rotates current feature.json -> feature.json.bak,
#     then renames .tmp -> feature.json. On any failure mid-rotation, .bak is the recovery point.
#   - Validates the input is parseable JSON (jq -e .) before doing any write.
#   - Refuses to operate if feature_dir does not already exist (caller must mkdir).
#
# Exit codes:
#   0 success
#   1 bad invocation (wrong arg count, missing dir, invalid JSON)
#   2 io failure during write/rotate
set -euo pipefail

# Subcommand dispatch: set/append for targeted key mutation
if [[ "$1" == "set" || "$1" == "append" ]]; then
  if [[ $# -ne 4 ]]; then
    echo "usage: feature-write.sh set|append <feature_dir> <dot_path> <value_json>" >&2
    exit 1
  fi
  subcmd="$1"; feat_dir="$2"; dot_path="$3"; val_json="$4"
  if [[ ! -f "$feat_dir/feature.json" ]]; then
    echo "feature-write: feature.json not found in $feat_dir" >&2; exit 1
  fi
  # Reject path segments that contain anything other than alnum/underscore. The prior
  # implementation interpolated $dot_path directly into the jq filter string, which let a
  # caller-controlled value execute arbitrary jq (or corrupt the file via a parse error).
  # We split on `.` and validate each segment, then pass the segments to jq via --argjson
  # so the path is built inside jq with getpath/setpath rather than via string concatenation.
  if [[ ! "$dot_path" =~ ^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$ ]]; then
    echo "feature-write: invalid dot_path (must be alnum/underscore segments separated by .): $dot_path" >&2
    exit 1
  fi
  path_json=$(printf '%s' "$dot_path" | jq -R 'split(".")')
  if [[ "$subcmd" == "set" ]]; then
    new_json=$(jq --argjson p "$path_json" --argjson v "$val_json" 'setpath($p; $v)' "$feat_dir/feature.json")
  else
    # Assert existing value at path is null (treated as empty array) or an array.
    # Without this guard, `(getpath($p) // []) + [$v]` would silently overwrite a string/
    # object/number at the path with `[$v]`, masking caller bugs that the prior `+=` form
    # would have surfaced as a jq error.
    new_json=$(jq --argjson p "$path_json" --argjson v "$val_json" '
      (getpath($p)) as $cur
      | if ($cur == null) then setpath($p; [$v])
        elif ($cur | type) == "array" then setpath($p; $cur + [$v])
        else error("feature-write: append target at path is not an array (type: \($cur | type))")
        end
    ' "$feat_dir/feature.json")
  fi
  exec "$0" "$feat_dir" "$new_json"
fi

if [[ $# -ne 2 ]]; then
  echo "usage: feature-write.sh <feature_dir> <feature_json_string>" >&2
  exit 1
fi

feature_dir="$1"
feature_json="$2"

if [[ ! -d "$feature_dir" ]]; then
  echo "feature-write: feature_dir does not exist: $feature_dir" >&2
  exit 1
fi

if ! printf '%s' "$feature_json" | jq -e . >/dev/null 2>&1; then
  echo "feature-write: invalid JSON input" >&2
  exit 1
fi

tmp="$feature_dir/feature.json.tmp"
final="$feature_dir/feature.json"
bak="$feature_dir/feature.json.bak"

{
  printf '%s\n' "$feature_json" > "$tmp"
  sync
  if [[ -f "$final" ]]; then
    mv "$final" "$bak"
  fi
  mv "$tmp" "$final"
} || {
  echo "feature-write: io failure" >&2
  exit 2
}

exit 0
