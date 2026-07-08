#!/usr/bin/env bash
# retro.sh - Deterministic retrospective miner: turns accumulated telemetry
# (events.jsonl + result.json + feature.json across features) into findings —
# rule candidates, suggestions, and informational stats. The engine behind
# /loop-spec:retro; the piece that closes the telemetry circuit: measurement
# (lib/status.sh) -> pattern -> permanent rule (lib/rules.sh).
#
# Usage:
#   retro.sh report [--root <dir>] [--json] [--min-repeats N]
#       Mine patterns and print findings. READ-ONLY. Default root
#       ${CLAUDE_PROJECT_DIR:-.}/.loop-spec, default min-repeats 3.
#
#   retro.sh apply [--root <dir>] [--min-repeats N]
#       Run the same report, then add every rule-candidate to the PROJECT
#       rules layer via lib/rules.sh add (idempotent — rule text is
#       count-free by design so re-applies dedupe). Prints added/exists per
#       rule. Suggestions and info findings are never auto-applied.
#
# Finding kinds:
#   rule-candidate  repeated failure pattern -> a rule the loop should carry
#   suggestion      an optimization backed by evidence (e.g. modelTier), user's call
#   info            aggregate facts worth seeing (convergence, cost)
#
# Detected patterns (all thresholds explicit, nothing model-judged):
#   - iterate gap type (plan/execute/spec) recurring across >= N features
#   - a critique gate hitting its round cap across >= N features
#   - first-pass convergence streak (>= N converged with <= 1 iteration)
#     -> modelTier: mechanical suggestion
#   - completed-but-not-converged runs (>= 2) -> info warning
#   - loop-fleet cost total when present -> info
#
# Rule text is deliberately COUNT-FREE and stable so lib/rules.sh idempotency
# holds as evidence accumulates; counts live in the finding's evidence field.
#
# Exit codes: 0 ok (including zero findings); 2 bad invocation.
set -uo pipefail

_die2() { echo "retro.sh: $*" >&2; exit 2; }

cmd="${1:-}"
[[ "$cmd" == "report" || "$cmd" == "apply" ]] \
  || _die2 "unknown subcommand '${cmd:-}' (usage: retro.sh report|apply [--root <dir>] [--json] [--min-repeats N])"
shift

ROOT=""
JSON=0
MIN=3
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 || shift ;;
    --json) JSON=1; shift ;;
    --min-repeats) MIN="${2:-3}"; shift 2 || shift ;;
    *) _die2 "unknown flag '$1'" ;;
  esac
done
[[ "$MIN" =~ ^[0-9]+$ ]] || _die2 "--min-repeats must be a number (got '$MIN')"

