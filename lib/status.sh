#!/usr/bin/env bash
# status.sh - Read-only consumer of loop-spec telemetry (feature.json,
# delivery.json, events.jsonl, result.json). The command surface behind /loop-spec:status.
#
# Usage:
#   status.sh [--root <dir>] [--json] [status] [<slug>]
#       Per-feature status: slug, phase, iterations, last event, warnings,
#       result status, PR URLs. With <slug>, only that feature.
#
#   status.sh [--root <dir>] [--json] stats
#       Aggregates across ALL features: runs by result status, convergence
#       rate, iteration usage, gate_round counts per gate, iterate_verdict gap
#       histogram, dispatch counts by model/role/rung, and loop-fleet cost
#       (.loop/fleet-result.json totals when present).
#
#   status.sh [--root <dir>] [--json] metrics [--digests <dir>]
#       THE METRICS CONTRACT (ROADMAP-3.0 B3): the stable, schema-versioned
#       numbers the other pillars consume — trust (lib/trust.sh) and tuning
#       read THIS output instead of re-deriving from raw telemetry. Computed
#       from the COMMITTED run digests (docs/loop-spec/telemetry/runs/*.json,
#       lib/run-digest.sh), not local events — the contract must survive
#       volatile agents. Keys are append-only across schema 1; a signal whose
#       producer has not run yet (no watch verdicts, no sentinel picks) is
#       present as null, so consumers can already bind to it and fail closed
#       on null. Always JSON (--json accepted for symmetry).
#
# --root defaults to ${CLAUDE_PROJECT_DIR:-.}/.loop-spec.
# Unlike the writers (events.sh/cycle-result.sh) this is a USER-FACING reader:
# it uses normal exit codes. 0 = ok (including "no features yet"), 2 = bad args.
set -uo pipefail

ROOT=""
JSON=0
CMD="status"
SLUG=""
DIGESTS_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 || shift ;;
    --json) JSON=1; shift ;;
    --digests) DIGESTS_DIR="${2:-}"; shift 2 || shift ;;
    status|stats|metrics) CMD="$1"; shift ;;
    -*) echo "status.sh: unknown flag '$1' (usage: status.sh [--root <dir>] [--json] [status|stats|metrics] [<slug>])" >&2; exit 2 ;;
    *) SLUG="$1"; shift ;;
  esac
done

ROOT="${ROOT:-${CLAUDE_PROJECT_DIR:-.}/.loop-spec}"
FEATURES_DIR="$ROOT/features"

