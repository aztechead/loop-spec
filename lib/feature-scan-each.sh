#!/usr/bin/env bash
# Run a per-repo git-diff scan for every target of a feature.
#
# VERIFY's marker and tamper gates take `--feature-dir`, not `{baseSha}` plus
# `{featureRepoRoot}`: those placeholders are a single SHA and a single git
# toplevel, and in workspace mode both are absent (baseSha lives per repo; the
# workspace root is not a git repository). Substituting them empty made the
# graph engine publish FAILED before either scan ran.
#
# Usage:
#   feature-scan-each.sh <scan-script> --feature-dir DIR
#
# Single-repo: one call with feature.json.baseSha and the git toplevel that
# holds DIR. Workspace: one call per workspace.repos[] with that repo's
# baseSha and absolute path. Never runs git at the workspace root.
#
# Exit codes match the scan: 0 all clean, 1 a scan found signals, 2 the
# feature could not be resolved into targets or a scan could not run.
set -euo pipefail

usage() {
  echo "usage: feature-scan-each.sh <scan-script> --feature-dir DIR" >&2
  exit 2
}

scan="${1:-}"
[[ -n "$scan" && -f "$scan" ]] || usage
shift
[[ "${1:-}" == "--feature-dir" && -n "${2:-}" && $# -eq 2 ]] || usage
feature_dir="$2"
[[ -f "$feature_dir/feature.json" ]] || {
  echo "feature-scan-each: feature.json not found in $feature_dir" >&2
  exit 2
}
feature_dir="$(cd "$feature_dir" && pwd)"
feature_json="$feature_dir/feature.json"

# JSONL of {name,path,baseSha}. Diagnostics on stderr; empty stdout is not a
# successful empty set — a feature with no scan targets is unresolved.
emit_targets() {
  local ws_type workspace_root n name rel_path base_sha repo_dir slug repo_root
  ws_type="$(jq -r '.workspace | type' "$feature_json" 2>/dev/null)" || return 1
  if [[ "$ws_type" == "object" ]]; then
    workspace_root="$(jq -r '.workspace.root // empty' "$feature_json")" || return 1
    [[ -n "$workspace_root" && -d "$workspace_root" ]] || {
      echo "feature-scan-each: workspace.root is missing or not a directory" >&2
      return 1
    }
    workspace_root="$(cd "$workspace_root" && pwd)"
    n="$(jq '.workspace.repos | length' "$feature_json" 2>/dev/null)" || return 1
    [[ "$n" -gt 0 ]] || {
      echo "feature-scan-each: workspace.repos is empty" >&2
      return 1
    }
    while IFS= read -r repo; do
      [[ -n "$repo" ]] || continue
      name="$(jq -r '.name // empty' <<<"$repo")"
      rel_path="$(jq -r '.path // empty' <<<"$repo")"
      base_sha="$(jq -r '.baseSha // empty' <<<"$repo")"
      [[ -n "$name" && -n "$rel_path" && -n "$base_sha" ]] || {
        echo "feature-scan-each: workspace repo is missing name, path, or baseSha" >&2
        return 1
      }
      repo_dir="${workspace_root%/}/${rel_path}"
      git -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
        echo "feature-scan-each: $name is not a git repo: $repo_dir" >&2
        return 1
      }
      jq -nc --arg name "$name" --arg path "$repo_dir" --arg sha "$base_sha" \
        '{name:$name,path:$path,baseSha:$sha}'
    done < <(jq -c '.workspace.repos[]' "$feature_json")
    return 0
  fi
  slug="$(jq -r '.slug // empty' "$feature_json")"
  base_sha="$(jq -r '.baseSha // empty' "$feature_json")"
  [[ -n "$base_sha" ]] || {
    echo "feature-scan-each: feature.json has no baseSha" >&2
    return 1
  }
  repo_root="$(git -C "$feature_dir" rev-parse --show-toplevel 2>/dev/null)" || {
    echo "feature-scan-each: feature directory is not inside a git work tree" >&2
    return 1
  }
  jq -nc --arg name "${slug:-feature}" --arg path "$repo_root" --arg sha "$base_sha" \
    '{name:$name,path:$path,baseSha:$sha}'
}

targets="$(emit_targets)" || exit 2
[[ -n "$targets" ]] || {
  echo "feature-scan-each: no scan targets" >&2
  exit 2
}

target_count="$(printf '%s\n' "$targets" | grep -c .)"
overall=0
while IFS= read -r target; do
  [[ -n "$target" ]] || continue
  name="$(jq -r '.name' <<<"$target")"
  path="$(jq -r '.path' <<<"$target")"
  base_sha="$(jq -r '.baseSha' <<<"$target")"
  rc=0
  out="$(bash "$scan" "$base_sha" "$path" 2>&1)" || rc=$?
  if [[ "$target_count" -gt 1 && -n "$out" ]]; then
    printf '%s\n' "$out" | sed "s|^|${name}: |"
  elif [[ -n "$out" ]]; then
    printf '%s\n' "$out"
  fi
  case "$rc" in
    0) ;;
    1) overall=1 ;;
    *)
      echo "feature-scan-each: $name could not be scanned (exit $rc)" >&2
      exit 2
      ;;
  esac
done <<<"$targets"

exit "$overall"
