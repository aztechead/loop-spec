#!/usr/bin/env bash
# task-route.sh - Validate a model-proposed autonomous task route.
#
# The model supplies semantic judgment after read-only grounding. This script owns
# authorization: malformed, uncertain, broad, or risky proposals fail upward to
# the full cycle. It never infers task semantics from keywords.
#
# Usage:
#   task-route.sh validate <classification.json | ->
#
# Output is one normalized JSON object. Classification failures are represented
# as route=full rather than process failures so autonomous callers keep moving on
# the safest path.
#
# Validation also ARMS the route: it records .loop-spec/active-run.json (git-ignored,
# never a tracked file) before the routed skill starts. Routing is the earliest point
# a run exists, so from here on an exit without a terminal result is detectable —
# by hooks/team/route-terminal-guard.sh during the session and by lib/cycle-reconcile.sh
# after it. Arming a run the routed skill never begins is the point: that is exactly
# the case this file used to leave invisible.

set -euo pipefail

usage() {
  echo "Usage: task-route.sh validate <classification.json | ->" >&2
  exit 2
}

[[ "${1:-}" == "validate" ]] || usage
source_path="${2:-}"
[[ -n "$source_path" ]] || usage
repo_path="."
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$script_dir/cycle-result.sh" clear --result-root "$PWD"
bash "$script_dir/runtime-preflight.sh" check-jq

if [[ "$source_path" == "-" ]]; then
  raw="$(cat)"
elif [[ -f "$source_path" ]]; then
  raw="$(<"$source_path")"
else
  echo "task-route.sh: classification file not found: $source_path" >&2
  exit 2
fi

# Always autonomous: /loop-spec:auto is this validator's only caller, and it is
# autonomous by definition. The guard reads that flag to leave interactive runs alone.
arm_route() {
  local route="$1" title="$2" classification="${3:-}"
  local -a extra=()
  [[ -n "$classification" ]] && extra+=(--classification "$classification")
  bash "$script_dir/cycle-result.sh" begin --result-root "$repo_path" \
    --cycle-type "$route" --title "$title" --phase routing \
    --autonomous true ${extra[@]+"${extra[@]}"} >/dev/null 2>&1 || true
}

fallback() {
  local reason_code="$1"
  local reason="Classification was not safe enough for a reduced cycle"
  arm_route full "$reason"
  jq -nc --arg reason_code "$reason_code" --arg reason "$reason" '{
    route: "full",
    candidateRoute: null,
    reasonCode: $reason_code,
    reason: $reason
  }'
}

if ! jq -e '
  type == "object" and
  (.route | type == "string") and
  (["micro", "debug", "compact", "full"] | index($ARGS.named.route)) != null
' --arg route "$(jq -r '.route // ""' <<<"$raw" 2>/dev/null || true)" <<<"$raw" >/dev/null 2>&1; then
  fallback "invalid-classification"
  exit 0
fi

# Compact routes share cycle-profile's single gate-plan validator so routing and
# execution cannot disagree on the durable contract. Micro/debug keep their legacy
# payload shape because this check runs only for an explicitly compact candidate.
if [[ "$(jq -r '.route' <<<"$raw")" == "compact" ]] && ! \
  printf '%s' "$raw" | bash "$script_dir/cycle-profile.sh" validate-gate-plan -; then
  fallback "invalid-compact-gate-plan"
  exit 0
fi

if ! jq -e '
  (.taskKind | type == "string") and
  (["docs", "config", "maintenance", "bug", "feature", "refactor", "greenfield", "unknown"] | index($ARGS.named.task_kind)) != null and
  (.confidence | type == "number" and . >= 0 and . <= 1) and
  (.estimatedFiles | type == "number" and floor == . and . >= 0 and . <= 100000) and
  (.criteriaCount | type == "number" and floor == . and . >= 1 and . <= 100000) and
  (.ambiguity == "low" or .ambiguity == "medium" or .ambiguity == "high") and
  (.introducesSeam | type == "boolean") and
  (.introducesDependency | type == "boolean") and
  ((has("introducesNewDependency") | not) or (.introducesNewDependency | type == "boolean")) and
  ((has("updatesDependencyVersion") | not) or (.updatesDependencyVersion | type == "boolean")) and
  (((has("introducesNewDependency") or has("updatesDependencyVersion")) | not) or
    (has("introducesNewDependency") and has("updatesDependencyVersion") and
     (.introducesDependency == (.introducesNewDependency or .updatesDependencyVersion)))) and
  ((has("generatedFiles") | not) or
    (.generatedFiles as $generated |
      ($generated | type == "number") and ($generated | floor == .) and
      $generated >= 0 and $generated <= .estimatedFiles)) and
  (.changesInterface | type == "boolean") and
  (.securitySensitive | type == "boolean") and
  (.dataMigration | type == "boolean") and
  (.multiRepo | type == "boolean") and
  (.destructive | type == "boolean") and
  (.reason | type == "string" and length > 0 and length <= 500)
