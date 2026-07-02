#!/usr/bin/env bash
# autonomous-chain.sh - The autonomous continuation-chain predicate, made deterministic.
#
# The cycle's On-completion section decides whether an autonomous run chains into
# backlog-drain mode for the gaps ITERATE just queued (skills/shared/autonomous-mode.md,
# continuation ladder rungs 4-5). That decision is a pure boolean over durable state;
# re-deriving it from prose every completion risks one probabilistic miss on a bound —
# and a missed "never chain past a failure" in a headless overnight run is a runaway
# loop. This script IS the predicate; the skill calls it and obeys the verdict.
#
# Usage:
#   autonomous-chain.sh should-chain <feature_dir> [--completed <n>]
#       <feature_dir>    Directory containing the just-completed feature.json.
#       --completed <n>  Features already completed this invocation (default 0);
#                        compared against LOOP_SPEC_MAX_FEATURES (default 1).
#
# Output (stdout, one line of JSON):
#   {"chain": true,  "entry": {...next backlog entry json...}}
#   {"chain": false, "reason": "<why>"}
#
# Reasons (stable strings, in check order):
#   not-autonomous        feature.json.autonomous != true
#   feature-not-completed currentPhase != "completed" (paused/escalated — never chain past a failure)
#   no-budget-spent-gaps  warnings[] has no iterate-budget-spent: entries
#   max-features-reached  completed >= LOOP_SPEC_MAX_FEATURES
#   backlog-empty         no unchecked backlog entries
#   next-entry-terminal   the next entry's gap id is already marked TERMINAL
#
# Exit codes: 0 predicate evaluated (answer in JSON), 1 bad invocation / unreadable state.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKLOG="$SCRIPT_DIR/backlog.sh"

no_chain() {
  jq -cn --arg r "$1" '{chain: false, reason: $r}'
  exit 0
}

cmd="${1:-}"
[[ "$cmd" == "should-chain" ]] || {
  echo "usage: autonomous-chain.sh should-chain <feature_dir> [--completed <n>]" >&2
  exit 1
}

feature_dir="${2:-}"
[[ -n "$feature_dir" && -f "$feature_dir/feature.json" ]] || {
  echo "autonomous-chain: feature.json not found in '${feature_dir}'" >&2
  exit 1
}

completed=0
if [[ "${3:-}" == "--completed" ]]; then
  completed="${4:-}"
  [[ "$completed" =~ ^[0-9]+$ ]] || {
    echo "autonomous-chain: --completed requires a non-negative integer" >&2
    exit 1
  }
fi

fj="$feature_dir/feature.json"
jq -e . "$fj" >/dev/null 2>&1 || {
  echo "autonomous-chain: feature.json is not valid JSON: $fj" >&2
  exit 1
}

max_features="${LOOP_SPEC_MAX_FEATURES:-1}"
[[ "$max_features" =~ ^[0-9]+$ ]] || max_features=1

# Check order mirrors the ladder: eligibility, then safety, then bounds, then supply.
[[ "$(jq -r '.autonomous // false' "$fj")" == "true" ]] || no_chain "not-autonomous"

[[ "$(jq -r '.currentPhase // ""' "$fj")" == "completed" ]] || no_chain "feature-not-completed"

n_gaps="$(jq -r '[(.warnings // [])[] | select(type == "string" and startswith("iterate-budget-spent:"))] | length' "$fj")"
[[ "$n_gaps" -gt 0 ]] || no_chain "no-budget-spent-gaps"

[[ "$completed" -lt "$max_features" ]] || no_chain "max-features-reached"

entry_json="$(bash "$BACKLOG" next --json 2>/dev/null)" || no_chain "backlog-empty"

gid="$(jq -r '.id // empty' <<<"$entry_json")"
if [[ -n "$gid" ]] && bash "$BACKLOG" is-terminal "$gid" 2>/dev/null; then
  no_chain "next-entry-terminal"
fi

jq -cn --argjson e "$entry_json" '{chain: true, entry: $e}'
