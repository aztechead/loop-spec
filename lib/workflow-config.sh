#!/usr/bin/env bash
# workflow-config.sh - Read optional per-project workflow config.
#
# Source of truth: .loop-spec/workflow.json (absent = all defaults). Mirrors the
# superpowers workflow.json idea so EXECUTE can switch commit cadence without a
# code change.
#
# Usage:
#   workflow-config.sh commit-strategy
#       Print "per-task" (default) or "at-end".
#       per-task: each completed task commits its own change (current behavior).
#       at-end:   tasks leave changes staged; a single final commit closes the plan.
#
#   workflow-config.sh get <key> [default]
#       Print a raw string value for an arbitrary top-level key, or the default.
#
# File: $LOOP_SPEC_WORKFLOW_CONFIG else ${CLAUDE_PROJECT_DIR:-.}/.loop-spec/workflow.json
# Fail-open: any parse error yields the default; never blocks the cycle.

set -euo pipefail
trap 'exit 0' ERR

CONFIG_FILE="${LOOP_SPEC_WORKFLOW_CONFIG:-${CLAUDE_PROJECT_DIR:-.}/.loop-spec/workflow.json}"

read_key() {
  local key="$1" default="$2"
  if [[ -f "$CONFIG_FILE" ]]; then
    local v
    v=$(jq -r --arg k "$key" '.[$k] // empty' "$CONFIG_FILE" 2>/dev/null || true)
    if [[ -n "$v" && "$v" != "null" ]]; then
      printf '%s\n' "$v"
      return 0
    fi
  fi
  printf '%s\n' "$default"
}

cmd="${1:-}"
case "$cmd" in
  commit-strategy)
    val=$(read_key commitStrategy "per-task")
    # Normalize: only the two known values are honored; anything else => default.
    case "$val" in
      at-end|per-task) printf '%s\n' "$val" ;;
      *) printf 'per-task\n' ;;
    esac
    ;;
  get)
    read_key "${2:?key required}" "${3:-}"
    ;;
  *)
    echo "workflow-config.sh: unknown command '${cmd}' (commit-strategy|get)" >&2
    exit 2
    ;;
esac
