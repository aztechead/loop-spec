#!/usr/bin/env bash
# Admit probe: does this run pause at a human gate?
#
# Usage:
#   human-gate.sh --feature-dir DIR
#   human-gate.sh --answers
#
# Why this exists rather than pinning `style=step` on each human node's `admit`:
# an admit condition holds ONE expected token (alternation is illegal, see
# lib/graph/validate.sh), so a style-valued probe can only ever admit a single
# style. Pinning `style=step` silently skipped every human gate under
# `interactive` -- the style whose documented behavior is to pause the MOST.
# Which styles pause is policy; the graph should not have to restate it on five
# separate nodes and drift when it changes. This probe owns that mapping.
#
# Pausing styles are `step` (pause between phases) and `interactive` (pause
# before every agent dispatch). `auto` runs end to end, and `review-only` pauses
# only for critique-gate reconciliation, which is a `gate` node, not a `human`
# one. See README "Execution styles".
#
# Exit: 0 with one `gate=<pause|skip> reason=<text>` line when resolved;
# non-zero and silent otherwise, so an unresolved style never admits.
set -euo pipefail

usage() {
  echo "usage: human-gate.sh --feature-dir DIR | --answers" >&2
  exit 2
}

if [[ "${1:-}" == "--answers" ]]; then
  printf 'gate=pause\ngate=skip\n'
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
  step|interactive) echo "gate=pause reason=execStyle=${style} pauses at human gates" ;;
  auto|review-only) echo "gate=skip reason=execStyle=${style} runs unattended" ;;
  *) exit 1 ;;
esac
