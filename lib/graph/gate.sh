#!/usr/bin/env bash
# Critique-gate lifecycle — the only writer of feature.json currentGate/gateHistory.
#
# Usage:
#   gate.sh open  --feature-dir DIR --phase PHASE --gate GATE [--challenger NAME] [--now ISO]
#   gate.sh round --feature-dir DIR
#   gate.sh fail  --feature-dir DIR --rounds N --convergence C --challenger-model M [--findings JSON] [--notes TEXT]
#   gate.sh pass  --feature-dir DIR --rounds N --convergence C --challenger-model M [--notes TEXT]
#   gate.sh next  --feature-dir DIR
#   gate.sh show  --feature-dir DIR
#
# `next` is the delta-round probe: after a fail entry lands it answers, on one line,
# whether the lead re-dispatches the author or closes the gate --
#   ANSWER=rerun REASON=...   another delta round is inside the ceiling
#   ANSWER=close REASON=...   the ceiling is spent, or one finding survived two
#                             consecutive delta rounds (a deadlock)
# The ceiling is the loop edge graph/critique.graph.json declares from
# critique.adjudicate back to critique.challenge, read at call time; a number restated
# here would be the second declaration tests/graph-conformance.test.sh bans.
# LOOP_SPEC_CRITIQUE_ROUNDS outranks the graph: a positive integer replaces the ceiling,
# 0 means unbounded (every answer is rerun), anything else is a configuration error.
# A field run spent over an hour bouncing PLAN.md between the challenger and the planner
# because the protocol prose said retries were unbounded and the graph's ceiling was
# inside a `contain` loop the engine never counts; this subcommand is what counts it.
#
# Why this exists rather than the write steps in skills/shared/critique-gate-protocol.md:
# the gate transition SELECTS A CODE PATH. graph/cycle.graph.json declares currentGate in
# the reads[] of both critique subgraph nodes, and lib/graph/state.sh assert-reads fails a
# node whose read is null -- so the moment the reset lands decides whether the run advances
# or dead-ends. Prose ordered against phase-skill step numbers cannot express "after the
# graph leaves the node", and the two shipped readings of the reset (a zeroed object, or
# null) do not even agree on the value. A field run took the null reading, stalled the
# engine, hand-repaired feature.json, and lost a human gate on the way back. The ordering
# and the shape are code here: `pass` appends the history entry BEFORE it resets, resets to
# a whole object and never to null, and every subcommand refuses when no gate is open.
#
# Writes delegate to lib/graph/state.sh (which delegates to lib/feature-write.sh), so the
# graph's own writes[] declaration still governs. Both keys belong to critique.adjudicate
# in graph/critique.graph.json -- the node that owns the adjudication these calls record.
#
# Exit: 0 ok; 1 no open gate / unreadable state / write failure; 2 bad invocation or a
# malformed LOOP_SPEC_CRITIQUE_ROUNDS.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
STATE="$SCRIPT_DIR/state.sh"
CRITIQUE_GRAPH="$REPO_ROOT/graph/critique.graph.json"
WRITE_NODE="critique.adjudicate"

usage() {
  cat >&2 <<'EOF'
usage: gate.sh open  --feature-dir DIR --phase PHASE --gate GATE [--challenger NAME] [--now ISO]
       gate.sh round --feature-dir DIR
       gate.sh fail  --feature-dir DIR --rounds N --convergence C --challenger-model M [--findings JSON] [--notes TEXT]
       gate.sh pass  --feature-dir DIR --rounds N --convergence C --challenger-model M [--notes TEXT]
       gate.sh next  --feature-dir DIR
       gate.sh show  --feature-dir DIR
EOF
  exit 2
}

[[ $# -ge 1 ]] || usage
cmd="$1"; shift

feature_dir=""; phase=""; gate=""; challenger="challenger-1"; now=""
rounds=""; convergence=""; challenger_model=""; findings="[]"; notes="null"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --feature-dir) feature_dir="${2:-}"; shift 2 ;;
    --phase) phase="${2:-}"; shift 2 ;;
    --gate) gate="${2:-}"; shift 2 ;;
    --challenger) challenger="${2:-}"; shift 2 ;;
    --now) now="${2:-}"; shift 2 ;;
    --rounds) rounds="${2:-}"; shift 2 ;;
    --convergence) convergence="${2:-}"; shift 2 ;;
    --challenger-model) challenger_model="${2:-}"; shift 2 ;;
    --findings) findings="${2:-}"; shift 2 ;;
    --notes) notes="$(jq -Rn --arg n "${2:-}" '$n')"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$feature_dir" ]] || usage
feature_json="$feature_dir/feature.json"
[[ -f "$feature_json" ]] || {
  echo "gate.sh: feature.json not found in $feature_dir" >&2
  exit 1
}

# state.sh enforces the graph's writes[]; feature-write.sh refuses these two keys to
# anything that has not come through here.
write_key() {
  local key="$1" value="$2"
  LOOP_SPEC_GATE_WRITE=1 bash "$STATE" write \
    --feature-dir "$feature_dir" --node "$WRITE_NODE" --graph "$CRITIQUE_GRAPH" \
    --key "$key" "$value"
}

open_phase="$(jq -r '.currentGate.phase // empty' "$feature_json")" || exit 1

require_open() {
  [[ -n "$open_phase" ]] || {
    echo "gate.sh: no gate is open (currentGate.phase is null); run 'gate.sh open' first" >&2
    exit 1
  }
}

