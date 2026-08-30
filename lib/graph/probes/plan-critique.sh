#!/usr/bin/env bash
# Route probe: does the feature branch's changed-file set trip the house
# security/destructive-change signal? Wraps lib/security-signal.sh (a file
# scanner, not a route probe on its own) with the route-probe answer contract
# for graph/cycle.graph.json's plan.critique.gate.
#
# Usage:
#   plan-critique.sh --feature-dir DIR
#   plan-critique.sh --answers
#
# The change set is `git diff` between the feature's recorded base and HEAD
# (single-repo mode: feature.json.baseSha; workspace mode: each
# workspace.repos[].baseSha), excluding deletions -- there is nothing left to
# scan in a deleted file. Deleted-only changesets and empty diffs both resolve
# `signal=none`; they are a determined empty result, not a failure.
#
# Exit: 0 with one `signal=<value> reason=<text>` line on stdout when
# resolved; non-zero and silent when the change set itself cannot be
# determined -- a git/read failure must never read as `signal=none` (contract
# sec 2: unresolved is never satisfied; fail closed rather than silently skip
# the critique gate).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECURITY_SIGNAL="$SCRIPT_DIR/../../security-signal.sh"

usage() {
  echo "usage: plan-critique.sh --feature-dir DIR | --answers" >&2
  exit 2
}

if [[ "${1:-}" == "--answers" ]]; then
  printf 'signal=matched\nsignal=none\nsignal=compact\n'
  exit 0
fi

feature_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --feature-dir) feature_dir="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$feature_dir" ]] || usage

feature_json="$feature_dir/feature.json"
[[ -f "$feature_json" ]] || exit 1
[[ -x "$SECURITY_SIGNAL" ]] || exit 1

profile="$(jq -r '.executionProfile // "standard"' "$feature_json" 2>/dev/null)" || exit 1
if [[ "$profile" == "compact" ]]; then
  echo 'signal=compact reason=compact gate plan owns plan critique'
  exit 0
fi

# changed_files REPO_ROOT BASE_SHA -- prints repo-relative paths changed between
# BASE_SHA and HEAD, excluding deletions. Returns non-zero when the base SHA or
# the diff itself cannot be resolved, so a caller can tell "no files" (empty
# stdout, rc 0) apart from "could not determine" (rc != 0).
changed_files() {
  local repo_root="$1" base_sha="$2" out
  git -C "$repo_root" rev-parse --verify --quiet "${base_sha}^{commit}" >/dev/null 2>&1 || return 1
  out="$(git -C "$repo_root" diff --name-only --diff-filter=d "$base_sha" HEAD -- 2>/dev/null)" || return 1
  printf '%s\n' "$out"
}

files=()
workspace_root="$(jq -r '.workspace.root // empty' "$feature_json" 2>/dev/null)" || exit 1
if [[ -n "$workspace_root" ]]; then
  repo_entries="$(jq -c '.workspace.repos[]?' "$feature_json" 2>/dev/null)" || exit 1
  [[ -n "$repo_entries" ]] || exit 1
  while IFS= read -r repo_entry; do
    [[ -n "$repo_entry" ]] || continue
    rel_path="$(jq -r '.path' <<<"$repo_entry")"
    base_sha="$(jq -r '.baseSha' <<<"$repo_entry")"
    repo_dir="$workspace_root/$rel_path"
    [[ -n "$base_sha" && -d "$repo_dir" ]] || exit 1
    diff_out="$(changed_files "$repo_dir" "$base_sha")" || exit 1
    while IFS= read -r f; do
      [[ -n "$f" ]] && files+=("$repo_dir/$f")
    done <<<"$diff_out"
  done <<<"$repo_entries"
else
  base_sha="$(jq -r '.baseSha // empty' "$feature_json" 2>/dev/null)" || exit 1
  [[ -n "$base_sha" ]] || exit 1
  repo_root="$(git -C "$feature_dir" rev-parse --show-toplevel 2>/dev/null)" || exit 1
  diff_out="$(changed_files "$repo_root" "$base_sha")" || exit 1
  while IFS= read -r f; do
    [[ -n "$f" ]] && files+=("$repo_root/$f")
  done <<<"$diff_out"
fi

if [[ "${#files[@]}" -eq 0 ]]; then
  echo "signal=none reason=no files changed on the feature branch"
  exit 0
fi

output=""
rc=0
output="$(bash "$SECURITY_SIGNAL" first "${files[@]}" 2>/dev/null)" || rc=$?
case "$rc" in
  0) echo "signal=matched reason=${output}" ;;
  1) echo "signal=none reason=no security/destructive-change signal in ${#files[@]} changed file(s)" ;;
  *) exit 1 ;;
esac
