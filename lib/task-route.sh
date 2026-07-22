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

fallback() {
  local reason_code="$1"
  jq -nc --arg reason_code "$reason_code" '{
    route: "full",
    candidateRoute: null,
    reasonCode: $reason_code,
    reason: "Classification was not safe enough for a reduced cycle"
  }'
}

if ! jq -e '
  type == "object" and
  (.route | type == "string") and
  (["micro", "debug", "full"] | index($ARGS.named.route)) != null
' --arg route "$(jq -r '.route // ""' <<<"$raw" 2>/dev/null || true)" <<<"$raw" >/dev/null 2>&1; then
  fallback "invalid-classification"
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

candidate_route="$(jq -r '.route' <<<"$raw")"
task_kind="$(jq -r '.taskKind' <<<"$raw")"
confidence="$(jq -r '.confidence' <<<"$raw")"
estimated_files="$(jq -r '.estimatedFiles' <<<"$raw")"
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
elif jq -e '
  .introducesSeam or .introducesDependency or .changesInterface or
  .securitySensitive or .dataMigration or .multiRepo or .destructive or
  .workingTreeConflict
' <<<"$raw" >/dev/null; then
  normalized_route="full"
  reason_code="hard-risk"
elif (( estimated_files > 5 || criteria_count > 3 )); then
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
elif [[ "$candidate_route" == "debug" ]]; then
  if [[ "$task_kind" != "bug" ]]; then
    normalized_route="full"
    reason_code="debug-task-kind-mismatch"
  elif [[ "$ambiguity" == "high" ]]; then
    normalized_route="full"
    reason_code="high-ambiguity"
  elif ! jq -e '.confidence >= 0.7' <<<"$raw" >/dev/null; then
    normalized_route="full"
    reason_code="low-confidence"
  fi
fi

jq -c \
  --arg route "$normalized_route" \
  --arg candidate_route "$candidate_route" \
  --arg reason_code "$reason_code" \
  '. + {route: $route, candidateRoute: $candidate_route, reasonCode: $reason_code}' \
  <<<"$raw"