ROOT="${ROOT:-${CLAUDE_PROJECT_DIR:-.}/.loop-spec}"
FEATURES_DIR="$ROOT/features"
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Collect one object per feature (tolerant of anything missing/corrupt) ─────
_collect() {
  local first=1
  echo "["
  if [[ -d "$FEATURES_DIR" ]]; then
    for fdir in "$FEATURES_DIR"/*/; do
      [[ -d "$fdir" ]] || continue
      local slug fj rj events
      slug="$(basename "$fdir")"
      fj="{}"; rj="null"; events="[]"
      [[ -f "$fdir/feature.json" ]] && fj="$(cat "$fdir/feature.json" 2>/dev/null || echo '{}')"
      jq -e . >/dev/null 2>&1 <<<"$fj" || fj="{}"
      [[ -f "$fdir/result.json" ]] && rj="$(cat "$fdir/result.json" 2>/dev/null || echo 'null')"
      jq -e . >/dev/null 2>&1 <<<"$rj" || rj="null"
      if [[ -f "$fdir/events.jsonl" ]]; then
        events="$(jq -cs 'map(select(type == "object"))' "$fdir/events.jsonl" 2>/dev/null || echo '[]')"
      fi
      [[ "$first" == "1" ]] || echo ","
      first=0
      jq -cn --arg slug "$slug" --argjson fj "$fj" --argjson rj "$rj" --argjson events "$events" \
        '{slug: $slug,
          converged: (if ($rj | type) == "object" and ($rj | has("converged")) then $rj.converged else null end),
          resultStatus: ($rj.status // null),
          iterationsUsed: ($rj.iterations.used // $fj.iterate.used // 0),
          events: $events}'
    done
  fi
  echo "]"
}

FEATS="$(_collect | jq -cs 'add // []' 2>/dev/null)" || FEATS="[]"
jq -e 'type == "array"' >/dev/null 2>&1 <<<"$FEATS" || FEATS="[]"

FLEET_COST="null"
FLEET_FILE="$(dirname "$ROOT")/.loop/fleet-result.json"
if [[ -f "$FLEET_FILE" ]]; then
  FLEET_COST="$(jq -c '.total_cost_usd // null' "$FLEET_FILE" 2>/dev/null || echo null)"
fi

FINDINGS="$(jq -cn --argjson feats "$FEATS" --argjson min "$MIN" --argjson fleetCost "$FLEET_COST" '
  def featsWithGap(g): [$feats[] | select([.events[] | select(.event == "iterate_verdict" and (.data.gap // "") == g)] | length > 0) | .slug];
  def featsWithGateCap(g): [$feats[] | select([.events[] | select(.event == "gate_round" and (.data.gate // "") == g and ((.data.round // 0) >= 2))] | length > 0) | .slug];

  (featsWithGap("plan")) as $planFeats |
  (featsWithGap("execute")) as $execFeats |
  (featsWithGap("spec")) as $specFeats |
  (featsWithGateCap("spec-critique")) as $specCapFeats |
  (featsWithGateCap("plan-critique")) as $planCapFeats |
  ([$feats[] | select(.converged == true and .iterationsUsed <= 1) | .slug]) as $firstPass |
  ([$feats[] | select(.resultStatus == "completed" and .converged == false) | .slug]) as $shippedGaps |
  ([$feats[] | select(.resultStatus != null)] | length) as $finished |
  ([$feats[] | select(.converged == true)] | length) as $convergedN |

  [
    (if ($planFeats | length) >= $min then
      {id: "gap-plan-recurs", kind: "rule-candidate",
       pattern: "PLAN was the iterate gap across multiple features",
       evidence: {count: ($planFeats | length), features: $planFeats},
       rule: {text: "Retro: PLAN decomposition recurs as the iterate gap - decompose smaller: every task touches <=3 files and carries one behavioral verify command", check: null}}
     else empty end),
    (if ($execFeats | length) >= $min then
      {id: "gap-execute-recurs", kind: "rule-candidate",
       pattern: "EXECUTE was the iterate gap across multiple features",
       evidence: {count: ($execFeats | length), features: $execFeats},
       rule: {text: "Retro: EXECUTE gaps recur - verifyCommands must be behavioral (exercise the change), not compile-only, and implementers re-read acceptance criteria before DONE", check: null}}
     else empty end),
    (if ($specFeats | length) >= $min then
      {id: "gap-spec-recurs", kind: "rule-candidate",
       pattern: "SPEC scope was the iterate gap across multiple features",
       evidence: {count: ($specFeats | length), features: $specFeats},
       rule: {text: "Retro: SPEC scope gaps recur - spend one extra interview round on scope boundaries and edge cases before DISCUSS", check: null}}
     else empty end),
    (if ($specCapFeats | length) >= $min then
      {id: "gate-cap-spec-critique", kind: "rule-candidate",
       pattern: "spec-critique repeatedly needed all critique rounds",
       evidence: {count: ($specCapFeats | length), features: $specCapFeats},
       rule: {text: "Retro: spec-critique repeatedly hits its round cap - strengthen the SPEC draft before the gate (deeper interview, more grounding probes)", check: null}}
     else empty end),
    (if ($planCapFeats | length) >= $min then
      {id: "gate-cap-plan-critique", kind: "rule-candidate",
       pattern: "plan-critique repeatedly needed all critique rounds",
       evidence: {count: ($planCapFeats | length), features: $planCapFeats},
       rule: {text: "Retro: plan-critique repeatedly hits its round cap - ground PLAN.md tighter in PATTERNS.md analogs before the gate", check: null}}
     else empty end),
    (if (($firstPass | length) >= $min) and (($execFeats | length) < $min) then
      {id: "model-tier-headroom", kind: "suggestion",
       pattern: "features repeatedly converge first-pass with no recurring EXECUTE gaps",
       evidence: {count: ($firstPass | length), features: $firstPass},
       rule: {text: "Consider modelTier: mechanical on low-risk plan tasks - the implementer tier has headroom (first-pass convergence streak, no recurring execute gaps). See lib/model-tier.sh.", check: null}}
     else empty end),
    (if ($shippedGaps | length) >= 2 then
      {id: "shipped-with-gaps", kind: "info",
       pattern: "completed runs shipped without converging (accepted gaps)",
       evidence: {count: ($shippedGaps | length), features: $shippedGaps},
       rule: {text: "Multiple runs shipped at the iteration limit - drain the backlog (/loop-spec:cycle backlog) and check ITERATION.md for what keeps being accepted", check: null}}
     else empty end),
    {id: "convergence-rate", kind: "info",
     pattern: "aggregate convergence",
     evidence: {count: $finished, features: []},
     rule: {text: ("Convergence: " + ($convergedN | tostring) + "/" + ($finished | tostring) + " finished runs converged"), check: null}},
    (if $fleetCost != null then
      {id: "fleet-cost", kind: "info",
       pattern: "loop-fleet cost total",
       evidence: {count: 1, features: []},
       rule: {text: ("Loop-fleet cost to date: $" + ($fleetCost | tostring) + " (.loop/fleet-result.json)"), check: null}}
     else empty end)
  ]
')"

if [[ "$cmd" == "report" && "$JSON" == "1" ]]; then
  jq . <<<"$FINDINGS"
  exit 0
fi

_render() {
  echo "loop-spec retro ($FEATURES_DIR, min-repeats $MIN)"
  echo ""
  local n
  n="$(jq 'map(select(.kind == "rule-candidate")) | length' <<<"$FINDINGS")"
  jq -r '
    def sec(k; title): (map(select(.kind == k)) | if length == 0 then empty else
      title, (.[] | "  - [\(.id)] \(.rule.text)" +
        (if (.evidence.features | length) > 0 then "\n      evidence: \(.evidence.count) feature(s): \(.evidence.features | join(", "))" else "" end)), "" end);
    sec("rule-candidate"; "RULE CANDIDATES (apply with: retro.sh apply / /loop-spec:retro apply):"),
    sec("suggestion"; "SUGGESTIONS (your call, never auto-applied):"),
    sec("info"; "INFO:")
  ' <<<"$FINDINGS"
  if [[ "$n" == "0" ]]; then
    echo "no rule candidates at this threshold - the loop is not repeating itself"
  fi
}

if [[ "$cmd" == "report" ]]; then
  _render
  exit 0
fi

# ── apply ─────────────────────────────────────────────────────────────────────
_render
echo ""
count="$(jq 'map(select(.kind == "rule-candidate")) | length' <<<"$FINDINGS")"
if [[ "$count" == "0" ]]; then
  echo "retro apply: nothing to apply"
  exit 0
fi
echo "Applying $count rule candidate(s) to the project rules layer:"
while IFS= read -r text; do
  res="$(bash "$LIB_DIR/rules.sh" add "$text" 2>/dev/null || echo "error")"
  echo "  $res: $text"
done < <(jq -r '.[] | select(.kind == "rule-candidate") | .rule.text' <<<"$FINDINGS")
exit 0
