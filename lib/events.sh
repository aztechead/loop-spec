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
#                       contract: skills/shared/dispatch.md)
#   task_start        - an EXECUTE task began (data: {"index":N,"total":M,
#                       "id":"task-003","subject":"..."}) -> "[EXECUTE] task 2/5 start"
#   task_end          - an EXECUTE task finished (same, plus {"result":"merged|failed|..."})
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

# One greppable console line per event, for the operator watching a streamed log.
#
# This is the MECHANISM behind skills/shared/report-style.md's phase-boundary
# contract. It used to be prose asking the model to print these lines, which meant
# the only window into a long unattended run depended on model compliance and had no
# test -- in practice only EXECUTE and DISCUSS ever printed them, and non-phase
# events reached no console at all. A boundary record an operator relies on is not a
# judgment call, so it is emitted here, deterministically, for every event.
#
# stderr by DEFAULT, because stdout carries the machine contract -- the
# LOOP_SPEC_PHASE_START/END marker plus its JSON. A consumer that does
# `out=$(events.sh emit ...)` and then `jq <<<"${out#LOOP_SPEC_PHASE_START }"` gets a
# parse error the moment a second line shares that stream, so defaulting to stdout
# would break existing callers.
#
# LOOP_SPEC_CONSOLE_STREAM=stdout moves them anyway, for hosts that treat the two
# streams differently. Cloud Run is the motivating case: it assigns stderr output
# ERROR severity, so routine progress lines surface in Cloud Logging as errors. In
# that mode the console line is printed AFTER the marker, and a consumer must select
# its record by prefix (`grep '^LOOP_SPEC_PHASE_'`) instead of assuming stdout holds
# exactly one line -- which is how a robust consumer should read it either way.
#
# Format follows EXECUTE's rung-decision line, the one operators already grep:
#   [VERIFY] failure: code-review
_console_line() {
  local event="$1" phase="$2" data="$3" elapsed="${4:-}" verdict="${5:-}"
  [[ "${LOOP_SPEC_CONSOLE_EVENTS:-1}" == "0" ]] && return 0
  local tag summary field extra
  if [[ -n "$phase" ]]; then
    tag="$(printf '%s' "$phase" | tr '[:lower:]' '[:upper:]')"
  else
    tag="LOOP-SPEC"
  fi
  _d() { jq -r "$1 // empty" <<<"$data" 2>/dev/null || true; }
  case "$event" in
    phase_start)
      summary="start"
      ;;
    phase_end)
      summary="done"
      [[ -n "$elapsed" ]] && summary="$summary (${elapsed}s)"
      [[ -n "$verdict" ]] && summary="$summary - $verdict"
      field="$(_d '.next')"
      [[ -n "$field" ]] && summary="$summary -> $field"
      ;;
    gate_round)
      field="$(_d '.gate')"; extra="$(_d '.round')"
      summary="gate ${field:-critique}${extra:+ round $extra}"
      field="$(_d '.result')"
      [[ -n "$field" ]] && summary="$summary - $field"
      ;;
    dispatch)
      field="$(_d '.role')"; summary="dispatch ${field:-agent}"
      field="$(_d '.model')"; extra="$(_d '.rung')"
      [[ -n "$field$extra" ]] && summary="$summary [${field}${field:+${extra:+, }}${extra}]"
      ;;
    task_start|task_end)
      # Where a long EXECUTE actually is. A phase that runs for an hour used to
      # report only "[EXECUTE] start", so an operator watching a streamed log could
      # not tell task 1 of 6 from task 5 of 6, or progress from a stall.
      local index total
      index="$(_d '.index')"; total="$(_d '.total')"
      if [[ -n "$index" && -n "$total" ]]; then
        summary="task ${index}/${total}"
      else
        summary="task"
      fi
      [[ "$event" == "task_start" ]] && summary="$summary start" || summary="$summary done"
      field="$(_d '.id')"; extra="$(_d '.subject')"
      [[ -n "$field" ]] && summary="$summary - $field"
      [[ -n "$extra" ]] && summary="$summary: $extra"
      field="$(_d '.result')"
      [[ -n "$field" ]] && summary="$summary [$field]"
      ;;
    verify_failure)
      field="$(_d '.class')"
      summary="FAILURE: ${field:-unclassified}"
      ;;
    iterate_verdict)
      field="$(_d '.verdict')"; [[ -n "$field" ]] || field="$(_d '.result')"
      summary="verdict: ${field:-unknown}"
      ;;
    checkpoint_pr)
      field="$(_d '.url')"
      summary="checkpoint PR${field:+ $field}"
      ;;
    completed|paused|escalated)
      summary="$event"
      field="$(_d '.reason')"
      [[ -n "$field" ]] && summary="$summary - $field"
      ;;
    *)
      summary="$event"
      ;;
  esac
  # Stream resolution, strongest evidence first (probe contract: an explicit
  # operator override outranks the probe; unknown values fall back to the safe
  # default rather than silently choosing a stream):
  #   1. LOOP_SPEC_CONSOLE_STREAM=stdout|stderr  operator says so.
  #   2. Cloud Run's own stamps (CLOUD_RUN_JOB for jobs, K_SERVICE for services)
  #      -> stdout. Cloud Run assigns stderr output ERROR severity, so on the
  #      harness this plugin most often runs unattended on, routine progress on
  #      stderr surfaces in Cloud Logging as a stream of errors. The platform
  #      stamps these variables itself; this is a fact, not a judgment.
  #   3. default stderr: stdout carries the marker JSON that callers parse.
  local stream="${LOOP_SPEC_CONSOLE_STREAM:-}"
  if [[ "$stream" != "stdout" && "$stream" != "stderr" ]]; then
    if [[ -n "${CLOUD_RUN_JOB:-}" || -n "${K_SERVICE:-}" ]]; then
      stream="stdout"
    else
      stream="stderr"
    fi
  fi
  if [[ "$stream" == "stdout" ]]; then
    printf '[%s] %s\n' "$tag" "$summary"
  else
    printf '[%s] %s\n' "$tag" "$summary" >&2
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
    _console_line "$event" "$phase_str" "$data_val" "${elapsed:-}" "${verdict:-}"
    exit 0
    ;;
  *)
    echo "events.sh: bad invocation — usage: events.sh emit <feature_dir> <event> [--phase <phase>] [--data <json-object>]" >&2
    exit 0
    ;;
esac
