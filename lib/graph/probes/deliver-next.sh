#!/usr/bin/env bash
# Route probe: DELIVER's declared next phase for graph/cycle.graph.json's
# post-delivery routes (deliver -> execute | completed).
#
# Usage:
#   deliver-next.sh --feature-dir DIR
#   deliver-next.sh --answers
#
# lib/deliver.sh is the side-effecting action script that actually runs
# delivery; it is never itself a route condition (REMEDIATION-CONTRACT.md
# sec 1). This probe only reads the outcome it already wrote to
# feature.json's `delivery.nextPhase`.
#
# lib/deliver.sh can also leave `delivery.nextPhase == "deliver"` (retry, no
# forward progress -- e.g. checks still pending, or no changes to ship). That
# value is deliberately outside this probe's answer set: with no route
# satisfied, the engine aborts (contract sec 3) instead of silently retrying
# or silently completing.
#
# Exit: 0 with one `nextPhase=<value> reason=<text>` line on stdout when
# resolved; non-zero and silent otherwise.
set -euo pipefail

usage() {
  echo "usage: deliver-next.sh --feature-dir DIR | --answers" >&2
  exit 2
}

if [[ "${1:-}" == "--answers" ]]; then
  printf 'nextPhase=execute\nnextPhase=completed\nnextPhase=deliver\n'
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

next_phase="$(jq -r '.delivery.nextPhase // empty' "$feature_json" 2>/dev/null)" || exit 1
case "$next_phase" in
  execute|completed|deliver)
    echo "nextPhase=${next_phase} reason=feature.json.delivery.nextPhase=${next_phase}"
    ;;
  *)
    exit 1
    ;;
esac
