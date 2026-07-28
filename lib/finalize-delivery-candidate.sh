#!/usr/bin/env bash
# Finalize deterministic, tracked artifacts before DELIVER binds an exact HEAD.
#
# Usage:
#   finalize-delivery-candidate.sh bound-sha <delivery.json> <target-name>
#   finalize-delivery-candidate.sh run <feature_dir> [--commit]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

binding_query='def local_error: ["repo_invalid","repo_root_mismatch","branch_mismatch","git_status_failed",
  "dirty_worktree","base_sha_missing","base_sha_invalid","base_not_ancestor","no_commits",
  "git_history_failed","local_artifact_policy_failed"];
  [.targets[]? | select(.name == $name and (.targetSha // "") != "") as $target
   | select($target.bindingEligible == true or
       (($target | has("bindingEligible") | not) and
        ((local_error | index($target.errorCode // "")) == null)))
   | .targetSha] | first // empty'

bound_sha() {
  local delivery_file="$1" name="$2" next sha
  [[ -f "$delivery_file" ]] || return 1
  jq -e 'type == "object"' "$delivery_file" >/dev/null 2>&1 || return 2
  next="$(jq -r '.nextPhase // ""' "$delivery_file")" || return 2
  [[ "$next" == "deliver" || "$next" == "completed" ]] || return 1
  sha="$(jq -r --arg name "$name" "$binding_query" "$delivery_file")" || return 2
  [[ -n "$sha" ]] || return 1
  printf '%s\n' "$sha"
}

case "${1:-}" in
  bound-sha)
    [[ -n "${2:-}" && -n "${3:-}" ]] || {
      echo "usage: finalize-delivery-candidate.sh bound-sha <delivery.json> <target-name>" >&2
      exit 2
    }
    bound_sha "$2" "$3"
    exit $?
    ;;
  run) ;;
  *)
    echo "usage: finalize-delivery-candidate.sh {bound-sha <delivery.json> <target-name>|run <feature_dir> [--commit]}" >&2
    exit 2
    ;;
esac

feature_dir="${2:-}"
commit_requested=0
[[ "${3:-}" == "--commit" ]] && commit_requested=1
[[ -n "$feature_dir" && -f "$feature_dir/feature.json" ]] || {
  echo "finalize-delivery-candidate: feature.json not found in ${feature_dir:-<empty>}" >&2
  exit 2
}
[[ $# -le 3 && ( $# -lt 3 || "${3:-}" == "--commit" ) ]] || {
  echo "usage: finalize-delivery-candidate.sh run <feature_dir> [--commit]" >&2
  exit 2
}

feature_dir="$(cd "$feature_dir" && pwd -P)" || exit 2
feature_json="$feature_dir/feature.json"
jq -e '.schemaVersion == 7 and .currentPhase == "deliver"' "$feature_json" >/dev/null 2>&1 || {
  echo "finalize-delivery-candidate: feature must be schema 7 at currentPhase=deliver" >&2
  exit 2
}

# Workspace delivery has no single candidate branch at the feature root.
if jq -e '.workspace != null' "$feature_json" >/dev/null 2>&1; then
  exit 0
fi

slug="$(jq -er '.slug | select(type == "string" and length > 0)' "$feature_json" 2>/dev/null)" || {
  echo "finalize-delivery-candidate: feature slug is missing" >&2
  exit 2
}
delivery_file="$feature_dir/delivery.json"
bound=""
bound_rc=0
bound="$(bound_sha "$delivery_file" "$slug")" || bound_rc=$?
if [[ "$bound_rc" -eq 0 ]]; then
  # Exact-SHA retries and completion recovery are observation-only. In particular,
  # do not even refresh info/exclude after a candidate has been bound.
  exit 0
elif [[ "$bound_rc" -ne 1 ]]; then
  echo "finalize-delivery-candidate: cannot read prior delivery binding" >&2
  exit 2
fi

repo_root="$(git -C "$feature_dir" rev-parse --show-toplevel 2>/dev/null)" || {
  echo "finalize-delivery-candidate: feature directory is not in a git work tree" >&2
  exit 2
}
repo_root="$(cd "$repo_root" && pwd -P)" || exit 2
expected_branch="$(jq -r '.branch // ""' "$feature_json")"
actual_branch="$(git -C "$repo_root" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
base_sha="$(jq -r '.baseSha // ""' "$feature_json")"
head_sha="$(git -C "$repo_root" rev-parse --verify HEAD 2>/dev/null || true)"
if [[ -z "$expected_branch" || "$actual_branch" != "$expected_branch" ]]; then
  echo "finalize-delivery-candidate: checkout is not on the recorded feature branch" >&2
  exit 1
elif [[ -z "$base_sha" ]] || ! git -C "$repo_root" rev-parse --verify "${base_sha}^{commit}" >/dev/null 2>&1; then
  echo "finalize-delivery-candidate: recorded base SHA is unavailable" >&2
  exit 1
elif [[ -z "$head_sha" ]] || ! git -C "$repo_root" merge-base --is-ancestor "$base_sha" "$head_sha"; then
  echo "finalize-delivery-candidate: recorded base is not an ancestor of HEAD" >&2
  exit 1
elif [[ "$(git -C "$repo_root" rev-list --count "${base_sha}..${head_sha}" 2>/dev/null || echo 0)" -eq 0 ]]; then
  echo "finalize-delivery-candidate: feature branch has no commits past its base" >&2
  exit 1
fi

bash "$SCRIPT_DIR/runtime-ignore.sh" ensure "$repo_root" >/dev/null || {
  echo "finalize-delivery-candidate: failed to install runtime ignores" >&2
  exit 2
}

initial_status="$(git -C "$repo_root" status --porcelain --untracked-files=all 2>/dev/null)" || {
  echo "finalize-delivery-candidate: cannot establish candidate cleanliness" >&2
  exit 2
}
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  path="${line:3}"
  case "$path" in
    ".gitignore")
      bash "$SCRIPT_DIR/owned-gitignore.sh" check "$repo_root" || {
        echo "finalize-delivery-candidate: pre-existing .gitignore change is not loop-spec-owned" >&2
        exit 1
      }
      ;;
    *)
      echo "finalize-delivery-candidate: unexpected pre-existing worktree change: $path" >&2
      exit 1
      ;;
  esac
done <<<"$initial_status"

CLAUDE_PROJECT_DIR="$repo_root" bash "$SCRIPT_DIR/retro.sh" auto "$feature_dir" >/dev/null || {
  echo "finalize-delivery-candidate: retrospective finalization failed" >&2
  exit 2
}
bash "$SCRIPT_DIR/run-digest.sh" append "$feature_dir" --candidate >/dev/null || {
  echo "finalize-delivery-candidate: run digest finalization failed" >&2
  exit 2
}

rules_path=".loop-spec/RULES.md"
ignore_path=".gitignore"
digest_path="docs/loop-spec/telemetry/runs/$slug.json"
if ! jq -e --arg slug "$slug" '.slug == $slug and .status == "completed"' \
    "$repo_root/$digest_path" >/dev/null 2>&1; then
  echo "finalize-delivery-candidate: candidate run digest was not produced" >&2
  exit 2
fi

status="$(git -C "$repo_root" status --porcelain --untracked-files=all 2>/dev/null)" || {
  echo "finalize-delivery-candidate: cannot inspect finalized artifacts" >&2
  exit 2
}
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  path="${line:3}"
  case "$path" in
    "$rules_path"|"$ignore_path"|"$digest_path") ;;
    *)
      echo "finalize-delivery-candidate: unexpected generated change: $path" >&2
      exit 1
      ;;
  esac
done <<<"$status"

if [[ "$commit_requested" -eq 1 ]]; then
  stage_paths=()
  for path in "$rules_path" "$ignore_path" "$digest_path"; do
    if [[ -e "$repo_root/$path" ]] || git -C "$repo_root" ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
      stage_paths+=("$path")
    fi
  done
  if [[ -n "${stage_paths[*]-}" ]]; then
    git -C "$repo_root" add -- "${stage_paths[@]}" || exit 2
    if ! git -C "$repo_root" diff --cached --quiet -- "${stage_paths[@]}"; then
      git -C "$repo_root" commit -q -m "chore: NO_JIRA finalize delivery candidate for $slug" -- \
        "${stage_paths[@]}" || exit 2
    fi
  fi
  final_status="$(git -C "$repo_root" status --porcelain --untracked-files=all 2>/dev/null)" || exit 2
  [[ -z "$final_status" ]] || {
    echo "finalize-delivery-candidate: candidate is not clean after commit" >&2
    exit 1
  }
fi

exit 0
