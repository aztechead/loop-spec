#!/usr/bin/env bash
# Turn a GitHub PR created outside lib/deliver.sh into canonical delivery.json.
#
# Headless agents sometimes run `gh pr create --draft` and then print
# LOOP_SPEC_RESULT without a sidecar. cycle-result.sh write and cycle-reconcile.sh
# call this fail-open so a missing record is not silently treated as a gap.
#
# Usage:
#   delivery-reconcile.sh observe <feature_dir> [--accept-checkpoint]
#
# --accept-checkpoint: treat a PR whose URL equals feature.checkpointPrUrl as a
# real delivery. cycle-result write --status completed passes this because the
# agent claimed completion. cycle-reconcile does not: a checkpoint PR is the
# interruption salvage, not a delivered feature.
#
# Does not push, create, edit metadata, or mark the PR ready. Required checks
# are read once (no long poll). Green draft → delivery.status delivered-draft;
# green ready → ready-for-review. Pending/failed checks, SHA mismatch, or no
# open PR leave delivery.json unchanged.
#
# Workspace mode is out of scope (per-repo branches; callers handle per-repo PRs).
#
# Kill switch: LOOP_SPEC_DELIVERY_RECONCILE=0 skips without writing.
#
# stdout is the sidecar JSON on success/no-op. Diagnostics go to stderr.
# Exit 0: canonical sidecar present or written; 1: nothing to record; 2: bad input.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR_DELIVERY="${LOOP_SPEC_PR_DELIVERY_BIN:-$SCRIPT_DIR/pr-delivery.sh}"

usage() {
  echo "usage: delivery-reconcile.sh observe <feature_dir> [--accept-checkpoint]" >&2
  exit 2
}

cmd="${1:-}"
feature_dir="${2:-}"
[[ "$cmd" == "observe" && -n "$feature_dir" ]] || usage
shift 2
accept_checkpoint=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --accept-checkpoint) accept_checkpoint=1; shift ;;
    *) echo "delivery-reconcile: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

[[ -f "$feature_dir/feature.json" ]] || {
  echo "delivery-reconcile: feature.json not found in $feature_dir" >&2
  exit 2
}

if [[ "${LOOP_SPEC_DELIVERY_RECONCILE:-1}" == "0" ]]; then
  echo "delivery-reconcile: skipped (LOOP_SPEC_DELIVERY_RECONCILE=0)" >&2
  exit 0
fi

feature_dir="$(cd "$feature_dir" && pwd)"
feature_json="$feature_dir/feature.json"
delivery_file="$feature_dir/delivery.json"
jq -e '.schemaVersion == 7' "$feature_json" >/dev/null 2>&1 || {
  echo "delivery-reconcile: feature must be schema 7" >&2
  exit 2
}

canonical_sidecar() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  jq -e '
    .nextPhase == "completed" and
    (.status == "ready-for-review" or .status == "delivered-draft") and
    ((.targets // []) | any((.prUrl // "") != ""))
  ' "$path" >/dev/null 2>&1
}

if canonical_sidecar "$delivery_file"; then
  jq -c . "$delivery_file"
  exit 0
fi

workspace_root="$(jq -r '.workspace.root // empty' "$feature_json")"
if [[ -n "$workspace_root" ]]; then
  echo "delivery-reconcile: workspace mode is out of scope" >&2
  exit 1
fi

slug="$(jq -r '.slug' "$feature_json")"
branch="$(jq -r '.branch // empty' "$feature_json")"
base_branch="$(jq -r '.baseBranch // "main"' "$feature_json")"
[[ -n "$branch" ]] || {
  echo "delivery-reconcile: feature has no branch" >&2
  exit 1
}

artifact_root="$(git -C "$feature_dir" rev-parse --show-toplevel 2>/dev/null)" || {
  echo "delivery-reconcile: feature directory is not inside a git work tree" >&2
  exit 1
}
target_sha="$(git -C "$artifact_root" rev-parse --verify HEAD 2>/dev/null)" || {
  echo "delivery-reconcile: cannot resolve HEAD" >&2
  exit 1
}

checkpoint_url="$(jq -r '.checkpointPrUrl // empty' "$feature_json")"
hint=""
[[ -f "$delivery_file" ]] && hint="$(jq -r '.prUrl // empty' "$delivery_file" 2>/dev/null || true)"
[[ -n "$hint" ]] || hint="$(jq -r '.prUrl // empty' "$feature_json")"
if [[ "$accept_checkpoint" -eq 0 && -z "$hint" ]]; then
  hint="$checkpoint_url"
fi

observe_args=(observe -C "$artifact_root" --branch "$branch" --sha "$target_sha")
[[ -n "$base_branch" ]] && observe_args+=(--base "$base_branch")
[[ -n "$hint" ]] && observe_args+=(--pr-url "$hint")

observe_rc=0
result="$(bash "$PR_DELIVERY" "${observe_args[@]}")" || observe_rc=$?
if ! jq -e 'type == "object" and has("ok")' >/dev/null 2>&1 <<<"${result:-}"; then
  echo "delivery-reconcile: observe did not return a delivery record" >&2
  exit 1
fi
[[ "$observe_rc" -eq 0 ]] || {
  echo "delivery-reconcile: observe blocked: $(jq -r '.errorCode // "unknown"' <<<"$result")" >&2
  exit 1
}

outcome="$(jq -r '.outcome // empty' <<<"$result")"
pr_url="$(jq -r '.prUrl // empty' <<<"$result")"
case "$outcome" in
  delivered|delivered-draft) ;;
  *)
    echo "delivery-reconcile: observe outcome '$outcome' is not a delivery" >&2
    exit 1
    ;;
esac
[[ -n "$pr_url" ]] || {
  echo "delivery-reconcile: observe returned no PR URL" >&2
  exit 1
}

if [[ "$accept_checkpoint" -eq 0 && -n "$checkpoint_url" && "$pr_url" == "$checkpoint_url" ]]; then
  echo "delivery-reconcile: refusing checkpoint-only PR $pr_url" >&2
  exit 1
fi

if [[ "$outcome" == "delivered-draft" ]]; then
  status="delivered-draft"
else
  status="ready-for-review"
fi

now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
record="$(jq -c --arg name "$slug" --arg path "$artifact_root" \
  '. + {name:$name,path:$path,bindingEligible:true}' <<<"$result")"
targets="$(jq -cn --argjson record "$record" '[$record]')"
ok=true
aggregate="$(jq -cn --argjson ok "$ok" --arg status "$status" --arg nextPhase "completed" \
  --arg prUrl "$pr_url" --arg attempted "$now" --arg finished "$now" \
  --argjson targets "$targets" \
  '{schema:1,ok:$ok,status:$status,nextPhase:$nextPhase,prUrl:$prUrl,attemptedAt:$attempted,
    finishedAt:$finished,ciRemediationAttempts:0,ciRemediationLimit:2,targets:$targets}')"

printf '%s\n' "$aggregate" > "$delivery_file.tmp" || exit 2
sync
mv "$delivery_file.tmp" "$delivery_file" || exit 2
printf '%s\n' "$aggregate"
exit 0
