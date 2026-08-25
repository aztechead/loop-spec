#!/usr/bin/env bash
# model-tier.sh - Resolve a task modelTier to a harness-portable selector.
#
# mechanical on Claude Code is the cheapest Agent alias (haiku). Every other
# tier, unknown value, or harness that cannot name a cheap alias inherits —
# a portable catalog cannot invent a model ID. A concrete task `model` pin
# still wins at the caller (checked before this script).
#
# Usage:
#   model-tier.sh model <mechanical|standard|frontier> [--harness <name>]
#   model-tier.sh upgrade <selector> [--harness <name>]
#       One step up for a stuck fix-loop (haiku -> sonnet). inherit stays inherit.
#   model-tier.sh valid <tier>
#       Exit 0 if the tier is one of the three known names, else 1.
#
# Exit: 0 success, 1 invalid tier (valid only), 2 usage.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INHERITED_MODEL="inherit"
CHEAPEST_CLAUDE="haiku"
MID_CLAUDE="sonnet"

HARNESS=""
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --harness) HARNESS="${2:-}"; shift 2 ;;
    *) ARGS+=("$1"); shift ;;
  esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

cmd="${1:-}"

resolve_harness() {
  if [[ -n "$HARNESS" ]]; then
    printf '%s\n' "$HARNESS"
    return
  fi
  bash "$SCRIPT_DIR/harness.sh" detect
}

case "$cmd" in
  model)
    tier="${2:-}"
    harness="$(resolve_harness)"
    if [[ "$tier" == "mechanical" && "$harness" == "claude" ]]; then
      printf '%s\n' "$CHEAPEST_CLAUDE"
    else
      printf '%s\n' "$INHERITED_MODEL"
    fi
    ;;
  upgrade)
    current="${2:-}"
    [[ -n "$current" ]] || { echo "usage: model-tier.sh upgrade <selector> [--harness <name>]" >&2; exit 2; }
    harness="$(resolve_harness)"
    if [[ "$harness" == "claude" && "$current" == "$CHEAPEST_CLAUDE" ]]; then
      printf '%s\n' "$MID_CLAUDE"
    else
      printf '%s\n' "$current"
    fi
    ;;
  valid)
    case "${2:-}" in
      mechanical|standard|frontier) exit 0 ;;
      *) exit 1 ;;
    esac
    ;;
  *)
    echo "model-tier.sh: unknown command '${cmd}' (model|upgrade|valid)" >&2
    exit 2
    ;;
esac
