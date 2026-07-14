#!/usr/bin/env bash
# autonomous-chain.sh - The autonomous continuation-chain predicate, made deterministic.
#
# The cycle's On-completion section decides whether an autonomous run chains into
# backlog-drain mode for the gaps ITERATE just queued (skills/shared/autonomous-mode.md,
# continuation ladder rungs 4-5). That decision is a pure boolean over durable state;
# re-deriving it from prose every completion risks one probabilistic miss on a bound —
# and a missed "never chain past a failure" in a headless overnight run is a runaway
# loop. This script IS the predicate; the skill calls it and obeys the verdict.
#
# Usage:
#   autonomous-chain.sh should-chain <feature_dir> [--completed <n>] [--scope backlog|queue]
#       <feature_dir>    Directory containing the just-completed feature.json.
#       --completed <n>  Features already completed this invocation (default 0).
#       --scope          backlog (default): the 2.x backlog-drain chain, bounded
#                        by LOOP_SPEC_MAX_FEATURES.
#                        queue: the sentinel batch chain (ROADMAP-3.0 A3+A4).
#                        Supply comes from the sentinel queue (via
#                        lib/sentinel-run.sh next --peek) and the bound comes
#                        from the trust governor (lib/trust.sh authorize
#                        --action sentinel-batch) — L0 caps batches at 1, L1
#                        honors LOOP_SPEC_MAX_FEATURES up to BATCH_L1.
#   Queue-scope flags (fixture seams for tests, forwarded verbatim):
#       --queue <file> --events <file> --conf <file>       -> sentinel-run.sh
#       --trust-conf <file> --trust-metrics <file>         -> trust.sh
#
# Output (stdout, one line of JSON):
#   {"chain": true,  "entry": {...next backlog entry / queue item json...}}
#   {"chain": false, "reason": "<why>"}
#
# Reasons (stable strings, in check order):
#   both scopes:  not-autonomous, feature-not-completed, delivery-incomplete
#   backlog:      no-budget-spent-gaps, max-features-reached, backlog-empty,
#                 next-entry-terminal
#   queue:        sentinel-batch-denied  trust.sh said no (bound reached)
#                 trust-unavailable      trust.sh errored — FAIL CLOSED, no chain
#                 queue-exhausted        no eligible queue item (empty/cooling)
#
# Exit codes: 0 predicate evaluated (answer in JSON), 1 bad invocation / unreadable state.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKLOG="$SCRIPT_DIR/backlog.sh"
TRUST="$SCRIPT_DIR/trust.sh"
SENTINEL_RUN="$SCRIPT_DIR/sentinel-run.sh"

no_chain() {
  jq -cn --arg r "$1" '{chain: false, reason: $r}'
  exit 0
}

cmd="${1:-}"
[[ "$cmd" == "should-chain" ]] || {
  echo "usage: autonomous-chain.sh should-chain <feature_dir> [--completed <n>] [--scope backlog|queue]" >&2
  exit 1
}

feature_dir="${2:-}"
[[ -n "$feature_dir" && -f "$feature_dir/feature.json" ]] || {
  echo "autonomous-chain: feature.json not found in '${feature_dir}'" >&2
  exit 1
}
shift 2

completed=0
scope="backlog"
queue_file=""; events_file=""; conf_file=""
trust_conf=""; trust_metrics=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --completed) completed="${2:-}"; shift 2 || shift ;;
    --scope) scope="${2:-}"; shift 2 || shift ;;
    --queue) queue_file="${2:-}"; shift 2 || shift ;;
    --events) events_file="${2:-}"; shift 2 || shift ;;
    --conf) conf_file="${2:-}"; shift 2 || shift ;;
    --trust-conf) trust_conf="${2:-}"; shift 2 || shift ;;
    --trust-metrics) trust_metrics="${2:-}"; shift 2 || shift ;;
    *) echo "autonomous-chain: unknown flag '$1'" >&2; exit 1 ;;
  esac
done
[[ "$completed" =~ ^[0-9]+$ ]] || {
  echo "autonomous-chain: --completed requires a non-negative integer" >&2
  exit 1
}
case "$scope" in backlog|queue) ;; *)
  echo "autonomous-chain: --scope must be backlog or queue (got '$scope')" >&2
  exit 1 ;;
