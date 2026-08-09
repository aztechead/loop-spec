#!/usr/bin/env bash
# Route probe: does this SPEC-level rewind need a human's approval first?
#
# Usage:
#   iterate-approval.sh --feature-dir DIR
#   iterate-approval.sh --answers
#
# The spec rewind is the expensive one, and skills/iterate/SKILL.md gates it on
# TWO facts at once: the gap class is `spec`, AND the run opted into per-phase
# control (`step` / `interactive`). In `auto` / `review-only` the rewind is
# deliberately autonomous -- the judge always scores against the immutable
# original goal, so refining the spec cannot redefine "done".
#
# A route condition holds ONE probe and ONE token, and the engine takes the
# first satisfied route in declaration order. Splitting this across a gap probe
# and a style probe made the approval gate unreachable: `gap=spec` matched first
# and jumped straight to the rewind, so `step` and `interactive` silently lost
# the approval they had asked for. This probe answers the compound question so
# one route can express it.
#
# Exit: 0 with one `approval=<required|none> reason=<text>` line when resolved;
# non-zero and silent when the gap class cannot be determined.
set -euo pipefail

usage() {
  echo "usage: iterate-approval.sh --feature-dir DIR | --answers" >&2
  exit 2
}

if [[ "${1:-}" == "--answers" ]]; then
  printf 'approval=required\napproval=none\n'
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

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Reuse the two probes that already own these facts rather than re-reading
# feature.json here; an unresolved gap class must stay unresolved, never "none".
gap_line="$(bash "$script_dir/iterate-gap.sh" --feature-dir "$feature_dir")" || exit 1
gap="${gap_line%% *}"

style_line="$(bash "$script_dir/exec-style.sh" --feature-dir "$feature_dir")" || exit 1
style="${style_line%% *}"

if [[ "$gap" == "gap=spec" && ( "$style" == "style=step" || "$style" == "style=interactive" ) ]]; then
  echo "approval=required reason=spec rewind under ${style#style=} needs approval"
else
  echo "approval=none reason=${gap#gap=} gap under ${style#style=}"
fi
