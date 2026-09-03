#!/usr/bin/env bash
# store-local.sh - Default state-store adapter: the checkout is the store.
#
# This is today's behavior behind the port. The feature directory lives in the
# checkout and lib/phase-exit.sh commits it at each phase transition, so open and
# persist have nothing to do. persist cannot fail, which is what a default must
# promise; open fails only when the checkout holds no working copy, because there is
# nowhere else to look.
#
# Usage:
#   store-local.sh open <feature-dir>
#   store-local.sh persist <feature-dir> <reason>
#   store-local.sh list [<project-root>]     directories under <root>/.loop-spec/features
#   store-local.sh describe
#
# Exit codes: 0 done, 1 open found no working copy, 2 bad invocation.
set -euo pipefail

usage() { echo "usage: store-local.sh open <feature-dir> | persist <feature-dir> <reason> | list [<project-root>] | describe" >&2; exit 2; }

case "${1:-}" in
  open)
    [[ $# -eq 2 && -n "$2" ]] || usage
    [[ -f "$2/feature.json" ]] || { echo "store-local: $(basename "$2") has no working copy at $2 and the checkout is the only store" >&2; exit 1; }
    printf 'opened=%s source=working-copy\n' "$(basename "$2")"
    ;;
  persist)
    [[ $# -eq 3 && -n "$2" && -n "$3" ]] || usage
    printf 'persisted=%s store=local\n' "$(basename "$2")"
    ;;
  list)
    [[ $# -le 2 ]] || usage
    root="${2:-${CLAUDE_PROJECT_DIR:-$PWD}}"
    for d in "$root"/.loop-spec/features/*/; do
      [[ -f "$d/feature.json" ]] || continue
      basename "$d"
    done
    ;;
  describe)
    [[ $# -eq 1 ]] || usage
    echo "store=local reason=checkout-is-store"
    ;;
  *) usage ;;
esac
