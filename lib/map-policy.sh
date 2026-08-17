#!/usr/bin/env bash
# Resolve operator policy for the two automatic codebase-map stages.
set -euo pipefail

case "${1:-}" in
  bootstrap) value="${LOOP_SPEC_MAP_BOOTSTRAP:-1}"; variable="LOOP_SPEC_MAP_BOOTSTRAP" ;;
  refresh) value="${LOOP_SPEC_MAP_REFRESH:-1}"; variable="LOOP_SPEC_MAP_REFRESH" ;;
  *) echo "usage: map-policy.sh {bootstrap|refresh}" >&2; exit 2 ;;
esac

case "$value" in
  1) echo "run" ;;
  0) echo "skip" ;;
  *) echo "map-policy.sh: $variable must be 0 or 1" >&2; exit 2 ;;
esac