# Collect one JSON object per feature dir (tolerant: every file optional).
_collect() {
  local now
  now="$(date -u +%s)"
  local first=1
  echo "["
  if [[ -d "$FEATURES_DIR" ]]; then
    for fdir in "$FEATURES_DIR"/*/; do
      [[ -d "$fdir" ]] || continue
      local slug; slug="$(basename "$fdir")"
      [[ -n "$SLUG" && "$slug" != "$SLUG" ]] && continue

      local fj="{}" dj="null" rj="null" last_event="null" events="[]"
      [[ -f "$fdir/feature.json" ]] && fj="$(cat "$fdir/feature.json" 2>/dev/null || echo '{}')"
      jq -e . >/dev/null 2>&1 <<<"$fj" || fj="{}"
      [[ -f "$fdir/delivery.json" ]] && dj="$(cat "$fdir/delivery.json" 2>/dev/null || echo 'null')"
      jq -e . >/dev/null 2>&1 <<<"$dj" || dj="null"
      [[ -f "$fdir/result.json" ]] && rj="$(cat "$fdir/result.json" 2>/dev/null || echo 'null')"
      jq -e . >/dev/null 2>&1 <<<"$rj" || rj="null"
      if [[ -f "$fdir/events.jsonl" ]]; then
        events="$(jq -cs 'map(select(type == "object"))' "$fdir/events.jsonl" 2>/dev/null || echo '[]')"
        last_event="$(jq -c '.[-1] // null' <<<"$events" 2>/dev/null || echo 'null')"
      fi

      [[ "$first" == "1" ]] || echo ","
      first=0
      jq -cn \
        --arg slug "$slug" \
        --argjson now "$now" \
        --argjson fj "$fj" \
        --argjson dj "$dj" \
        --argjson rj "$rj" \
        --argjson last_event "$last_event" \
        --argjson events "$events" \
        '{
          slug: $slug,
          phase: (if ($rj.status // "") == "completed" or
                         (($dj.nextPhase // "") == "completed" and
                          ($dj.status // "") == "ready-for-review")
                  then "completed" else ($fj.currentPhase // null) end),
          iterations: {
            used: ($fj.iterate.used // 0),
            max: ($fj.iterate.maxIterations // null)
          },
          warnings: (($fj.warnings // []) | length),
          resultStatus: ($rj.status // null),
          converged: (if ($rj | type) == "object" and ($rj | has("converged")) then $rj.converged else null end),
          prUrl: ($rj.prUrl // $dj.prUrl // $fj.prUrl // null),
          checkpointPrUrl: ($fj.checkpointPrUrl // null),
          deliveryStatus: ($rj.delivery.status // $dj.status // $fj.delivery.status // null),
          autonomous: ($fj.autonomous // false),
          lastEvent: (if $last_event == null then null else {
            event: $last_event.event,
            phase: $last_event.phase,
            ts: $last_event.ts,
            ageSeconds: (try ($now - ($last_event.ts | fromdateiso8601)) catch null)
          } end),
          events: $events
        }'
    done
  fi
  echo "]"
}

_age_human() { # seconds -> "3m" / "2h" / "5d" / "-"
  local s="$1"
  if [[ -z "$s" || "$s" == "null" ]]; then echo "-"; return; fi
  if (( s < 0 )); then echo "-"; return; fi
  if (( s < 3600 )); then echo "$(( s / 60 ))m"
  elif (( s < 86400 )); then echo "$(( s / 3600 ))h"
  else echo "$(( s / 86400 ))d"; fi
}

FEATURES_JSON="$(_collect | jq -cs 'add // []' 2>/dev/null)" || FEATURES_JSON="[]"
# _collect prints an array already; the jq -cs add flattens the single array.
if ! jq -e 'type == "array"' >/dev/null 2>&1 <<<"$FEATURES_JSON"; then
  FEATURES_JSON="[]"
fi

case "$CMD" in
  status)
    # Strip the raw event list from per-feature status output (stats-only detail).
    OUT="$(jq -c 'map(del(.events))' <<<"$FEATURES_JSON")"
    if [[ "$JSON" == "1" ]]; then
      jq . <<<"$OUT"
      exit 0
    fi
    COUNT="$(jq 'length' <<<"$OUT")"
    if [[ "$COUNT" == "0" ]]; then
      echo "no loop-spec features found under $FEATURES_DIR"
      exit 0
    fi
    printf '%-28s %-10s %-6s %-22s %-5s %-9s %s\n' "SLUG" "PHASE" "ITER" "LAST EVENT" "WARN" "RESULT" "PR"
    while IFS= read -r row; do
      slug="$(jq -r '.slug' <<<"$row")"
      phase="$(jq -r '.phase // "-"' <<<"$row")"
      iter="$(jq -r '"\(.iterations.used)/\(.iterations.max // "-")"' <<<"$row")"
      ev="$(jq -r '.lastEvent.event // "-"' <<<"$row")"
      age="$(_age_human "$(jq -r '.lastEvent.ageSeconds // "null"' <<<"$row")")"
      warn="$(jq -r '.warnings' <<<"$row")"
      res="$(jq -r '.resultStatus // "-"' <<<"$row")"
      pr="$(jq -r '.prUrl // .checkpointPrUrl // "-"' <<<"$row")"
      printf '%-28s %-10s %-6s %-22s %-5s %-9s %s\n' \
        "$slug" "$phase" "$iter" "$ev ($age ago)" "$warn" "$res" "$pr"
    done < <(jq -c '.[]' <<<"$OUT")
    exit 0
    ;;

  stats)
    # Loop-fleet cost, when a fleet ran from this root's project dir.
    FLEET_COST="null"
    FLEET_FILE="$(dirname "$ROOT")/.loop/fleet-result.json"
    if [[ -f "$FLEET_FILE" ]]; then
      FLEET_COST="$(jq -c '.total_cost_usd // null' "$FLEET_FILE" 2>/dev/null || echo null)"
    fi

    STATS="$(jq -cn --argjson feats "$FEATURES_JSON" --argjson fleetCost "$FLEET_COST" '
      ($feats | map(.events) | add // []) as $all_events |
      {
        features: {
          total: ($feats | length),
          byResultStatus: ($feats | map(.resultStatus // "in-flight") | group_by(.)
                           | map({key: .[0], value: length}) | from_entries)
        },
        convergence: {
          finished: ($feats | map(select(.resultStatus != null)) | length),
          converged: ($feats | map(select(.converged == true)) | length),
          rate: (($feats | map(select(.resultStatus != null)) | length) as $n
                 | if $n == 0 then null
                   else (($feats | map(select(.converged == true)) | length) / $n * 100 | round / 100)
                   end)
        },
        iterations: {
          avgUsed: (($feats | length) as $n
                    | if $n == 0 then null
                      else (($feats | map(.iterations.used) | add) / $n * 100 | round / 100)
                      end),
          maxUsed: ($feats | map(.iterations.used) | max // null)
        },
        gateRounds: ($all_events | map(select(.event == "gate_round"))
                     | group_by(.data.gate // "unknown")
                     | map({key: (.[0].data.gate // "unknown"), value: length}) | from_entries),
        iterateGaps: ($all_events | map(select(.event == "iterate_verdict"))
                      | group_by(.data.gap // "unknown")
                      | map({key: (.[0].data.gap // "unknown"), value: length}) | from_entries),
        dispatches: ($all_events | map(select(.event == "dispatch")) as $d | {
          total: ($d | length),
          byModel: ($d | group_by(.data.model // "unknown")
                    | map({key: (.[0].data.model // "unknown"), value: length}) | from_entries),
          byRole: ($d | group_by(.data.role // "unknown")
                   | map({key: (.[0].data.role // "unknown"), value: length}) | from_entries),
          byRung: ($d | group_by(.data.rung // "unknown")
                   | map({key: (.[0].data.rung // "unknown"), value: length}) | from_entries)
        }),
        loopFleetCostUsd: $fleetCost
      }')"

    if [[ "$JSON" == "1" ]]; then
      jq . <<<"$STATS"
      exit 0
    fi
    echo "loop-spec stats ($FEATURES_DIR)"
    echo ""
    jq -r '
      "features: \(.features.total) total  \(.features.byResultStatus | to_entries | map("\(.key)=\(.value)") | join("  "))",
      "convergence: \(.convergence.converged)/\(.convergence.finished) finished converged\(if .convergence.rate != null then " (rate \(.convergence.rate))" else "" end)",
      "iterations: avg \(.iterations.avgUsed // "-")  max \(.iterations.maxUsed // "-")",
      "gate rounds: \(if (.gateRounds | length) == 0 then "none recorded" else (.gateRounds | to_entries | map("\(.key)=\(.value)") | join("  ")) end)",
      "iterate gaps: \(if (.iterateGaps | length) == 0 then "none recorded" else (.iterateGaps | to_entries | map("\(.key)=\(.value)") | join("  ")) end)",
      "dispatches: \(.dispatches.total) total",
      "  by model: \(if (.dispatches.byModel | length) == 0 then "-" else (.dispatches.byModel | to_entries | map("\(.key)=\(.value)") | join("  ")) end)",
      "  by role:  \(if (.dispatches.byRole | length) == 0 then "-" else (.dispatches.byRole | to_entries | map("\(.key)=\(.value)") | join("  ")) end)",
      "  by rung:  \(if (.dispatches.byRung | length) == 0 then "-" else (.dispatches.byRung | to_entries | map("\(.key)=\(.value)") | join("  ")) end)",
      "loop-fleet cost: \(if .loopFleetCostUsd != null then "$\(.loopFleetCostUsd)" else "n/a (no fleet-result.json or cost not reported)" end)"
    ' <<<"$STATS"
    exit 0
    ;;

  metrics)
    # The B3 contract. Schema 1 keys (append-only; never rename, never remove):
    #   schema, source, runs, converged, convergenceRate, firstPassRate,
    #   consecutiveConverged, consecutiveFirstPass, gapCounts,
    #   verifyFailureClassCounts, postMergeFixRate, verifyFailureRate,
    #   sentinelNeedsHumanRate, watchWindowClean
    # Pinned by tests/lib/status.test.sh — a key change is a schema bump.
    # gapCounts / verifyFailureClassCounts count RUNS exhibiting each gap /
    # verify-failure class (digests carry them unique-per-run), which is the
    # recurrence definition lib/tuning.sh and lib/retro.sh share.
    # postMergeFixRate / watchWindowClean are computed over runs that CARRY a
    # watch verdict (lib/watch.sh, C2) — null until one exists, so trust.sh
    # keeps failing closed. sentinelNeedsHumanRate reads the LOCAL scan
    # history (<root>/sentinel-events.jsonl): needs-human / (needs-human +
    # picked); null until the sentinel has both scanned and run.
    DIGESTS_DIR="${DIGESTS_DIR:-$(dirname "$ROOT")/docs/loop-spec/telemetry/runs}"
    DIGESTS="[]"
    if [[ -d "$DIGESTS_DIR" ]]; then
      for f in "$DIGESTS_DIR"/*.json; do
        [[ -f "$f" ]] || continue
        d="$(cat "$f" 2>/dev/null || echo null)"
        jq -e 'type == "object"' >/dev/null 2>&1 <<<"$d" || continue
        DIGESTS="$(jq -c --argjson d "$d" '. + [$d]' <<<"$DIGESTS")"
      done
    fi
    SENTINEL_EVENTS="[]"
    if [[ -f "$ROOT/sentinel-events.jsonl" ]]; then
      SENTINEL_EVENTS="$(jq -cs 'map(select(type == "object"))' "$ROOT/sentinel-events.jsonl" 2>/dev/null || echo '[]')"
    fi
    jq -n --argjson runs "$DIGESTS" --arg src "$DIGESTS_DIR" --argjson sentinel "$SENTINEL_EVENTS" '
      ($runs | sort_by(.finishedAt // "")) as $ordered
      | ($ordered | length) as $n
      | ($ordered | map(select(.converged == true)) | length) as $conv
      | ($ordered | map(select(.converged == true and ((.iterations.used // 0) <= 1))) | length) as $fp
      | ($ordered | reverse | map(.converged == true) | (index(false) // length)) as $streak
      | ($ordered | reverse | map(.converged == true and ((.iterations.used // 0) <= 1))
         | (index(false) // length)) as $fpStreak
      | ($ordered | map(select((.verifyFailureClasses // []) | length > 0)) | length) as $vfRuns
      | ($ordered | map(select(.watch != null))) as $watched
      | ($watched | map(select((.watch.humanFixCommits // 0) > 0)) | length) as $fixed
      | ($sentinel | map(select(.event == "needs-human")) | length) as $nh
      | ($sentinel | map(select(.event == "picked")) | length) as $picked
      | {
          schema: 1,
          source: $src,
          runs: $n,
          converged: $conv,
          convergenceRate: (if $n == 0 then null else ($conv / $n * 100 | round / 100) end),
          firstPassRate: (if $n == 0 then null else ($fp / $n * 100 | round / 100) end),
          consecutiveConverged: $streak,
          consecutiveFirstPass: $fpStreak,
          gapCounts: ([$ordered[] | (.gaps // [])[]] | group_by(.)
                      | map({key: .[0], value: length}) | from_entries),
          verifyFailureClassCounts: ([$ordered[] | (.verifyFailureClasses // [])[]] | group_by(.)
                                     | map({key: .[0], value: length}) | from_entries),
          postMergeFixRate: (($watched | length) as $w
                             | if $w == 0 then null else ($fixed / $w * 100 | round / 100) end),
          verifyFailureRate: (if $n == 0 then null else ($vfRuns / $n * 100 | round / 100) end),
          sentinelNeedsHumanRate: (($nh + $picked) as $d
                                   | if $d == 0 then null else ($nh / $d * 100 | round / 100) end),
          watchWindowClean: (if ($watched | length) == 0 then null
                             else ($watched | all(.watch.clean == true)) end)
        }'
    exit 0
    ;;
esac
