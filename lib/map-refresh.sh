#!/usr/bin/env bash
# Decide whether an incremental codebase-map refresh has work to do.
#
# The map skill used to invoke an expensive external graph build before learning
# whether the codebase index named any stale domain. This helper owns that
# decision so the phase can bypass only proven no-op work; it never bypasses a
# missing/corrupt map or an unknown source change.
#
# Usage:
#   map-refresh.sh decide <repo> <base-sha> [--mode incremental|full]
#                         [--domains tech,arch,quality,concerns,domain]
#
# stdout: one JSON object
#   {refresh:true|false, reason:<stable string>, domains:[...], changedFiles:[...]}
#
# Exit codes: 0 decision emitted, 2 bad invocation/repository state.
set -euo pipefail

ALL_DOMAINS='["tech","arch","quality","concerns","domain"]'

usage() {
  echo "usage: map-refresh.sh decide <repo> <base-sha> [--mode incremental|full] [--domains csv]" >&2
  exit 2
}

[[ "${1:-}" == "decide" && -n "${2:-}" && -n "${3:-}" ]] || usage
repo="${2%/}"
base_sha="$3"
shift 3
mode="incremental"
domains_csv=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) mode="${2:-}"; shift 2 || usage ;;
    --domains) domains_csv="${2:-}"; shift 2 || usage ;;
    *) usage ;;
  esac
done
[[ "$mode" == "incremental" || "$mode" == "full" ]] || usage
[[ -d "$repo" ]] || { echo "map-refresh: repository not found: $repo" >&2; exit 2; }
repo="$(cd "$repo" && pwd -P)"
git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "map-refresh: not a git worktree: $repo" >&2
  exit 2
}

emit() {
  local refresh="$1" reason="$2" domains="$3" changed="$4"
  jq -cn --argjson refresh "$refresh" --arg reason "$reason" \
    --argjson domains "$domains" --argjson changed "$changed" \
    '{schema:1,refresh:$refresh,reason:$reason,domains:$domains,changedFiles:$changed}'
}

normalize_domains() {
  local raw="$1"
  jq -cn --arg raw "$raw" '
    $raw | split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "")) |
    map(select(length > 0)) | unique |
    if all(.[]; . == "tech" or . == "arch" or . == "quality" or . == "concerns" or . == "domain")
    then . else error("invalid domain") end
  '
}

index="$repo/.loop-spec/codebase/index.json"
map_complete=true
for map_doc in TECH.md ARCH.md QUALITY.md CONCERNS.md DOMAIN.md; do
  [[ -s "$repo/docs/loop-spec/codebase/$map_doc" ]] || map_complete=false
done
jq -e '.files | type == "object"' "$index" >/dev/null 2>&1 || map_complete=false

if [[ -n "$domains_csv" ]]; then
  explicit_domains="$(normalize_domains "$domains_csv")" || {
    echo "map-refresh: --domains must contain only tech,arch,quality,concerns,domain" >&2
    exit 2
  }
  [[ "$(jq 'length' <<<"$explicit_domains")" -gt 0 ]] || {
    echo "map-refresh: --domains cannot be empty" >&2
    exit 2
  }
  emit true explicit-domains "$explicit_domains" '[]'
  exit 0
fi

if [[ "$mode" == "full" ]]; then
  emit true full-request "$ALL_DOMAINS" '[]'
  exit 0
fi

# A partial corpus is not a cache hit: produce every domain before allowing an
# incremental no-op. This preserves first-run artifact creation.
if [[ "$map_complete" != true ]]; then
  emit true map-artifacts-incomplete "$ALL_DOMAINS" '[]'
  exit 0
fi

if ! git -C "$repo" rev-parse --verify "${base_sha}^{commit}" >/dev/null 2>&1; then
  # The old inline flow's fallback on an unreadable index was an ARCH refresh;
  # a missing baseline is broader uncertainty, so fail closed to the full map.
  emit true base-unavailable "$ALL_DOMAINS" '[]'
  exit 0
fi

changed='[]'
is_runtime_artifact() {
  case "$1" in
    .loop-spec/*|docs/loop-spec/features/*|docs/loop-spec/telemetry/*|docs/loop-spec/codebase/*|graphify-out/*)
      return 0 ;;
    *) return 1 ;;
  esac
}
while IFS= read -r -d '' path; do
  is_runtime_artifact "$path" && continue
  changed="$(jq -cn --argjson prior "$changed" --arg path "$path" '$prior + [$path]')"
done < <(git -C "$repo" diff --name-only -z "$base_sha" HEAD)

if [[ "$(jq 'length' <<<"$changed")" -eq 0 ]]; then
  emit false no-map-relevant-changes '[]' "$changed"
  exit 0
fi

domains="$(jq -cn --argjson changed "$changed" --slurpfile index "$index" '
  $index[0].files as $files |
  [$changed[] as $path | ($files[$path] // [])[]] | unique
')"

# A new source file has no index entry yet. It must at least refresh architecture
# (the documented conservative default) instead of being silently unmapped.
unknown_count="$(jq -n --argjson changed "$changed" --slurpfile index "$index" '
  $index[0].files as $files |
  [$changed[] | ($files[.] // null) as $mapped
   | select(($mapped | type) != "array" or ($mapped | length) == 0)] | length
')"
if [[ "$unknown_count" -gt 0 ]]; then
  domains="$(jq -cn --argjson prior "$domains" '$prior + ["arch"] | unique')"
fi

if [[ "$(jq 'length' <<<"$domains")" -eq 0 ]]; then
  emit false changed-paths-unmapped '[]' "$changed"
else
  emit true changed-domains "$domains" "$changed"
fi
