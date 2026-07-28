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
# phase_start and phase_end also print a greppable marker. Their attempt IDs are
# paired through an ignored local sidecar; callers do not need to retain them.
#
# Canonical event names:
#   phase_start       - a phase is about to run
#   phase_end         - a phase returned (data: {"next":"<next_phase>"})
#   gate_round        - a gate round completed (data: {"gate":..,"round":N})
#   iterate_verdict   - an iterate judge verdict landed
#   dispatch          - an agent was launched (data: {"role":..,"model":..,"rung":..};
#                       contract: skills/shared/dispatch-events.md)
#   verify_failure    - a VERIFY gate failed (data: {"class":"marker|tamper|
#                       suite-regression|acceptance|code-review|live-probe"};
#                       mined into the run digest's verifyFailureClasses)
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
ATTEMPTS_FILE=".phase-attempts.json"

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

_phase_key() {
  if [[ -n "$1" ]]; then printf '%s' "$1"; else printf '%s' "__no_phase__"; fi
}

_phase_label() {
  if [[ -n "$1" ]]; then printf '%s' "$1"; else printf '%s' "unknown"; fi
}

_phase_start_attempt() {
  local fdir="$1" slug="$2" phase="$3" timestamp="$4" epoch="$5"
  local state_file="$fdir/$ATTEMPTS_FILE" state key label sequence attempt_id updated tmp
  state='{"sequence":0,"phases":{}}'
  if [[ -f "$state_file" ]]; then
    state="$(jq -c 'select(type == "object")' "$state_file" 2>/dev/null || true)"
    [[ -n "$state" ]] || state='{"sequence":0,"phases":{}}'
  fi
  key="$(_phase_key "$phase")"
  label="$(_phase_label "$phase")"
  sequence="$(jq -r '(.sequence // 0) + 1' <<<"$state" 2>/dev/null || printf '1')"
  attempt_id="${slug}:${label}:${sequence}"
  updated="$(jq -c --arg key "$key" --arg id "$attempt_id" --arg timestamp "$timestamp" \
    --argjson sequence "$sequence" --argjson epoch "$epoch" '
      .sequence = $sequence |
      .phases = (.phases // {}) |
      .phases[$key] = ((.phases[$key] // []) +
        [{attemptId:$id,timestamp:$timestamp,startedEpoch:$epoch}])' \
    <<<"$state" 2>/dev/null || true)"
  if [[ -n "$updated" ]]; then
    tmp="${state_file}.tmp.$$"
    if ! printf '%s\n' "$updated" > "$tmp" 2>/dev/null || ! mv "$tmp" "$state_file" 2>/dev/null; then
      rm -f "$tmp" 2>/dev/null || true
      echo "events.sh: cannot persist phase attempt state in $state_file" >&2
    fi
  else
    echo "events.sh: cannot build phase attempt state for '$phase'" >&2
  fi
  printf '%s' "$attempt_id"
}

_phase_end_attempt() {
  local fdir="$1" slug="$2" phase="$3" now_epoch="$4"
  local state_file="$fdir/$ATTEMPTS_FILE" state key label record attempt_id started elapsed updated tmp
  key="$(_phase_key "$phase")"
  label="$(_phase_label "$phase")"
  state="$(jq -c 'select(type == "object")' "$state_file" 2>/dev/null || true)"
  record=""
  if [[ -n "$state" ]]; then
    record="$(jq -c --arg key "$key" '.phases[$key][-1] // empty' <<<"$state" 2>/dev/null || true)"
  fi
  if [[ -n "$record" ]]; then
    attempt_id="$(jq -r '.attemptId' <<<"$record")"
    started="$(jq -r '.startedEpoch' <<<"$record")"
    case "$started" in ''|*[!0-9]*) started="$now_epoch" ;; esac
    elapsed=$((now_epoch - started))
    [[ "$elapsed" -ge 0 ]] || elapsed=0
    updated="$(jq -c --arg key "$key" '
      if ((.phases[$key] // []) | length) <= 1
      then del(.phases[$key])
      else .phases[$key] = .phases[$key][0:-1]
      end' <<<"$state" 2>/dev/null || true)"
    if [[ -n "$updated" ]]; then
      tmp="${state_file}.tmp.$$"
      if ! printf '%s\n' "$updated" > "$tmp" 2>/dev/null || ! mv "$tmp" "$state_file" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null || true
        echo "events.sh: cannot update phase attempt state in $state_file" >&2
      fi
    fi
  else
    attempt_id="${slug}:${label}:unmatched"
    elapsed=0
  fi
  printf '%s\t%s' "$attempt_id" "$elapsed"
}

_phase_verdict() {
  local phase="$1" next="$2" phase_rank=0 next_rank=0
  case "$next" in completed|done) printf '%s' "completed"; return ;; esac
  if [[ -z "$next" || "$next" == "$phase" ]]; then
    printf '%s' "blocked"
    return
  fi
  case "$phase" in
    spec) phase_rank=1 ;; discuss) phase_rank=2 ;; plan) phase_rank=3 ;;
    execute) phase_rank=4 ;; verify) phase_rank=5 ;; iterate) phase_rank=6 ;;
    deliver) phase_rank=7 ;;
  esac
  case "$next" in
    spec) next_rank=1 ;; discuss) next_rank=2 ;; plan) next_rank=3 ;;
    execute) next_rank=4 ;; verify) next_rank=5 ;; iterate) next_rank=6 ;;
    deliver) next_rank=7 ;;
  esac
  if [[ "$phase_rank" -gt 0 && "$next_rank" -gt 0 && "$next_rank" -lt "$phase_rank" ]]; then
    printf '%s' "rewind"
  else
    printf '%s' "advanced"
  fi
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
    epoch="$(date -u +%s)"

    # Create events.jsonl if absent; append-only, never rewrite.
    if ! touch "$feature_dir/$EVENTS_FILE" 2>/dev/null; then
      echo "events.sh: cannot write to $feature_dir/$EVENTS_FILE" >&2
      exit 0
    fi

    # Generic events retain their original shape. Phase events add metadata while
    # preserving all legacy fields, including data.next on phase_end.
    event_json=""
    marker=""
    if [[ "$event" == "phase_start" ]]; then
      attempt_id="$(_phase_start_attempt "$feature_dir" "$slug" "$phase_str" "$ts" "$epoch")"
      event_json="$(jq -cn --arg ts "$ts" --arg slug "$slug" --arg event "$event" \
        --argjson has_phase "$has_phase" --arg phase_str "$phase_str" --argjson data "$data_val" \
        --arg attempt "$attempt_id" '
          {ts:$ts,slug:$slug,event:$event,
           phase:(if $has_phase == 1 then $phase_str else null end),data:$data,
           attemptId:$attempt,timestamp:$ts}')"
      marker="LOOP_SPEC_PHASE_START"
    elif [[ "$event" == "phase_end" ]]; then
      attempt_record="$(_phase_end_attempt "$feature_dir" "$slug" "$phase_str" "$epoch")"
      attempt_id="${attempt_record%%$'\t'*}"
      elapsed="${attempt_record#*$'\t'}"
      next="$(jq -r '.next // empty' <<<"$data_val" 2>/dev/null || true)"
      verdict="$(_phase_verdict "$phase_str" "$next")"
      event_json="$(jq -cn --arg ts "$ts" --arg slug "$slug" --arg event "$event" \
        --argjson has_phase "$has_phase" --arg phase_str "$phase_str" --argjson data "$data_val" \
        --arg attempt "$attempt_id" --arg next "$next" --arg verdict "$verdict" \
        --argjson elapsed "$elapsed" '
          {ts:$ts,slug:$slug,event:$event,
           phase:(if $has_phase == 1 then $phase_str else null end),data:$data,
           attemptId:$attempt,timestamp:$ts,elapsedSeconds:$elapsed,
           verdict:$verdict,next:(if $next == "" then null else $next end)}')"
      marker="LOOP_SPEC_PHASE_END"
    else
      event_json="$(jq -cn --arg ts "$ts" --arg slug "$slug" --arg event "$event" \
        --argjson has_phase "$has_phase" --arg phase_str "$phase_str" --argjson data "$data_val" '
          {ts:$ts,slug:$slug,event:$event,
           phase:(if $has_phase == 1 then $phase_str else null end),data:$data}')"
    fi
    if ! printf '%s\n' "$event_json" >> "$feature_dir/$EVENTS_FILE" 2>/dev/null; then
      echo "events.sh: failed to append event '$event' to $feature_dir/$EVENTS_FILE" >&2
    fi
    [[ -z "$marker" ]] || printf '%s %s\n' "$marker" "$event_json"
    exit 0
    ;;
  *)
    echo "events.sh: bad invocation — usage: events.sh emit <feature_dir> <event> [--phase <phase>] [--data <json-object>]" >&2
    exit 0
    ;;
esac
