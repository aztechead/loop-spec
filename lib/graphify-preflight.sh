#!/usr/bin/env bash
# graphify-preflight.sh - Enforce graphify as a hard requirement for the cycle.
#
# graphify (PyPI package `graphifyy`) is loop-spec's de-facto code-graph solution.
# The design phases (SPEC / DISCUSS / PLAN) query the graph to ground their work,
# so the cycle requires it. This script is the single enforcement + status point.
#
# Usage:
#   graphify-preflight.sh check
#       Exit 0 if graphify is available (or the requirement is bypassed).
#       Exit 1 with install instructions on stderr if the binary is missing.
#
#   graphify-preflight.sh graph-status [dir]
#       Print "present" if <dir>/graphify-out/graph.json exists, else "missing".
#       dir defaults to ".".
#
#   graphify-preflight.sh build [dir]
#       Build/refresh the graph for <dir> (default "."). Uses the documented CLI:
#       `graphify <dir>` to build, `graphify <dir> --update` when a graph exists.
#       Exits non-zero on build failure so the caller can hard-fail.
#
# Env:
#   GRAPHIFY_BIN               Binary name/path (default "graphify"). For testing.
#   LOOP_SPEC_REQUIRE_GRAPHIFY Set to "0" to bypass the hard requirement (escape
#                              hatch for constrained environments). Default: required.

set -euo pipefail

GRAPHIFY_BIN="${GRAPHIFY_BIN:-graphify}"

install_hint() {
  cat >&2 <<'EOF'
loop-spec: graphify is REQUIRED but was not found on PATH.

graphify is the de-facto code-graph solution loop-spec uses to ground its design
phases (SPEC / DISCUSS / PLAN). Install it (Python 3.10+):

    uv tool install graphifyy      # recommended (manages PATH)
    # or: pipx install graphifyy
    # or: pip install graphifyy

Then register and verify:

    graphify install
    graphify --help

Code-only extraction needs no API key and runs offline.
To bypass this requirement in a constrained environment (not recommended):

    export LOOP_SPEC_REQUIRE_GRAPHIFY=0
EOF
}

has_graphify() { command -v "$GRAPHIFY_BIN" >/dev/null 2>&1; }

cmd="${1:-}"
case "$cmd" in
  check)
    if [[ "${LOOP_SPEC_REQUIRE_GRAPHIFY:-1}" == "0" ]]; then
      echo "graphify requirement bypassed (LOOP_SPEC_REQUIRE_GRAPHIFY=0)" >&2
      exit 0
    fi
    if has_graphify; then
      exit 0
    fi
    install_hint
    exit 1
    ;;
  graph-status)
    dir="${2:-.}"
    if [[ -f "${dir%/}/graphify-out/graph.json" ]]; then
      echo "present"
    else
      echo "missing"
    fi
    ;;
  build)
    dir="${2:-.}"
    if ! has_graphify; then
      if [[ "${LOOP_SPEC_REQUIRE_GRAPHIFY:-1}" == "0" ]]; then
        echo "graphify absent and requirement bypassed; skipping build" >&2
        exit 0
      fi
      install_hint
      exit 1
    fi
    if [[ -f "${dir%/}/graphify-out/graph.json" ]]; then
      "$GRAPHIFY_BIN" "$dir" --update
    else
      "$GRAPHIFY_BIN" "$dir"
    fi
    ;;
  *)
    echo "graphify-preflight.sh: unknown command '${cmd}' (check|graph-status|build)" >&2
    exit 2
    ;;
esac
