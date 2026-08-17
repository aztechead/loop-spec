#!/usr/bin/env bash
# Select phase-by-phase state commits or one final state commit at delivery.
set -euo pipefail

[[ "${1:-}" == "mode" && $# -eq 1 ]] || {
  echo "usage: state-commit-policy.sh mode" >&2
  exit 2
}
case "${LOOP_SPEC_SQUASH_STATE_COMMITS:-0}" in
  0) echo "phase" ;;
  1) echo "final" ;;
  *) echo "state-commit-policy.sh: LOOP_SPEC_SQUASH_STATE_COMMITS must be 0 or 1" >&2; exit 2 ;;
esac
