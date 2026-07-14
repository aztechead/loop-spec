#!/usr/bin/env bash
# Machine-readable cycle result contract for headless/programmatic callers.
#
# OBSERVABILITY CONTRACT: this script must NEVER abort a cycle. All internal
# failures print a one-line warning to stderr and exit 0. A broken telemetry
# writer must not kill a 2-hour run.
#
# Usage:
#   cycle-result.sh write <feature_dir> --status <completed|paused|escalated|terminal>
#                        [--pr-url <url>] [--reason <text>]
#
# Reads <feature_dir>/feature.json and writes <feature_dir>/result.json, then
# copies it to <feature_dir>/../../last-result.json (i.e., .loop-spec/last-result.json,
# since feature dirs live at .loop-spec/features/<slug>).
#
# Also emits a matching event via lib/events.sh (event = the status value) so
# events.jsonl and result.json can't disagree.
#
# result.json schema (schema version 1):
# {
#   "schema": 1,
#   "slug": "...",
#   "status": "completed | paused | escalated | terminal",
#   "reason": "<--reason text or null>",
#   "phaseReached": "<logical phase, including delivery.json completion>",
#   "branch": "<.branch>",
#   "baseBranch": "<.baseBranch>",
#   "prUrl": "<--pr-url arg, else delivery.json/feature.json .prUrl, else null>",
#   "checkpointPrUrl": "<feature.json .checkpointPrUrl // null>",
#   "delivery": "<delivery.json, else feature.json .delivery, else null>",
#   "converged": <true iff status==completed AND no warnings[] entry starts
#                 with "iterate-budget-spent:" or "iterate-terminal:", AND an
#                 explicit delivery block is ready-for-review (legacy state with
#                 no delivery block remains compatible)>,
#   "iterations": {"used": <.iterate.used // 0>, "max": <.iterate.maxIterations // null>},
#   "warnings": <.warnings // []>,
#   "autonomous": <.autonomous // false>,
#   "feature_title": "<.feature_title // .slug>",
#   "createdAt": "<.createdAt // null>",
#   "finishedAt": "<now ISO-8601 UTC>"
# }
#
# events.jsonl and result.json are local telemetry, deliberately not committed.
#
# Missing feature.json → one-line stderr warning, exit 0 (observability never aborts).
# Bad --status value → one-line stderr warning, exit 0, write nothing.
#
# Exit codes: always 0 (observability never aborts).
set -uo pipefail

VALID_STATUSES="completed paused escalated terminal"

_is_valid_status() {
  local s="$1"
  for v in $VALID_STATUSES; do
    [[ "$s" == "$v" ]] && return 0
  done
  return 1
}

