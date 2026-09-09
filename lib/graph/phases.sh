#!/usr/bin/env bash
# phases.sh - The cycle's phase vocabulary, read from the graph.
#
# Why: the seven phase ids were spelled out in twelve files (the engine, the entry and
# exit gates, the driver, feature-init, the extension points, two hooks, three tests,
# and a doc), so adding a phase was a twelve-file edit and a missed one was a phase
# the harness could not enter (docs/loop-spec/orchestrator-port-plan.md, WP2). A phase
# is an agent node of graph/cycle.graph.json whose body is a phase skill
# (`skills/<id>/SKILL.md`); this is the only place that rule is written down.
#
# Usage:
#   phases.sh list      [--graph PATH]        one id per line, graph order
#   phases.sh regex     [--graph PATH]        `spec|discuss|...` for a regex alternation
#   phases.sh validate <id> [--graph PATH]    exit 0 when <id> is a phase, 1 otherwise
#                                             (the message names the phases)
#   phases.sh suffix   <id> [--graph PATH]    the LOOP_SPEC_PHASE_MODEL_<SUFFIX> suffix
#
# LOOP_SPEC_GRAPH names another graph for every caller (an embedding that ships its own
# graph, or a test that adds a phase to a copy); --graph outranks it.
# Exit codes: 0 answered; 1 not a phase; 2 bad invocation or unreadable graph.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cmd="${1:-}"; shift || true
graph="${LOOP_SPEC_GRAPH:-$SCRIPT_DIR/../../graph/cycle.graph.json}"
id=""
case "$cmd" in
  validate|suffix) id="${1:-}"; shift || true ;;
esac
while [[ $# -gt 0 ]]; do
  case "$1" in
    --graph) graph="${2:-}"; shift 2 ;;
    *) echo "usage: phases.sh list|regex|validate <id>|suffix <id> [--graph PATH]" >&2; exit 2 ;;
  esac
done
[[ -f "$graph" ]] || { echo "phases.sh: graph not readable: $graph" >&2; exit 2; }

phases="$(jq -r '.nodes[] | select(.kind == "agent" and ((.body // "") | test("^skills/[^/]+/SKILL\\.md$"))) | .id' "$graph" 2>/dev/null)" \
  || { echo "phases.sh: graph is not valid JSON: $graph" >&2; exit 2; }
[[ -n "$phases" ]] || { echo "phases.sh: no phase nodes (agent nodes with a skills/<id>/SKILL.md body) in $graph" >&2; exit 2; }

case "$cmd" in
  list) printf '%s\n' "$phases" ;;
  regex) paste -sd'|' <<<"$phases" ;;
  validate)
    [[ -n "$id" ]] || { echo "usage: phases.sh validate <id> [--graph PATH]" >&2; exit 2; }
    grep -qxF -- "$id" <<<"$phases" \
      || { echo "phase must be one of: $(paste -sd' ' <<<"$phases" | sed 's/ / | /g') (got '$id')" >&2; exit 1; }
    ;;
  suffix)
    [[ -n "$id" ]] || { echo "usage: phases.sh suffix <id> [--graph PATH]" >&2; exit 2; }
    grep -qxF -- "$id" <<<"$phases" \
      || { echo "phase must be one of: $(paste -sd' ' <<<"$phases" | sed 's/ / | /g') (got '$id')" >&2; exit 1; }
    printf '%s\n' "$id" | tr 'a-z-' 'A-Z_'
    ;;
  *) echo "usage: phases.sh list|regex|validate <id>|suffix <id> [--graph PATH]" >&2; exit 2 ;;
esac