' --arg task_kind "$(jq -r '.taskKind // ""' <<<"$raw")" <<<"$raw" >/dev/null; then
  fallback "invalid-classification"
  exit 0
fi

# New classifiers distinguish an added dependency edge from a version update and
# identify generated lockfiles. Older callers retain the conservative behavior:
# introducesDependency means a new edge and every estimated file counts.
raw="$(jq -c '
  . + {
    introducesNewDependency:
      (if has("introducesNewDependency") then .introducesNewDependency else .introducesDependency end),
    updatesDependencyVersion: (.updatesDependencyVersion // false),
    generatedFiles: (.generatedFiles // 0)
  }
' <<<"$raw")"

candidate_route="$(jq -r '.route' <<<"$raw")"
task_kind="$(jq -r '.taskKind' <<<"$raw")"
confidence="$(jq -r '.confidence' <<<"$raw")"
estimated_files="$(jq -r '.estimatedFiles' <<<"$raw")"
generated_files="$(jq -r '.generatedFiles' <<<"$raw")"
reviewable_files=$((estimated_files - generated_files))
criteria_count="$(jq -r '.criteriaCount' <<<"$raw")"
ambiguity="$(jq -r '.ambiguity' <<<"$raw")"

working_tree_conflict=false
clean_state=""
if ! git -C "$repo_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  working_tree_conflict=true
elif ! clean_state="$(bash "$script_dir/git-ops.sh" -C "$repo_path" ensure-clean-or-stash 2>/dev/null)"; then
  working_tree_conflict=true
elif [[ "$clean_state" != "clean" ]]; then
  working_tree_conflict=true
fi
raw="$(jq -c --argjson conflict "$working_tree_conflict" '. + {workingTreeConflict: $conflict}' <<<"$raw")"

normalized_route="$candidate_route"
reason_code="validated"

if [[ "$candidate_route" == "full" ]]; then
  reason_code="classifier-selected-full"
elif [[ "$candidate_route" == "compact" || "$candidate_route" == "debug" ]]; then
  if [[ "$candidate_route" == "compact" && "$task_kind" != "feature" && "$task_kind" != "refactor" ]]; then
    normalized_route="full"
    reason_code="compact-task-kind-mismatch"
  elif [[ "$candidate_route" == "debug" && "$task_kind" != "bug" ]]; then
    normalized_route="full"
    reason_code="debug-task-kind-mismatch"
  elif [[ "$ambiguity" == "high" ]]; then
    normalized_route="full"
    reason_code="high-ambiguity"
  elif ! jq -e '.confidence >= 0.7' <<<"$raw" >/dev/null; then
    normalized_route="full"
    reason_code="low-confidence"
  elif [[ "$candidate_route" == "compact" ]] && (( reviewable_files > 12 || criteria_count > 6 )); then
    normalized_route="full"
    reason_code="compact-scope-too-large"
  elif [[ "$candidate_route" == "compact" ]] && jq -e '.destructive' <<<"$raw" >/dev/null; then
    normalized_route="full"
    reason_code="destructive-compact"
  fi
elif jq -e '
  .introducesSeam or .introducesNewDependency or .changesInterface or
  .securitySensitive or .dataMigration or .multiRepo or .destructive or
  .workingTreeConflict
' <<<"$raw" >/dev/null; then
  normalized_route="full"
  reason_code="hard-risk"
elif (( reviewable_files > 5 || criteria_count > 3 )); then
  normalized_route="full"
  reason_code="scope-too-large"
elif [[ "$ambiguity" == "high" ]]; then
  normalized_route="full"
  reason_code="high-ambiguity"
elif [[ "$candidate_route" == "micro" ]]; then
  if [[ "$ambiguity" != "low" ]]; then
    normalized_route="full"
    reason_code="micro-requires-low-ambiguity"
  elif ! jq -e '.confidence >= 0.8' <<<"$raw" >/dev/null; then
    normalized_route="full"
    reason_code="low-confidence"
  elif [[ "$task_kind" == "feature" || "$task_kind" == "refactor" || "$task_kind" == "greenfield" || "$task_kind" == "unknown" ]]; then
    normalized_route="full"
    reason_code="micro-task-kind-mismatch"
  fi
fi

normalized="$(jq -c \
  --arg route "$normalized_route" \
  --arg candidate_route "$candidate_route" \
  --arg reason_code "$reason_code" \
  --argjson reviewable_files "$reviewable_files" \
  '. + {route: $route, candidateRoute: $candidate_route, reasonCode: $reason_code,
        reviewableEstimatedFiles: $reviewable_files}' \
  <<<"$raw")"

arm_route "$normalized_route" "$(jq -r '.reason' <<<"$raw")" "$normalized"
printf '%s\n' "$normalized"
