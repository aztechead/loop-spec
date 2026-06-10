#!/usr/bin/env bash
# Parse PLAN.md for ### task-NNN: headings and emit a JSON object.
#
# Usage: plan-adherence.sh <plan-path>
#   <plan-path> may be a file path or /dev/stdin.
#
# Output (always to stdout, always valid JSON):
#   {"plan_task_ids": ["task-001", ...], "gap_message": null}
#   {"plan_task_ids": [], "gap_message": "file not found: <path>"}
#
# Exit codes:
#   0 always (fail-open)

plan_path="${1:-}"

if [[ -z "$plan_path" ]]; then
  jq -n '{"plan_task_ids": [], "gap_message": "no plan path provided"}'
  exit 0
fi

if [[ "$plan_path" != "/dev/stdin" && ! -f "$plan_path" ]]; then
  jq -n --arg msg "file not found: $plan_path" \
    '{"plan_task_ids": [], "gap_message": $msg}'
  exit 0
fi

# Extract task IDs from headings matching ^### task-[0-9]+:
ids=$(grep -E '^### task-[0-9]+:' "$plan_path" \
  | sed 's/^### //' \
  | cut -d: -f1)

# Build JSON array using jq -n with --args
if [[ -z "$ids" ]]; then
  jq -n '{"plan_task_ids": [], "gap_message": null}'
else
  # Pass each ID as a positional arg to jq
  jq -n '{"plan_task_ids": $ARGS.positional, "gap_message": null}' \
    --args $ids
fi
