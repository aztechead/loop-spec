#!/usr/bin/env bash
# Handoff port dispatcher — routes to LOOP_SPEC_PORT or port-local.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ADAPTER="$SCRIPT_DIR/port-local.sh"

if [[ $# -lt 1 ]]; then
  echo "usage: port.sh put|get|list|claim|release|complete ..." >&2
  exit 2
fi

adapter="${LOOP_SPEC_PORT:-$DEFAULT_ADAPTER}"

if [[ -n "${LOOP_SPEC_PORT:-}" ]]; then
  if [[ ! -f "$adapter" || ! -x "$adapter" ]]; then
    echo "port.sh: LOOP_SPEC_PORT='$adapter' is missing or not executable" >&2
    exit 1
  fi
else
  [[ -x "$adapter" ]] || chmod +x "$adapter"
fi

exec bash "$adapter" "$@"
