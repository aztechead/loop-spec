#!/usr/bin/env bash
# sentinel-triage.sh - Deterministic sentinel triage policy (ROADMAP-3.0 A2).
#
# Scores candidate work items from lib/sentinel-sources.sh and writes the
# ordered queue file. NO LLM calls: the policy is source-weight x recency x
# kind arithmetic, so the same inputs always produce the same queue — this is
# the "scripts authorize, the model proposes" constraint applied to intake.
# Items the policy cannot classify are queued as needs-human and surfaced by
# /loop-spec:status — never silently dropped, never silently run.
#
# Usage:
#   sentinel-triage.sh run [--in <file>] [--out <file>] [--conf <file>] [--now <epoch>]
#       Read a JSON array of candidates (stdin, or --in), score, write the
#       queue file (default .loop-spec/sentinel-queue.json), print it.
#       --now pins the recency clock for deterministic tests.
#   sentinel-triage.sh sources [--conf <file>]
#       Print the enabled adapter names, one per line (the scan orchestration
#       asks this before invoking lib/sentinel-sources.sh).
#   sentinel-triage.sh show [--out <file>]
#       Print the current queue file (exit 1 when none exists).
#
# Config (.loop-spec/sentinel.conf, KEY=VALUE lines, never sourced; every key
# optional — defaults below):
#   ENABLE_GH_ISSUES=1  ENABLE_CI_FAILURES=1  ENABLE_BACKLOG=1  ENABLE_ASSESSMENT=1
#   WEIGHT_GH_ISSUES=5  WEIGHT_CI_FAILURES=8  WEIGHT_BACKLOG=3  WEIGHT_ASSESSMENT=2
#   MAX_QUEUE_DEPTH=10
#
# Scoring: score = source_weight * kind_factor * recency_factor
#   kind:    bug=3  gap=2  chore=1   (anything else -> needs-human)
#   recency: updated <=2d ago = 3, <=7d = 2, older/unknown = 1
# Order: score desc, updatedAt desc, id asc (total order — no ties left to
# chance). The queue is truncated to MAX_QUEUE_DEPTH; a scan re-derives the
# whole queue from sources every time, so truncation loses nothing durable.
#
# Queue file schema (version 1):
#   {"schema": 1, "generatedAt": "ISO", "queue": [{item..., "score": N}],
#    "needsHuman": [{item..., "reason": "..."}]}
#
# Exit codes: 0 success, 1 no queue file (show), 2 bad invocation.
set -euo pipefail

_die2() { echo "sentinel-triage.sh: $*" >&2; exit 2; }

DEFAULT_CONF="${CLAUDE_PROJECT_DIR:-.}/.loop-spec/sentinel.conf"
DEFAULT_OUT="${CLAUDE_PROJECT_DIR:-.}/.loop-spec/sentinel-queue.json"

# conf_get <file> <key> <default> — first "KEY=<digits>" line wins; the file is
# parsed, never sourced (a conf file must not be able to run code).
conf_get() {
  local file="$1" key="$2" default="$3" val
  if [[ -f "$file" ]]; then
    val="$(grep -m1 -E "^${key}=[0-9]+$" "$file" 2>/dev/null | cut -d= -f2 || true)"
    [[ -n "$val" ]] && { printf '%s' "$val"; return; }
  fi
  printf '%s' "$default"
}

cmd="${1:-}"
shift || true

