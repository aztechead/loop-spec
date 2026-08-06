#!/usr/bin/env bash
# code-graph.sh - Which code-intelligence layers are available, and what each is
# allowed to answer.
#
# Why: "the graph" was one hard-required tool answering three jobs with different
# needs, and a missing install aborted the cycle for all three. The jobs are not
# alike:
#
#   structural  where is X defined, what references it     -> wants CURRENT
#   ripple      hotspots, god nodes, what a change reaches -> staleness tolerable
#   semantic    non-derivable truths (why, constraints)    -> curated, not derived
#
# Separating them is what makes degradation possible: a missing graph costs the
# ripple job, which nothing else answers, while structural work drops to Glob/Grep
# and the run continues. It also names the honest caveat on each answer -- a graph
# snapshot is precise but only as current as its last refresh, which is exactly why
# the grounding gate carries graphify's own EXTRACTED/INFERRED/AMBIGUOUS label
# (skills/shared/grounding-protocol.md).
#
# This reports; it never installs, builds, or refreshes anything, and it bundles no
# tool of its own. The layers are the seam: an implementation can be added here
# without touching a phase skill.
#
# Usage:
#   code-graph.sh layers          # one line per job: who answers it and why
#   code-graph.sh structural      # the tool for symbol lookups
#   code-graph.sh ripple          # the tool for hotspots/ripple (or none)
#   code-graph.sh require <job>   # exit 0 if that job has a real answer
#
# Environment:
#   LOOP_SPEC_STRUCTURAL_TOOL   force graphify|grep (default: probe)
#   LOOP_SPEC_REQUIRE_GRAPHIFY  1 restores the pre-2.35 hard requirement
#
# Exit codes:
#   0  reported / the required job has an answer
#   1  `require` asked about a job with no answer
#   2  usage error
#
# No layer is a hard gate. A missing tool degrades the job it served and says so;
# it never aborts a run, because a cycle that cannot consult a graph can still read
# files, and refusing to start would be a worse answer than a slower one.
set -euo pipefail

command="${1:-}"
case "$command" in
  layers|structural|ripple) [[ $# -eq 1 ]] || { echo "usage: code-graph.sh $command" >&2; exit 2; } ;;
  require) [[ $# -eq 2 ]] || { echo "usage: code-graph.sh require <structural|ripple>" >&2; exit 2; } ;;
  *) echo "usage: code-graph.sh layers|structural|ripple|require <job>" >&2; exit 2 ;;
esac

structural_tool() {
  local forced="${LOOP_SPEC_STRUCTURAL_TOOL:-}"
  case "$forced" in
    graphify|grep)
      printf '%s\toperator override (LOOP_SPEC_STRUCTURAL_TOOL=%s)' "$forced" "$forced"
      return 0
      ;;
    "") ;;
    *)
      echo "code-graph: ignoring unknown LOOP_SPEC_STRUCTURAL_TOOL='$forced'" >&2
      ;;
  esac

  if [[ -f "graphify-out/graph.json" ]]; then
    printf 'graphify\tgraph snapshot answers symbol lookups, only as current as its last refresh'
  else
    printf 'grep\tno built graph; Glob/Grep only -- always current, never precise'
  fi
}

ripple_tool() {
  if [[ -f "graphify-out/GRAPH_REPORT.md" ]]; then
    printf 'graphify\tGRAPH_REPORT.md provides god nodes and cross-module connections'
  elif [[ -f "graphify-out/graph.json" ]]; then
    printf 'graphify\tgraph.json present but GRAPH_REPORT.md missing; hotspots unavailable'
  else
    printf 'none\tno built graph; ripple analysis unavailable and no tool substitutes for it'
  fi
}

emit() {
  local job="$1" answer reason
  IFS=$'\t' read -r answer reason <<<"$2"
  printf '%s=%s reason=%s\n' "$job" "$answer" "$reason"
}

case "$command" in
  structural) emit structural "$(structural_tool)" ;;
  ripple) emit ripple "$(ripple_tool)" ;;
  layers)
    emit structural "$(structural_tool)"
    emit ripple "$(ripple_tool)"
    # The third job has no tool by construction: non-derivable truths are curated,
    # and nothing in this repository curates them yet (bmad-scan-proposals.md B6).
    printf 'semantic=none reason=no curated context kernel in this release\n'
    ;;
  require)
    job="$2"
    case "$job" in
      structural) line="$(structural_tool)" ;;
      ripple) line="$(ripple_tool)" ;;
      *) echo "usage: code-graph.sh require <structural|ripple>" >&2; exit 2 ;;
    esac
    emit "$job" "$line"
    answer="${line%%$'\t'*}"
    [[ "$answer" != "none" && "$answer" != "grep" ]]
    ;;
esac
