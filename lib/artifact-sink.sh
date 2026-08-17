#!/usr/bin/env bash
# Preserve feature documents outside the delivery branch when explicitly requested.
set -euo pipefail

[[ "${1:-}" == "store" && -n "${2:-}" && -n "${3:-}" && $# -eq 3 ]] || {
  echo "usage: artifact-sink.sh store <feature_dir> <repo_root>" >&2
  exit 2
}
case "${LOOP_SPEC_ARTIFACTS_IN_PR:-1}" in
  1) echo "inline"; exit 0 ;;
  0) ;;
  *) echo "artifact-sink.sh: LOOP_SPEC_ARTIFACTS_IN_PR must be 0 or 1" >&2; exit 2 ;;
esac

feature_dir="$(cd "$2" && pwd -P)"
repo_root="$(cd "$3" && pwd -P)"
feature_json="$feature_dir/feature.json"
[[ -f "$feature_json" ]] || {
  echo "artifact-sink.sh: feature.json not found" >&2
  exit 2
}
[[ ! -L "$feature_json" ]] || {
  echo "artifact-sink.sh: refusing a symlinked feature.json" >&2
  exit 2
}
case "$feature_dir/" in "$repo_root/"*) ;; *)
  echo "artifact-sink.sh: feature directory is outside the repository" >&2; exit 2;; esac

slug="$(jq -er '.slug | select(type == "string" and test("^[a-z0-9][a-z0-9._-]*$"))' \
  "$feature_json" 2>/dev/null)" || {
  echo "artifact-sink.sh: feature slug is missing or unsafe" >&2
  exit 2
}
base_sha="$(jq -r '.baseSha // ""' "$feature_json")"
head_sha="$(git -C "$repo_root" rev-parse --verify HEAD)"
[[ -n "$base_sha" ]] && git -C "$repo_root" rev-parse --verify "${base_sha}^{commit}" >/dev/null 2>&1 || {
  echo "artifact-sink.sh: recorded base SHA is unavailable" >&2
  exit 2
}

sink_root="${LOOP_SPEC_ARTIFACT_DIR:-}"
if [[ -z "$sink_root" ]]; then
  sink_root="$(git -C "$repo_root" rev-parse --git-path loop-spec/artifacts)"
fi
[[ "$sink_root" == /* ]] || sink_root="$repo_root/$sink_root"
[[ ! -L "$sink_root" ]] || {
  echo "artifact-sink.sh: refusing a symlinked artifact store" >&2
  exit 2
}
sink_root="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$sink_root")"
git_common="$(git -C "$repo_root" rev-parse --git-common-dir)"
[[ "$git_common" == /* ]] || git_common="$repo_root/$git_common"
git_common="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$git_common")"
case "$sink_root/" in
  "$repo_root/"*)
    case "$sink_root/" in "$git_common/"*) ;; *)
      echo "artifact-sink.sh: artifact store must be outside the working tree or inside Git private storage" >&2
      exit 2;; esac
    ;;
esac
mkdir -p "$sink_root"
destination="$sink_root/$slug/$head_sha"
reuse=0
if [[ -e "$destination" ]]; then
  if [[ -f "$destination/manifest.json" ]] \
     && jq -e --arg slug "$slug" --arg head "$head_sha" \
       '.slug == $slug and .sourceHead == $head and .artifactsInPr == false' \
       "$destination/manifest.json" >/dev/null 2>&1; then
    reuse=1
  else
    echo "artifact-sink.sh: destination exists without a matching manifest: $destination" >&2
    exit 2
  fi
else
  mkdir -p "$destination"
fi

docs_rel="docs/loop-spec/features/$slug"
docs_source="$repo_root/$docs_rel"
[[ ! -L "$docs_source" ]] || {
  echo "artifact-sink.sh: refusing a symlinked feature-document directory" >&2
  exit 2
}
if [[ -d "$docs_source" && "$reuse" -eq 0 ]]; then
  cp -R "$docs_source" "$destination/artifacts"
fi

metadata="$(jq -cn --arg manifest "$slug/$head_sha/manifest.json" \
  '{mode:"store",manifest:$manifest}')"
tmp_json="$(mktemp "$feature_dir/.artifact-sink.XXXXXX")"
trap 'rm -f "$tmp_json"' EXIT
jq --argjson metadata "$metadata" '.artifactSink = $metadata' "$feature_json" > "$tmp_json"
mv "$tmp_json" "$feature_json"
trap - EXIT
rm -rf "$destination/state"
cp -R "$feature_dir" "$destination/state"
if [[ "$reuse" -eq 0 ]]; then
  jq -n --arg slug "$slug" --arg baseSha "$base_sha" --arg sourceHead "$head_sha" \
    --arg createdAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{schema:1,slug:$slug,baseSha:$baseSha,sourceHead:$sourceHead,createdAt:$createdAt,
      artifactsInPr:false}' > "$destination/manifest.json"
fi

# The store now has a recoverable copy. Restore the base image of this exact
# feature-document directory, which removes additions and preserves any baseline files.
git -C "$repo_root" rm -r -f --ignore-unmatch -- "$docs_rel" >/dev/null 2>&1
rm -rf "$docs_source"
if [[ -n "$(git -C "$repo_root" ls-tree -r --name-only "$base_sha" -- "$docs_rel")" ]]; then
  git -C "$repo_root" restore --source "$base_sha" --staged --worktree -- "$docs_rel"
fi

printf 'stored:%s\n' "$destination"