case "$cmd" in
  sources)
    CONF="$DEFAULT_CONF"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --conf) CONF="${2:-}"; shift 2 || shift ;;
        *) _die2 "unknown flag '$1' for sources" ;;
      esac
    done
    [[ "$(conf_get "$CONF" ENABLE_GH_ISSUES 1)" == "0" ]] || echo "gh-issues"
    [[ "$(conf_get "$CONF" ENABLE_CI_FAILURES 1)" == "0" ]] || echo "ci-failures"
    [[ "$(conf_get "$CONF" ENABLE_BACKLOG 1)" == "0" ]] || echo "backlog"
    [[ "$(conf_get "$CONF" ENABLE_ASSESSMENT 1)" == "0" ]] || echo "assessment"
    exit 0
    ;;

  show)
    OUT="$DEFAULT_OUT"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --out) OUT="${2:-}"; shift 2 || shift ;;
        *) _die2 "unknown flag '$1' for show" ;;
      esac
    done
    [[ -f "$OUT" ]] || { echo "sentinel-triage.sh: no queue file at $OUT (run a scan first)" >&2; exit 1; }
    jq . "$OUT"
    exit 0
    ;;

  run)
    IN=""; OUT="$DEFAULT_OUT"; CONF="$DEFAULT_CONF"; NOW=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --in) IN="${2:-}"; shift 2 || shift ;;
        --out) OUT="${2:-}"; shift 2 || shift ;;
        --conf) CONF="${2:-}"; shift 2 || shift ;;
        --now) NOW="${2:-}"; shift 2 || shift ;;
        *) _die2 "unknown flag '$1' for run" ;;
      esac
    done
    if [[ -n "$IN" ]]; then
      [[ -f "$IN" ]] || _die2 "input not found: $IN"
      candidates="$(jq -c . "$IN" 2>/dev/null)" || _die2 "input is not valid JSON: $IN"
    else
      candidates="$(jq -c . 2>/dev/null)" || _die2 "stdin is not valid JSON"
    fi
    jq -e 'type == "array"' >/dev/null 2>&1 <<<"$candidates" || _die2 "input must be a JSON array of candidates"
    [[ -z "$NOW" || "$NOW" =~ ^[0-9]+$ ]] || _die2 "--now must be a unix epoch (got '$NOW')"
    NOW="${NOW:-$(date -u +%s)}"

    w_gh="$(conf_get "$CONF" WEIGHT_GH_ISSUES 5)"
    w_ci="$(conf_get "$CONF" WEIGHT_CI_FAILURES 8)"
    w_bl="$(conf_get "$CONF" WEIGHT_BACKLOG 3)"
    w_as="$(conf_get "$CONF" WEIGHT_ASSESSMENT 2)"
    e_gh="$(conf_get "$CONF" ENABLE_GH_ISSUES 1)"
    e_ci="$(conf_get "$CONF" ENABLE_CI_FAILURES 1)"
    e_bl="$(conf_get "$CONF" ENABLE_BACKLOG 1)"
    e_as="$(conf_get "$CONF" ENABLE_ASSESSMENT 1)"
    depth="$(conf_get "$CONF" MAX_QUEUE_DEPTH 10)"

    mkdir -p "$(dirname "$OUT")"

    jq -c \
      --argjson now "$NOW" \
      --argjson depth "$depth" \
      --argjson weights "{\"gh-issues\": $w_gh, \"ci-failures\": $w_ci, \"backlog\": $w_bl, \"assessment\": $w_as}" \
      --argjson enabled "{\"gh-issues\": $e_gh, \"ci-failures\": $e_ci, \"backlog\": $e_bl, \"assessment\": $e_as}" \
      '
      def kind_factor: {bug: 3, gap: 2, chore: 1}[.kind // "unknown"];
      def recency_factor:
        (try ((.updatedAt // "") | fromdateiso8601) catch null) as $t
        | if $t == null then 1
          elif ($now - $t) <= 172800 then 3
          elif ($now - $t) <= 604800 then 2
          else 1 end;

      # Drop disabled sources first (defense in depth: the scan already skips
      # invoking them; a stale --in file must not resurrect one). Unknown
      # sources fall through to needs-human below — configured-off is a user
      # decision, unrecognized is not.
      map(select(($enabled[.source // ""] // 1) != 0)) as $live

      | ($live | map(select(
          (.id // "") == "" or (.title // "") == "" or kind_factor == null
          or ($weights[.source // ""] // null) == null))
         | map(. + {reason:
             (if (.id // "") == "" or (.title // "") == "" then "missing-id-or-title"
              elif ($weights[.source // ""] // null) == null then "unknown-source"
              else "unclassifiable-kind" end)})) as $needs_human

      | ($live | map(select(
          (.id // "") != "" and (.title // "") != "" and kind_factor != null
          and ($weights[.source // ""] // null) != null))
         | map(. + {score: (($weights[.source]) * kind_factor * recency_factor)})
         | sort_by([-.score, -(try ((.updatedAt // "") | fromdateiso8601) catch 0), .id])
         | .[0:$depth]) as $queue

      | {schema: 1,
         generatedAt: ($now | todate),
         queue: $queue,
         needsHuman: $needs_human}
      ' <<<"$candidates" > "$OUT.tmp"
    mv "$OUT.tmp" "$OUT"
    jq . "$OUT"
    exit 0
    ;;

  *)
    _die2 "unknown subcommand '${cmd:-}' (run|sources|show)"
    ;;
esac
