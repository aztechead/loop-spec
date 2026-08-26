#!/usr/bin/env bash
# Route probe: after the execute agent returns, should the engine admit
# the declared execute -> execute.worker fanout?
#
# The execute node body (skills/execute/SKILL.md) already runs the selected
# rung to completion: inline, subagent, loop, team, and workflow each
# dispatch and merge inside that node and never leave work on mergeQueue
# for graph-level workers. Phase exit clears the queue. An unconditional
# fanout then dispatched loop-spec:implementer against an empty queue —
# a no-op at best, and the path the subagent rung (hard-pinned by
# workspace mode) actually stopped on rather than force.
#
# mergeQueue is the worker subgraph's input. A non-empty queue admits
# the fanout; an empty or absent queue skips it. A mergeQueue that is
# not an array fails closed (unresolved) rather than guessing.
#
# Usage:
#   execute-fanout.sh --feature-dir DIR
#   execute-fanout.sh --answers
#
# Exit: 0 with one `fanout=<skip|worker> reason=<text>` line when
# resolved; non-zero and silent otherwise.
set -euo pipefail

usage() {
  echo "usage: execute-fanout.sh --feature-dir DIR | --answers" >&2
  exit 2
}

if [[ "${1:-}" == "--answers" ]]; then
  printf 'fanout=skip\nfanout=worker\n'
  exit 0
fi

feature_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --feature-dir) feature_dir="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$feature_dir" ]] || usage

feature_json="$feature_dir/feature.json"
[[ -f "$feature_json" ]] || exit 1

queue_type="$(jq -r 'if has("mergeQueue") then (.mergeQueue | type) else "null" end' \
  "$feature_json" 2>/dev/null)" || exit 1

case "$queue_type" in
  array)
    length="$(jq -r '.mergeQueue | length' "$feature_json" 2>/dev/null)" || exit 1
    if [[ "$length" -gt 0 ]]; then
      echo "fanout=worker reason=mergeQueue-length=${length}"
    else
      echo "fanout=skip reason=mergeQueue-empty"
    fi
    ;;
  null)
    echo "fanout=skip reason=mergeQueue-empty"
    ;;
  *)
    exit 1
    ;;
esac
