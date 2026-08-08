#!/usr/bin/env bash
# Route probe: classify ITERATE's outstanding gap for graph/cycle.graph.json's
# rewind routes (iterate -> execute | plan | spec | deliver).
#
# Usage:
#   iterate-gap.sh --feature-dir DIR
#   iterate-gap.sh --answers
#
# ITERATE Step 3 (skills/iterate/SKILL.md) writes the judge's gap classification
# to feature.json's `iterate.feedback` field (shape from lib/feature-init.sh
# fixed_blocks): `{type, description, fix_first}` on a rewind, cleared to `null`
# on convergence. The `iterate` block itself and its `feedback` key are always
# present from feature-init's schema-7 skeleton onward, so an absent key (not
# merely a null value) means the feature predates that shape or is otherwise
# malformed -- unresolved, per contract sec 2/3, never guessed as "no gap".
#
# Exit: 0 with one `gap=<value> reason=<text>` line on stdout when resolved;
# non-zero and silent otherwise.
set -euo pipefail

usage() {
  echo "usage: iterate-gap.sh --feature-dir DIR | --answers" >&2
  exit 2
}

if [[ "${1:-}" == "--answers" ]]; then
  printf 'gap=execute\ngap=plan\ngap=spec\ngap=none\n'
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

state="$(jq -r '
  if (.iterate | type) != "object" then "UNRESOLVED"
  elif (.iterate | has("feedback") | not) then "UNRESOLVED"
  elif .iterate.feedback == null then "NONE"
  elif ((.iterate.feedback.type // "") | test("^(execute|plan|spec)$")) then .iterate.feedback.type
  else "UNRESOLVED"
  end
' "$feature_json" 2>/dev/null)" || exit 1

case "$state" in
  NONE)
    echo "gap=none reason=iterate.feedback is null (converged, no rewind pending)"
    ;;
  execute|plan|spec)
    echo "gap=${state} reason=iterate.feedback.type=${state}"
    ;;
  *)
    exit 1
    ;;
esac
