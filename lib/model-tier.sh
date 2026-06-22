#!/usr/bin/env bash
# model-tier.sh - Resolve an abstract per-task model tier to a concrete model id.
#
# loop-spec uses a FIXED per-role model map (skills/shared/model-matrix.md). This
# adds an OPTIONAL per-task override: a plan task may carry a `modelTier`
# (mechanical | standard | frontier) to route that one task to the cheapest model
# that fits, independent of its role default. Tiers are abstract on purpose so
# plans survive model generations; this file decides what a tier means today.
#
# Today's mapping (only opus + sonnet are in the fixed set):
#   mechanical -> claude-sonnet-4-6   (rote edits, scaffolding, mechanical fixes)
#   standard   -> claude-sonnet-4-6   (normal implementation / review throughput)
#   frontier   -> claude-opus-4-8     (judgment-heavy reasoning)
#
# Usage:
#   model-tier.sh model <mechanical|standard|frontier>
#       Print the model id for the tier. Unknown/empty tier -> standard default.
#
#   model-tier.sh valid <tier>
#       Exit 0 if tier is one of the three known tiers, else exit 1.
#
# A concrete `model` pin in task metadata still overrides this (callers check
# `model` first, then fall back to `modelTier` via this script, then the role map).

set -euo pipefail

MECHANICAL_MODEL="claude-sonnet-4-6"
STANDARD_MODEL="claude-sonnet-4-6"
FRONTIER_MODEL="claude-opus-4-8"

cmd="${1:-}"
case "$cmd" in
  model)
    case "${2:-}" in
      mechanical) printf '%s\n' "$MECHANICAL_MODEL" ;;
      frontier)   printf '%s\n' "$FRONTIER_MODEL" ;;
      standard|"") printf '%s\n' "$STANDARD_MODEL" ;;
      *)          printf '%s\n' "$STANDARD_MODEL" ;;
    esac
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
