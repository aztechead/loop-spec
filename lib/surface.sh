#!/usr/bin/env bash
# Answer "which bundled script or contract covers X?" from the tree, at call time.
#
# Why: the bundled surface is over a hundred `lib/` scripts plus every shared contract and
# role charter. A phase agent that needs one of them has no cheaper move than
# glob-then-grep-then-open-three-files — measured on mocked sessions, locating two scripts
# and their exit contract cost three full file reads that this answers in one call. The
# cost is paid by EVERY agent, on EVERY phase, and it is pure navigation: none of it is
# the work the agent was dispatched to do.
#
# This is NOT a stored map. Nothing is written, nothing is cached, and there is no
# artifact to fall out of date (CLAUDE.md: "Stored maps rot, and a rotted map is worse
# than none because it is wrong with authority"). Every answer is read from the files
# that exist right now, so a renamed script is renamed here the same instant.
#
# The purpose line comes from each file's own header — the file-header purpose block the
# house style already requires and `tests/lib/surface.test.sh` now enforces across the
# whole tree. Writing a header IS writing the index entry; there is no second place to
# update. `lib/surface.py` owns the derivation rules; this launcher owns arguments only.
#
# Usage:
#   surface.sh list [lib|shared|all]     every entry: kind<TAB>path<TAB>purpose
#   surface.sh find <term> [term ...]    entries whose path or purpose matches EVERY term
#   surface.sh show <path-or-name>       one entry's full header block (usage, exit codes)
#   surface.sh covers <path> [path ...]  the registered test suites that name each path
#
# Exit: 0 with results, 1 when a query matches nothing, 2 bad invocation.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  echo "usage: surface.sh list [lib|shared|all]" >&2
  echo "       surface.sh find <term> [term ...]" >&2
  echo "       surface.sh show <path-or-name>" >&2
  exit 2
}

[[ $# -ge 1 ]] || usage
cmd="$1"; shift

exec python3 "$SCRIPT_DIR/surface.py" "$ROOT" "$cmd" "$@"
