#!/usr/bin/env bash
# sentinel-run.sh - Deterministic drive-loop mechanics for `sentinel run`
# (ROADMAP-3.0 A3+A4).
#
# The queue file (lib/sentinel-triage.sh) is a re-derived VIEW — it never
# remembers what has already been attempted. This script is that memory: `next`
# picks the first queue item not recently picked (so a failing item cannot be
# re-picked in a thrash loop the same night), and `record` appends every
# sentinel decision to the scan history so /status and /retro see it — picked,
# skipped, and needs-human items are never silently dropped, never silently
# run. The skill calls these verbs and obeys them; it never re-derives the
# eligibility rule in prose.
#
# Usage:
#   sentinel-run.sh next [--queue <file>] [--events <file>] [--conf <file>]
#                        [--now <epoch>] [--peek]
#       Print the first eligible queue item (JSON object). Eligible = in the
#       queue AND without a `picked` event newer than PICK_COOLDOWN_HOURS
#       (conf, default 24). Records the pick in the events file unless --peek.
#       Exit 1 when nothing is eligible (reason on stderr: no-queue-file |
#       queue-empty | all-cooling-down).
#   sentinel-run.sh record <event> --id <id> [--source <s>] [--reason <r>]
#                          [--events <file>]
#       Append {ts, event, id, source, reason} to the scan history
#       (.loop-spec/sentinel-events.jsonl). Observability contract: never
#       fails (warn + exit 0), same as the triage history writer.
#
# Config (.loop-spec/sentinel.conf, KEY=VALUE lines, parsed never sourced):
#   PICK_COOLDOWN_HOURS=24
#
# Exit codes: next: 0 item printed, 1 nothing eligible, 2 bad invocation.
#             record: 0 (including a skipped write — warn-only), 2 bad invocation.
set -euo pipefail

_die2() { echo "sentinel-run.sh: $*" >&2; exit 2; }

DEFAULT_QUEUE="${CLAUDE_PROJECT_DIR:-.}/.loop-spec/sentinel-queue.json"
DEFAULT_CONF="${CLAUDE_PROJECT_DIR:-.}/.loop-spec/sentinel.conf"

conf_get() {
  local file="$1" key="$2" default="$3" val
  if [[ -f "$file" ]]; then
    val="$(grep -m1 -E "^${key}=[0-9]+$" "$file" 2>/dev/null | cut -d= -f2 || true)"
    [[ -n "$val" ]] && { printf '%s' "$val"; return; }
  fi
  printf '%s' "$default"
}

# append_event <events-file> <event> <id> <source> <reason>
# Warn-only: a broken history writer must never fail the drive loop.
append_event() {
  local file="$1" event="$2" id="$3" source="$4" reason="$5"
  mkdir -p "$(dirname "$file")" 2>/dev/null || true
  jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg event "$event" --arg id "$id" --arg source "$source" --arg reason "$reason" \
    '{ts: $ts, event: $event,
      id: (if $id == "" then null else $id end),
      source: (if $source == "" then null else $source end),
      reason: (if $reason == "" then null else $reason end)}' \
    >> "$file" 2>/dev/null \
    || echo "sentinel-run.sh: WARN could not append '$event' to $file" >&2
}

cmd="${1:-}"
shift || true

case "$cmd" in
  next)
    QUEUE="$DEFAULT_QUEUE"; EVENTS=""; CONF="$DEFAULT_CONF"; NOW=""; PEEK=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --queue) QUEUE="${2:-}"; shift 2 || shift ;;
        --events) EVENTS="${2:-}"; shift 2 || shift ;;
        --conf) CONF="${2:-}"; shift 2 || shift ;;
        --now) NOW="${2:-}"; shift 2 || shift ;;
        --peek) PEEK=1; shift ;;
        *) _die2 "unknown flag '$1' for next" ;;
      esac
    done
    [[ -z "$NOW" || "$NOW" =~ ^[0-9]+$ ]] || _die2 "--now must be a unix epoch (got '$NOW')"
    NOW="${NOW:-$(date -u +%s)}"
    EVENTS="${EVENTS:-$(dirname "$QUEUE")/sentinel-events.jsonl}"

    if [[ ! -f "$QUEUE" ]]; then
      echo "sentinel-run.sh: no-queue-file: $QUEUE (run a scan first)" >&2
      exit 1
    fi
    queue="$(jq -c '.queue // []' "$QUEUE" 2>/dev/null)" || _die2 "queue file is not valid JSON: $QUEUE"
    if [[ "$(jq 'length' <<<"$queue")" == "0" ]]; then
      echo "sentinel-run.sh: queue-empty: $QUEUE" >&2
      exit 1
    fi

    cooldown_h="$(conf_get "$CONF" PICK_COOLDOWN_HOURS 24)"
    picks="[]"
    if [[ -f "$EVENTS" ]]; then
      picks="$(jq -cs 'map(select(type == "object" and .event == "picked"))' "$EVENTS" 2>/dev/null || echo '[]')"
    fi

    item="$(jq -cn --argjson queue "$queue" --argjson picks "$picks" \
      --argjson now "$NOW" --argjson cooldown "$(( cooldown_h * 3600 ))" '
      # ids picked within the cooldown window are ineligible
      ([$picks[]
        | select((try (.ts | fromdateiso8601) catch null) as $t
                 | $t != null and ($now - $t) < $cooldown)
        | .id] | unique) as $cooling
      | [$queue[] | select((.id // "") as $id | ($cooling | index($id)) == null)]
      | first // empty')"
    if [[ -z "$item" ]]; then
      echo "sentinel-run.sh: all-cooling-down: every queue item was picked within ${cooldown_h}h" >&2
      exit 1
    fi

    if [[ "$PEEK" != "1" ]]; then
      append_event "$EVENTS" picked \
        "$(jq -r '.id // ""' <<<"$item")" "$(jq -r '.source // ""' <<<"$item")" ""
    fi
    printf '%s\n' "$item"
    exit 0
    ;;

  record)
    event="${1:-}"
    [[ -n "$event" ]] || _die2 "record needs an event name (record <event> --id <id> ...)"
    shift
    ID=""; SOURCE=""; REASON=""; EVENTS=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --id) ID="${2:-}"; shift 2 || shift ;;
        --source) SOURCE="${2:-}"; shift 2 || shift ;;
        --reason) REASON="${2:-}"; shift 2 || shift ;;
        --events) EVENTS="${2:-}"; shift 2 || shift ;;
        *) _die2 "unknown flag '$1' for record" ;;
      esac
    done
    [[ -n "$ID" ]] || { echo "sentinel-run.sh: WARN record without --id; skipped" >&2; exit 0; }
    EVENTS="${EVENTS:-$(dirname "$DEFAULT_QUEUE")/sentinel-events.jsonl}"
    append_event "$EVENTS" "$event" "$ID" "$SOURCE" "$REASON"
    exit 0
    ;;

  *)
    _die2 "unknown subcommand '${cmd:-}' (next|record)"
    ;;
esac