esac

fj="$feature_dir/feature.json"
jq -e . "$fj" >/dev/null 2>&1 || {
  echo "autonomous-chain: feature.json is not valid JSON: $fj" >&2
  exit 1
}

# Check order mirrors the ladder: eligibility, then safety, then bounds, then supply.
[[ "$(jq -r '.autonomous // false' "$fj")" == "true" ]] || no_chain "not-autonomous"

delivery_file="$feature_dir/delivery.json"
sidecar_delivery="null"
if [[ -f "$delivery_file" ]]; then
  sidecar_delivery="$(jq -c . "$delivery_file" 2>/dev/null || echo null)"
fi
tracked_phase="$(jq -r '.currentPhase // ""' "$fj")"
if [[ "$tracked_phase" != "completed" ]]; then
  [[ "$(jq -r '.nextPhase == "completed" and .status == "ready-for-review"' \
      <<<"$sidecar_delivery" 2>/dev/null)" == "true" ]] || no_chain "feature-not-completed"
fi

# New seven-phase runs may chain only after DELIVER reached a review-ready PR.
# A missing delivery block is accepted for completed schema-7 state created by
# older plugin versions; an explicit non-ready state fails closed.
if [[ "$sidecar_delivery" != "null" ]]; then
  [[ "$(jq -r '.status // ""' <<<"$sidecar_delivery")" == "ready-for-review" ]] \
    || no_chain "delivery-incomplete"
else
  has_delivery="$(jq -r 'has("delivery")' "$fj")"
  if [[ "$has_delivery" == "true" ]]; then
    [[ "$(jq -r '.delivery.status // ""' "$fj")" == "ready-for-review" ]] \
      || no_chain "delivery-incomplete"
  fi
fi

if [[ "$scope" == "queue" ]]; then
  # Bound: the governor decides, this predicate obeys (D3: authority checks
  # live in the scripts that act). trust.sh unavailable/erroring fails CLOSED.
  trust_args=(--action sentinel-batch --completed "$completed")
  [[ -n "$trust_conf" ]] && trust_args+=(--conf "$trust_conf")
  [[ -n "$trust_metrics" ]] && trust_args+=(--metrics-json "$trust_metrics")
  trust_ec=0
  bash "$TRUST" authorize "${trust_args[@]}" >/dev/null 2>&1 || trust_ec=$?
  [[ "$trust_ec" -eq 1 ]] && no_chain "sentinel-batch-denied"
  [[ "$trust_ec" -eq 0 ]] || no_chain "trust-unavailable"

  # Supply: first eligible queue item, WITHOUT recording a pick — the skill
  # records the pick when it actually starts the item.
  next_args=(--peek)
  [[ -n "$queue_file" ]] && next_args+=(--queue "$queue_file")
  [[ -n "$events_file" ]] && next_args+=(--events "$events_file")
  [[ -n "$conf_file" ]] && next_args+=(--conf "$conf_file")
  entry_json="$(bash "$SENTINEL_RUN" next "${next_args[@]}" 2>/dev/null)" || no_chain "queue-exhausted"

  jq -cn --argjson e "$entry_json" '{chain: true, entry: $e}'
  exit 0
fi

n_gaps="$(jq -r '[(.warnings // [])[] | select(type == "string" and startswith("iterate-budget-spent:"))] | length' "$fj")"
[[ "$n_gaps" -gt 0 ]] || no_chain "no-budget-spent-gaps"

max_features="${LOOP_SPEC_MAX_FEATURES:-1}"
[[ "$max_features" =~ ^[0-9]+$ ]] || max_features=1
[[ "$completed" -lt "$max_features" ]] || no_chain "max-features-reached"

entry_json="$(bash "$BACKLOG" next --json 2>/dev/null)" || no_chain "backlog-empty"

gid="$(jq -r '.id // empty' <<<"$entry_json")"
if [[ -n "$gid" ]] && bash "$BACKLOG" is-terminal "$gid" 2>/dev/null; then
  no_chain "next-entry-terminal"
fi

jq -cn --argjson e "$entry_json" '{chain: true, entry: $e}'
