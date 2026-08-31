#!/usr/bin/env bash
# Critique-gate lifecycle — the only writer of feature.json currentGate/gateHistory.
#
# Usage:
#   gate.sh open  --feature-dir DIR --phase PHASE --gate GATE [--challenger NAME] [--now ISO]
#   gate.sh round --feature-dir DIR
#   gate.sh fail  --feature-dir DIR --rounds N --convergence C --challenger-model M [--findings JSON] [--notes TEXT]
#   gate.sh pass  --feature-dir DIR --rounds N --convergence C --challenger-model M [--notes TEXT]
#   gate.sh show  --feature-dir DIR
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
# Exit: 0 ok; 1 no open gate / unreadable state / write failure; 2 bad invocation.
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
