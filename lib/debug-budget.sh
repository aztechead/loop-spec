#!/usr/bin/env bash
# debug-budget.sh - Deterministic budget counters for the debug skill's FIX loop.
#
# The debug loop is bounded: max 5 hypotheses, max 3 fix attempts per hypothesis
# (skills/debug/SKILL.md, Step 3). Counting those in model context drifts across a
# long session (compaction eats the count); counting them in BUG.md prose is not a
# counter at all. This file IS the counter: state lives in {bug_dir}/budget.json,
# each tick answers "may I proceed?" with an exit code.
#
# Usage:
#   debug-budget.sh hypothesis <bug_dir>
#       Open the next hypothesis (resets the attempt counter). Prints
#       {hypothesis, attempts, hypotheses_left}. Exit 0 when within budget,
#       exit 3 when the hypothesis budget is exhausted (stop and escalate).
#   debug-budget.sh attempt <bug_dir>
#       Record a fix attempt against the current hypothesis. Prints
#       {hypothesis, attempts, attempts_left}. Exit 0 when within budget,
#       exit 3 when this hypothesis' attempts are exhausted (move to next
#       hypothesis or escalate). Requires an open hypothesis (exit 1 otherwise).
#   debug-budget.sh status <bug_dir>
#       Print the full state {hypothesis, attempts, max_hypotheses, max_attempts}.
#
# Budgets: LOOP_SPEC_DEBUG_MAX_HYPOTHESES (default 5),
#          LOOP_SPEC_DEBUG_MAX_ATTEMPTS   (default 3).
#
# Exit codes: 0 within budget, 1 bad invocation, 3 budget exhausted.
set -euo pipefail

MAX_H="${LOOP_SPEC_DEBUG_MAX_HYPOTHESES:-5}"
MAX_A="${LOOP_SPEC_DEBUG_MAX_ATTEMPTS:-3}"

cmd="${1:-}"
bug_dir="${2:-}"
[[ -n "$cmd" && -n "$bug_dir" ]] || {
  echo "usage: debug-budget.sh hypothesis|attempt|status <bug_dir>" >&2
  exit 1
}
[[ -d "$bug_dir" ]] || { echo "debug-budget: no such dir: $bug_dir" >&2; exit 1; }

STATE="$bug_dir/budget.json"
[[ -f "$STATE" ]] || printf '{"hypothesis": 0, "attempts": 0}\n' > "$STATE"

h="$(jq -r '.hypothesis' "$STATE")"
a="$(jq -r '.attempts' "$STATE")"

write_state() {
  jq -cn --argjson h "$1" --argjson a "$2" '{hypothesis: $h, attempts: $a}' > "$STATE"
}

case "$cmd" in
  hypothesis)
    if [[ "$h" -ge "$MAX_H" ]]; then
      jq -cn --argjson h "$h" --argjson max "$MAX_H" \
        '{hypothesis: $h, hypotheses_left: 0, exhausted: true, max_hypotheses: $max}'
      exit 3
    fi
    h=$((h + 1)); a=0
    write_state "$h" "$a"
    jq -cn --argjson h "$h" --argjson a "$a" --argjson left "$((MAX_H - h))" \
      '{hypothesis: $h, attempts: $a, hypotheses_left: $left}'
    ;;
  attempt)
    if [[ "$h" -eq 0 ]]; then
      echo "debug-budget: no open hypothesis (run 'hypothesis' first)" >&2
      exit 1
    fi
    if [[ "$a" -ge "$MAX_A" ]]; then
      jq -cn --argjson h "$h" --argjson a "$a" --argjson max "$MAX_A" \
        '{hypothesis: $h, attempts: $a, attempts_left: 0, exhausted: true, max_attempts: $max}'
      exit 3
    fi
    a=$((a + 1))
    write_state "$h" "$a"
    jq -cn --argjson h "$h" --argjson a "$a" --argjson left "$((MAX_A - a))" \
      '{hypothesis: $h, attempts: $a, attempts_left: $left}'
    ;;
  status)
    jq -cn --argjson h "$h" --argjson a "$a" --argjson mh "$MAX_H" --argjson ma "$MAX_A" \
      '{hypothesis: $h, attempts: $a, max_hypotheses: $mh, max_attempts: $ma}'
    ;;
  *)
    echo "usage: debug-budget.sh hypothesis|attempt|status <bug_dir>" >&2
    exit 1
    ;;
esac