# One history entry, with `attempt` counted from the entries already recorded for this
# phase+gate. Deriving it here is the point: an attempt number a caller supplies is a
# caller's guess, and a wrong one silently rewrites the gate's own record of itself.
append_history() {
  local result="$1" entry history
  entry="$(jq -n \
    --arg phase "$open_phase" \
    --arg gate "$(jq -r '.currentGate.gate // ""' "$feature_json")" \
    --arg result "$result" \
    --arg convergence "$convergence" \
    --arg model "$challenger_model" \
    --argjson rounds "$rounds" \
    --argjson findings "$findings" \
    --argjson notes "$notes" \
    '{phase: $phase, gate: $gate, attempt: 0, result: $result,
      advocateModel: null, challengerModel: $model, rounds: $rounds,
      convergence: $convergence, findingsAddressed: $findings, notes: $notes}')" || exit 1
  history="$(jq --argjson e "$entry" '
    (.gateHistory // [])
    | ([.[] | select(.phase == $e.phase and .gate == $e.gate)] | length + 1) as $attempt
    | . + [$e | .attempt = $attempt]
  ' "$feature_json")" || exit 1
  write_key gateHistory "$history"
}

# The delta-round ceiling, from the graph's own loop edge. Empty output means the graph
# no longer declares one, and the caller must refuse rather than guess a number.
critique_ceiling() {
  local override="${LOOP_SPEC_CRITIQUE_ROUNDS-}"
  if [[ -n "$override" ]]; then
    [[ "$override" =~ ^[0-9]+$ ]] || {
      echo "gate.sh: LOOP_SPEC_CRITIQUE_ROUNDS must be a non-negative integer (0 = unbounded), got '$override'" >&2
      exit 2
    }
    echo "$override"
    return 0
  fi
  jq -r '[.edges[] | select(.kind == "loop" and .from == "critique.adjudicate"
                            and .to == "critique.challenge")][0].ceiling // empty' \
    "$CRITIQUE_GRAPH"
}

# A finding present in both of the last two fail entries for the open gate. Fail entries
# are appended before every re-dispatch, so in a stall the last two are the last two
# rounds; a DELTA-VERIFIED round would have closed the gate instead.
surviving_finding() {
  jq -r --arg phase "$open_phase" \
    --arg gate "$(jq -r '.currentGate.gate // ""' "$feature_json")" '
    [.gateHistory[]? | select(.phase == $phase and .gate == $gate and .result == "fail")]
    | if length < 2 then empty
      else (.[-2].findingsAddressed // []) as $prev
           | (.[-1].findingsAddressed // []) | map(select(. as $f | $prev | index($f))) | .[0] // empty
      end' "$feature_json"
}

case "$cmd" in
  open)
    [[ -n "$phase" && -n "$gate" ]] || usage
    [[ -z "$open_phase" ]] || {
      echo "gate.sh: gate '$(jq -r '.currentGate.gate' "$feature_json")' is already open for phase '$open_phase'" >&2
      echo "  close it with 'gate.sh pass' before opening another" >&2
      exit 1
    }
    [[ -n "$now" ]] || now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    write_key currentGate "$(jq -n \
      --arg phase "$phase" --arg gate "$gate" --arg challenger "$challenger" --arg now "$now" \
      '{phase: $phase, gate: $gate, round: 0, advocateName: null,
        challengerName: $challenger, startedAt: $now}')"
    ;;
  round)
    require_open
    next="$(jq '.currentGate.round + 1' "$feature_json")" || exit 1
    write_key currentGate "$(jq --argjson r "$next" '.currentGate | .round = $r' "$feature_json")"
    echo "$next"
    ;;
  fail)
    require_open
    [[ -n "$rounds" && -n "$convergence" && -n "$challenger_model" ]] || usage
    append_history fail
    ;;
  pass)
    require_open
    [[ -n "$rounds" && -n "$convergence" && -n "$challenger_model" ]] || usage
    findings="[]"
    append_history pass
    # Only after the entry lands. A crash between the two leaves an open gate and a
    # recorded attempt, which resume re-enters; the reverse order would lose the attempt
    # and read as a gate that never ran.
    write_key currentGate '{"phase": null, "gate": null, "round": 0, "advocateName": null,
      "challengerName": null, "startedAt": null}'
    ;;
  next)
    require_open
    # The substitution swallows the helper's exit code; pass it through unchanged.
    ceiling="$(critique_ceiling)" || exit $?
    [[ -n "$ceiling" ]] || {
      echo "gate.sh: $CRITIQUE_GRAPH declares no loop edge from critique.adjudicate to critique.challenge; cannot bound the gate" >&2
      exit 1
    }
    if [[ "$ceiling" -eq 0 ]]; then
      echo "ANSWER=rerun REASON=LOOP_SPEC_CRITIQUE_ROUNDS=0 (unbounded by operator)"
      exit 0
    fi
    round="$(jq -r '.currentGate.round' "$feature_json")" || exit 1
    # Round 1 is the single-critic pass; every later round is a delta re-verify.
    delta_spent=$(( round > 0 ? round - 1 : 0 ))
    if (( delta_spent >= ceiling )); then
      echo "ANSWER=close REASON=ceiling: $delta_spent of $ceiling delta rounds spent (graph/critique.graph.json)"
      exit 0
    fi
    if (( round >= 3 )); then
      survivor="$(surviving_finding)" || exit 1
      if [[ -n "$survivor" ]]; then
        echo "ANSWER=close REASON=deadlock: finding survived two consecutive delta rounds: $survivor"
        exit 0
      fi
    fi
    echo "ANSWER=rerun REASON=$delta_spent of $ceiling delta rounds spent"
    ;;
  show)
    if [[ -z "$open_phase" ]]; then
      echo "gate=none"
    else
      jq -r '"gate=\(.currentGate.gate) phase=\(.currentGate.phase) round=\(.currentGate.round)"' \
        "$feature_json"
    fi
    ;;
  *)
    usage
    ;;
esac
