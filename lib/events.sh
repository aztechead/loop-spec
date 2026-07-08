#!/usr/bin/env bash
# Structured progress events for headless/programmatic callers (JSONL).
#
# OBSERVABILITY CONTRACT: this script must NEVER abort a cycle. All internal
# failures print a one-line warning to stderr and exit 0. A broken telemetry
# writer must not kill a 2-hour run.
#
# Usage:
#   events.sh emit <feature_dir> <event> [--phase <phase>] [--data <json-object>]
#
# Appends ONE line to <feature_dir>/events.jsonl:
#   {"ts":"<ISO-8601 UTC>","slug":"<slug>","event":"<event>","phase":<phase|null>,"data":<object|{}>}
#
# Slug resolution: reads <feature_dir>/feature.json .slug; falls back to the
# basename of <feature_dir> when feature.json is absent or unparseable.
#
# --data must be a valid JSON object; if not, a warning is printed and {} is used.
# Missing args → exit 0 with a loud warning (non-fatal).
#
# The file is created if absent and is append-only (never rewritten).
#
# Canonical event names:
#   phase_start       - a phase is about to run
#   phase_end         - a phase returned (data: {"next":"<next_phase>"})
#   gate_round        - a gate round completed (data: {"gate":..,"round":N})
#   iterate_verdict   - an iterate judge verdict landed
#   dispatch          - an agent was launched (data: {"role":..,"model":..,"rung":..};
#                       contract: skills/shared/dispatch-events.md)
#   completed         - cycle completed successfully
#   paused            - cycle paused by user
#   escalated         - cycle escalated due to limit/context
#   checkpoint_pr     - a checkpoint PR was created
#
# events.jsonl and result.json are local telemetry, deliberately not committed.
#
# Exit codes: always 0 (observability never aborts).
set -uo pipefail

EVENTS_FILE="events.jsonl"

# Resolve slug from feature.json .slug, with basename fallback.
_resolve_slug() {
  local fdir="$1"
  local fj="$fdir/feature.json"
  if [[ -f "$fj" ]]; then
    local s
    s="$(jq -r '.slug // empty' "$fj" 2>/dev/null || true)"
    if [[ -n "$s" ]]; then
      printf '%s' "$s"
      return
    fi
  fi
  printf '%s' "$(basename "$fdir")"
}

case "${1:-}" in
  emit)
    feature_dir="${2:-}"
    event="${3:-}"
    if [[ -z "$feature_dir" || -z "$event" ]]; then
      echo "events.sh: bad invocation — usage: events.sh emit <feature_dir> <event> [--phase <phase>] [--data <json-object>]" >&2
      exit 0
    fi

    # Parse optional flags
    has_phase=0
    phase_str=""
    data_val="{}"
    shift 3 || true
    while [[ $# -gt 0 ]]; do
      case "${1:-}" in
        --phase)
          phase_str="${2:-}"
          has_phase=1
          shift 2 || shift || true
          ;;
        --data)
          raw_data="${2:-}"
          if printf '%s' "$raw_data" | jq -e 'type == "object"' >/dev/null 2>&1; then
            data_val="$raw_data"
          else
            echo "events.sh: --data is not a valid JSON object; using {} instead" >&2
            data_val="{}"
          fi
          shift 2 || shift || true
          ;;
        *)
          shift || true
          ;;
      esac
    done

    # Resolve slug
    slug="$(_resolve_slug "$feature_dir")"
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # Create events.jsonl if absent; append-only, never rewrite.
    if ! touch "$feature_dir/$EVENTS_FILE" 2>/dev/null; then
      echo "events.sh: cannot write to $feature_dir/$EVENTS_FILE" >&2
      exit 0
    fi

    # Build and append JSON via jq (never string-interpolate user text into JSON).
    jq -cn \
      --arg ts "$ts" \
      --arg slug "$slug" \
      --arg event "$event" \
      --argjson has_phase "$has_phase" \
      --arg phase_str "$phase_str" \
      --argjson data "$data_val" \
      '{ts: $ts, slug: $slug, event: $event,
        phase: (if $has_phase == 1 then $phase_str else null end),
        data: $data}' \
      >> "$feature_dir/$EVENTS_FILE" 2>/dev/null || {
      echo "events.sh: failed to append event '$event' to $feature_dir/$EVENTS_FILE" >&2
    }
    exit 0
    ;;
  *)
    echo "events.sh: bad invocation — usage: events.sh emit <feature_dir> <event> [--phase <phase>] [--data <json-object>]" >&2
    exit 0
    ;;
esac
