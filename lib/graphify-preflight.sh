#!/usr/bin/env bash
# graphify-preflight.sh - Enforce graphify as a hard requirement for the cycle.
#
# graphify (PyPI package `graphifyy`) is loop-spec's de-facto knowledge-graph solution.
# The design phases (SPEC / DISCUSS / PLAN) query the graph to ground their work,
# so the cycle requires it. The assistant skill builds the graph; this script
# owns deterministic package checks, output validation, and staging policy.
#
# Usage:
#   graphify-preflight.sh check
#       Exit 0 if graphify is available (or the requirement is bypassed).
#       Exit 1 with install instructions on stderr if the binary is missing.
#
#   graphify-preflight.sh graph-status [dir]
#       Print "present" when <dir> has a non-empty, queryable graph plus the
#       report consumed by design phases; otherwise print "missing".
#
#   graphify-preflight.sh validate [dir]
#       Validate the complete assistant-skill output contract and print a
#       specific error on failure.
#
#   graphify-preflight.sh stage [dir]
#       Stage shared graph artifacts in the repository at <dir>. Local cache,
#       cost, interpreter, root, temporary, and backup files are excluded and
#       removed from the index if an older loop-spec run tracked them.
#
# Env:
#   GRAPHIFY_BIN               Binary name/path (default "graphify"). For testing.
#   LOOP_SPEC_REQUIRE_GRAPHIFY Set to "0" to bypass the hard requirement (escape
#                              hatch for constrained environments). Default: required.

set -euo pipefail

GRAPHIFY_BIN="${GRAPHIFY_BIN:-graphify}"

install_hint() {
  local register="graphify install"
  case "${LOOP_SPEC_HARNESS:-claude}" in
    pi) register="graphify install --platform pi" ;;
    opencode) register="graphify install --platform opencode" ;;
  esac
  cat >&2 <<'EOF'
loop-spec: graphify is REQUIRED but was not found on PATH.

graphify is the de-facto code-graph solution loop-spec uses to ground its design
phases (SPEC / DISCUSS / PLAN). Install it (Python 3.10+):

    uv tool install graphifyy      # recommended (manages PATH)
    # or: pipx install graphifyy
    # or: pip install graphifyy

Then register its assistant skill for this harness and verify:
EOF
  printf '\n    %s\n    graphify --help\n\n' "$register" >&2
  cat >&2 <<'EOF'
The assistant skill uses the current host model and authentication for semantic
content; AST code extraction remains local.
To bypass this requirement in a constrained environment (not recommended):

    export LOOP_SPEC_REQUIRE_GRAPHIFY=0
EOF
}

has_graphify() { command -v "$GRAPHIFY_BIN" >/dev/null 2>&1; }

validate_graph() {
  local dir="${1%/}"
  local out="$dir/graphify-out"
  local required
  for required in graph.json GRAPH_REPORT.md manifest.json graph.html; do
    [[ -s "$out/$required" ]] || {
      echo "loop-spec: invalid graphify output: missing or empty $out/$required" >&2
      return 1
    }
  done
  jq -e '
    (.nodes | type == "array" and length > 0) and
    all(.nodes[];
      (.id | type == "string" and length > 0) and
      (.label | type == "string" and length > 0 and (test("^[0-9a-fA-F]{16,}$") | not))
    )
  ' "$out/graph.json" >/dev/null 2>&1 || {
    echo "loop-spec: invalid graphify output: graph.json needs non-empty nodes with human-readable id and label values" >&2
    return 1
  }
  jq -e 'type == "object"' "$out/manifest.json" >/dev/null 2>&1 || {
    echo "loop-spec: invalid graphify output: manifest.json must be a JSON object" >&2
    return 1
  }
}

graph_is_usable() {
  validate_graph "$1" >/dev/null 2>&1
}

stage_graph() {
  local dir="${1%/}" exclude marker
  [[ -d "$dir/graphify-out" ]] || {
    echo "loop-spec: no graphify-out directory to stage under $dir" >&2
    return 1
  }
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "loop-spec: cannot stage graphify outputs outside a git repository: $dir" >&2
    return 1
  }

  # Graphify recommends committing its outputs, but these paths are explicitly
  # local or disposable. Keep the policy clone-local so loop-spec does not
  # rewrite a consumer repository's .gitignore.
  exclude="$(git -C "$dir" rev-parse --path-format=absolute --git-path info/exclude)"
  marker="# loop-spec graphify local artifacts"
  if [[ ! -f "$exclude" ]] || [[ "$(<"$exclude")" != *"$marker"* ]]; then
    printf '%s\n' \
      "$marker" \
      '/graphify-out/cost.json' \
      '/graphify-out/cache/' \
      '/graphify-out/.graphify_python' \
      '/graphify-out/.graphify_root' \
      '/graphify-out/.graphify_chunk_*.json' \
      '/graphify-out/.graphify_detect*.json' \
      '/graphify-out/.graphify_extract*.json' \
      '/graphify-out/.graphify_ast*.json' \
      '/graphify-out/.graphify_semantic*.json' \
      '/graphify-out/.graphify_cached*.json' \
      '/graphify-out/.graphify_incremental*.json' \
      '/graphify-out/.graphify_old*.json' \
      '/graphify-out/.graphify_uncached.txt' \
      '/graphify-out/.graphify_pending*' \
      '/graphify-out/.needs_update' \
      '/graphify-out/*.tmp' \
      '/graphify-out/*.lock' \
      '/graphify-out/????-??-??/' >> "$exclude"
  fi

  # Migrate repositories bootstrapped by the old blanket `git add graphify-out/`.
  git -C "$dir" rm -r --cached --ignore-unmatch -q -- \
    graphify-out/cost.json \
    graphify-out/cache \
    graphify-out/.graphify_python \
    graphify-out/.graphify_root \
    graphify-out/.graphify_uncached.txt
  git -C "$dir" rm -r --cached --ignore-unmatch -q -- \
    ':(glob)graphify-out/.graphify_chunk_*.json' \
    ':(glob)graphify-out/.graphify_detect*.json' \
    ':(glob)graphify-out/.graphify_extract*.json' \
    ':(glob)graphify-out/.graphify_ast*.json' \
    ':(glob)graphify-out/.graphify_semantic*.json' \
    ':(glob)graphify-out/.graphify_cached*.json' \
    ':(glob)graphify-out/.graphify_incremental*.json' \
    ':(glob)graphify-out/.graphify_old*.json' \
    ':(glob)graphify-out/.graphify_pending*' \
    graphify-out/.needs_update \
    ':(glob)graphify-out/*.tmp' \
    ':(glob)graphify-out/*.lock' \
    ':(glob)graphify-out/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/**'
  git -C "$dir" add -A -- graphify-out/
}

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
    if graph_is_usable "$dir"; then
      echo "present"
    else
      echo "missing"
    fi
    ;;
  validate)
    validate_graph "${2:-.}"
    ;;
  stage)
    stage_graph "${2:-.}"
    ;;
  *)
    echo "graphify-preflight.sh: unknown command '${cmd}' (check|graph-status|validate|stage)" >&2
    exit 2
    ;;
esac
