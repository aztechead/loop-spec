#!/usr/bin/env bash
# doc-deps.sh - Which third-party dependencies do these files actually import?
#
# Why: a design phase that leans on a fast-moving framework (an agent SDK, a cloud
# client) from model memory ships hacks the current docs would have prevented. The
# grounding protocol's "Current documentation" rule needs a deterministic answer to
# "which dependencies are in play for THIS change?" -- the whole manifest is context
# bloat, and judgment demonstrably never fires. This probe intersects the imports of
# the touched files with the deps the repo's manifests declare (py/js-ts/go; other
# languages report none). lib/doc-deps.py owns the matching; this launcher owns
# arguments only.
#
# Usage:
#   doc-deps.sh scan <file> [file ...]                  # probe: deps in play
#   doc-deps.sh gate --tasks <tasks.json> --artifact <PLAN.md>
#
# scan prints one line, always exit 0 (probe polarity, fails safe to none):
#   ANSWER=google-adk,fastapi REASON=imports of 3 file(s) intersected with declared dependencies
# LOOP_SPEC_DOC_DEPS=<comma-list|none> overrides the scan (operator outranks probe).
#
# gate re-derives the deps from every task's files[] and requires each to appear in
# the artifact's ## Grounding section (an EVID doc citation or an ASSUMPTION line;
# offline runs pass via ASSUMPTION). Exit codes (gate polarity, matching
# lib/grounding-lint.sh): 0 ok, 1 FLAG(s), 2 usage error.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MODE="${1:-}"
case "$MODE" in
  scan) [[ $# -ge 2 ]] || { echo "usage: doc-deps.sh scan <file> [file ...]" >&2; exit 2; } ;;
  gate) [[ $# -eq 5 ]] || { echo "usage: doc-deps.sh gate --tasks <tasks.json> --artifact <PLAN.md>" >&2; exit 2; } ;;
  *) echo "usage: doc-deps.sh <scan|gate> ..." >&2; exit 2 ;;
esac

exec python3 "$SCRIPT_DIR/doc-deps.py" "$@"
