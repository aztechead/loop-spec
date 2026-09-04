#!/usr/bin/env bash
# store.sh - State-store port dispatcher: routes to LOOP_SPEC_STORE or store-local.sh.
#
# The feature directory on disk stays the working copy every phase reads. This port
# decides where that copy is durable between agent deaths: the checkout (the
# default, today's behavior), a mounted directory (store-mirror.sh), or whatever
# executable a supervisor names in LOOP_SPEC_STORE. The plugin never learns the
# transport. Contract and reasoning: docs/loop-spec/supervisor-interface.md; the
# executable definition is tests/lib/supervisor-store-contract.test.sh.
#
# Usage:
#   store.sh open <feature-dir>             make the working copy present
#   store.sh persist <feature-dir> <reason> make the working copy durable
#   store.sh list [<project-root>]          slugs the store holds, one per line
#   store.sh describe                       store=<name> reason=<text>
#
# Exit codes come from the adapter: 0 done, 1 not found, 2 bad invocation or a store
# that cannot hold state. A failing open/persist is loud on purpose: a store the
# supervisor chose and that cannot hold state is data loss waiting for the next death.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ADAPTER="$SCRIPT_DIR/store-local.sh"

case "${1:-}" in
  open|persist|list|describe) ;;
  *) echo "usage: store.sh open <feature-dir> | persist <feature-dir> <reason> | list [<project-root>] | describe" >&2; exit 2 ;;
esac

eval "$(bash "$SCRIPT_DIR/../profile.sh" env 2>/dev/null || true)"

adapter="${LOOP_SPEC_STORE:-$DEFAULT_ADAPTER}"
if [[ -n "${LOOP_SPEC_STORE:-}" && ( ! -f "$adapter" || ! -x "$adapter" ) ]]; then
  echo "store.sh: LOOP_SPEC_STORE='$adapter' is missing or not executable" >&2
  exit 2
fi

exec bash "$adapter" "$@"
