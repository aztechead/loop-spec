#!/usr/bin/env bash
# Route/admit probe: the feature's declared execStyle, verbatim.
#
# Usage:
#   exec-style.sh --feature-dir DIR
#   exec-style.sh --answers
#
# Used both as a route condition (e.g. ITERATE's spec-approval routes) and as a
# human node's `admit` condition (contract sec 4) -- the same probe, the same
# answer contract, whichever role the graph declares it in.
#
# Exit: 0 with one `style=<value> reason=<text>` line on stdout when resolved;
# non-zero and silent otherwise.
set -euo pipefail

usage() {
  echo "usage: exec-style.sh --feature-dir DIR | --answers" >&2
  exit 2
}

if [[ "${1:-}" == "--answers" ]]; then
  printf 'style=auto\nstyle=step\nstyle=interactive\nstyle=review-only\n'
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

style="$(jq -r '.execStyle // empty' "$feature_json" 2>/dev/null)" || exit 1
case "$style" in
  auto|step|interactive|review-only)
    echo "style=${style} reason=feature.json.execStyle=${style}"
    ;;
  *)
    exit 1
    ;;
esac
