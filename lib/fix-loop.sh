#!/usr/bin/env bash
# fix-loop.sh - Deterministic EXECUTE fix-round policy.
#
# Why: a fresh one-shot retry of the same implementer is expensive and often
# blind to its own mistake. Superpowers v6.2.0: rounds 1-3 resume the live
# implementer; rounds 4-5 spawn fresh on a more capable model; a five-round
# breaker stops the spin. One-shot Agent rungs cannot resume — they still
# consume the report file as memory, and this script still names the action
# so the lead does not invent a sixth attempt.
#
# Attempt is 0-based and includes the initial implementation:
#   0       initial
#   1-3     resume (fix rounds 1-3)
#   4-5     fresh-upgrade (fix rounds 4-5)
#   6+      breaker
#
# Usage:
#   fix-loop.sh action <attempt>
#       Print: initial | resume | fresh-upgrade | breaker
#   fix-loop.sh max
#       Print the first attempt index that trips the breaker (6).
#   fix-loop.sh live <rung>
#       Print: resumeable | oneshot
#       resumeable = team | implicit-named | loop-fleet
#       oneshot    = subagent | inline | workflow | anything else
#
# Exit codes: 0 success, 2 usage.
set -euo pipefail

cmd="${1:-}"
arg="${2:-}"

case "$cmd" in
  max)
    echo 6
    ;;
  action)
    [[ "$arg" =~ ^[0-9]+$ ]] || { echo "usage: fix-loop.sh action <attempt>" >&2; exit 2; }
    if (( arg == 0 )); then
      echo initial
    elif (( arg >= 1 && arg <= 3 )); then
      echo resume
    elif (( arg >= 4 && arg <= 5 )); then
      echo fresh-upgrade
    else
      echo breaker
    fi
    ;;
  live)
    case "$arg" in
      team|implicit-named|loop-fleet) echo resumeable ;;
      *) echo oneshot ;;
    esac
    ;;
  *)
    echo "usage: fix-loop.sh action <attempt> | max | live <rung>" >&2
    exit 2
    ;;
esac
