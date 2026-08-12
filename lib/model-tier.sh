#!/usr/bin/env bash
# model-tier.sh - Keep legacy task tiers portable across model catalogs.
#
# Older plans may carry a `modelTier` (mechanical | standard | frontier). A tier
# cannot name a portable model: Claude Code and OpenCode may expose entirely
# different catalogs. All three therefore inherit the caller's model. A concrete
# task `model` remains an explicit operator-owned override.
#
# Usage:
#   model-tier.sh model <mechanical|standard|frontier>
#       Print `inherit`. Unknown/empty tier also inherits.
#
#   model-tier.sh valid <tier>
#       Exit 0 if tier is one of the three known tiers, else exit 1.
#
# A concrete `model` pin in task metadata still overrides this (callers check
# `model` first, then fall back to `modelTier` via this script, then the role map).

set -euo pipefail

INHERITED_MODEL="inherit"

cmd="${1:-}"
case "$cmd" in
  model)
    # Every tier -- known, unknown, or absent -- resolves the same way. A tier
    # cannot name a portable model, so there is nothing here to branch on.
    printf '%s\n' "$INHERITED_MODEL"
    ;;
  valid)
    case "${2:-}" in
      mechanical|standard|frontier) exit 0 ;;
      *) exit 1 ;;
    esac
    ;;
  *)
    echo "model-tier.sh: unknown command '${cmd}' (model|valid)" >&2
    exit 2
    ;;
esac