case "${1:-}" in
  write)
    feature_dir="${2:-}"
    if [[ -z "$feature_dir" ]]; then
      echo "cycle-result.sh: bad invocation — usage: cycle-result.sh write <feature_dir> --status <status> [--pr-url <url>] [--reason <text>]" >&2
      exit 0
    fi

    # Parse remaining flags
    status=""
    pr_url=""
    reason=""
    shift 2 || true
    while [[ $# -gt 0 ]]; do
      case "${1:-}" in
        --status)
          status="${2:-}"
          shift 2 || shift || true
          ;;
        --pr-url)
          pr_url="${2:-}"
          shift 2 || shift || true
          ;;
        --reason)
          reason="${2:-}"
          shift 2 || shift || true
          ;;
        *)
          shift || true
          ;;
      esac
    done

    # Validate status
    if [[ -z "$status" ]]; then
      echo "cycle-result.sh: --status is required" >&2
      exit 0
    fi
    if ! _is_valid_status "$status"; then
      echo "cycle-result.sh: invalid --status '$status'; must be one of: $VALID_STATUSES" >&2
      exit 0
    fi

    # Load feature.json
    fj="$feature_dir/feature.json"
    if [[ ! -f "$fj" ]]; then
      echo "cycle-result.sh: feature.json not found in $feature_dir" >&2
      exit 0
    fi

    fj_content="$(cat "$fj" 2>/dev/null)" || {
      echo "cycle-result.sh: cannot read $fj" >&2
      exit 0
    }
    delivery_content="null"
    if [[ -f "$feature_dir/delivery.json" ]]; then
      delivery_content="$(jq -c . "$feature_dir/delivery.json" 2>/dev/null || echo null)"
    fi

    # Build result.json with jq (never string-interpolate user text into JSON).
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    result_json="$(jq -cn \
      --arg now "$now" \
      --arg status "$status" \
      --arg pr_url_arg "$pr_url" \
      --arg reason_arg "$reason" \
      --argjson fj "$fj_content" \
      --argjson delivery "$delivery_content" \
      '
      # prUrl: explicit arg, successful delivery sidecar, tracked fallback.
      (if $pr_url_arg != "" then $pr_url_arg
       elif (($delivery.prUrl // "") != "") then $delivery.prUrl
       elif (($fj.prUrl // "") != "") then $fj.prUrl
       else null
       end) as $prUrl |
      # reason: --reason arg, or null
      (if $reason_arg != "" then $reason_arg else null end) as $reason |
      # converged: clean goal verdict plus a successful explicit delivery when present.
      (($status == "completed") and
       (($fj.warnings // [])
         | map(startswith("iterate-budget-spent:") or startswith("iterate-terminal:"))
         | any | not) and
       (if $delivery != null then (($delivery.status // "") == "ready-for-review")
        else (($fj | has("delivery") | not) or (($fj.delivery.status // "") == "ready-for-review"))
        end)) as $converged |
      {
        schema: 1,
        slug: $fj.slug,
        status: $status,
        reason: $reason,
        phaseReached: (if $status == "completed" and (($delivery.status // "") == "ready-for-review")
                       then "completed" else ($fj.currentPhase // null) end),
        branch: ($fj.branch // null),
        baseBranch: ($fj.baseBranch // null),
        prUrl: $prUrl,
        checkpointPrUrl: ($fj.checkpointPrUrl // null),
        delivery: (if $delivery != null then $delivery else ($fj.delivery // null) end),
        converged: $converged,
        iterations: {
          used: ($fj.iterate.used // 0),
          max: ($fj.iterate.maxIterations // null)
        },
        warnings: ($fj.warnings // []),
        autonomous: ($fj.autonomous // false),
        feature_title: ($fj.feature_title // $fj.slug),
        createdAt: ($fj.createdAt // null),
        finishedAt: $now
      }
      ')" 2>/dev/null || {
      echo "cycle-result.sh: failed to build result.json from feature.json in $feature_dir" >&2
      exit 0
    }

    # Write result.json to feature dir
    printf '%s\n' "$result_json" > "$feature_dir/result.json" 2>/dev/null || {
      echo "cycle-result.sh: failed to write result.json to $feature_dir" >&2
      exit 0
    }

    # Copy to .loop-spec/last-result.json.
    # Feature dirs live at .loop-spec/features/<slug>, so ../../ resolves to .loop-spec.
    # Guard with normalization: cd into the resolved path to verify it exists.
    feature_dir_abs="$(cd "$feature_dir" 2>/dev/null && pwd)" || feature_dir_abs=""
    if [[ -n "$feature_dir_abs" ]]; then
      loop_spec_dir="$(cd "$feature_dir_abs/../.." 2>/dev/null && pwd)" || loop_spec_dir=""
      if [[ -n "$loop_spec_dir" ]]; then
        printf '%s\n' "$result_json" > "$loop_spec_dir/last-result.json" 2>/dev/null || {
          echo "cycle-result.sh: failed to write last-result.json to $loop_spec_dir" >&2
        }
      else
        echo "cycle-result.sh: cannot resolve .loop-spec dir; last-result.json not written" >&2
      fi
    fi

    # Emit matching event via lib/events.sh so events.jsonl and result.json can't disagree.
    EVENTS_SH="$(dirname "${BASH_SOURCE[0]}")/events.sh"
    bash "$EVENTS_SH" emit "$feature_dir" "$status" 2>/dev/null || true

    exit 0
    ;;
  *)
    echo "cycle-result.sh: bad invocation — usage: cycle-result.sh write <feature_dir> --status <status> [--pr-url <url>] [--reason <text>]" >&2
    exit 0
    ;;
esac
