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
#   graphify-preflight.sh freshness [dir]
#       Print "fresh" only when the complete local graph was stamped from the
#       exact current source snapshot. Prints "stale" for every other case.
#
#   graphify-preflight.sh stamp [dir]
#       Record the current source snapshot after a successful assistant-owned
#       build/update. The stamp remains local with graphify-out/.
#
#   graphify-preflight.sh localize [dir]
#       Keep generated graph output local to this checkout. Graphify is valuable
#       navigation state while a cycle runs, but a semantic refresh can rewrite the
#       entire graph for a tiny feature. Never stage it on a feature branch: refresh
#       it after merge or from a dedicated graph-maintenance checkout instead.
#
#   graphify-preflight.sh publish [dir]
#       Explicit out-of-band operation: re-enable tracked graph paths and stage only
#       portable Graphify output for review on a default/maintenance branch. This is
#       never called by a feature cycle.
#
# Env:
#   GRAPHIFY_BIN               Binary name/path (default "graphify"). For testing.
#   LOOP_SPEC_REQUIRE_GRAPHIFY Set to "0" to bypass the hard requirement (escape
#                              hatch for constrained environments). Default: required.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GRAPHIFY_BIN="${GRAPHIFY_BIN:-graphify}"
FRESHNESS_SCHEMA=1
FRESHNESS_FILE=".loop-spec-source-fingerprint.json"

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

# Graphify is semantically expensive, so a valid graph may be reused only when
# its source inputs are byte-for-byte the same. This is a source-tree proof, not
# a timestamp or an assertion that a prior Graphify invocation happened. Runtime
# state and Graphify's own derived output are excluded; every other tracked file
# (including documentation, papers, and images) remains an input.
source_fingerprint() {
  local dir="${1%/}" status
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1

  # A dirty source tree cannot match a committed-content fingerprint. Fail
  # closed to a Graphify update instead of potentially reusing stale output.
  status="$(git -C "$dir" status --porcelain --untracked-files=all -- \
    . \
    ':(exclude).loop-spec/**' \
    ':(exclude)graphify-out/**' 2>/dev/null)" || return 1
  [[ -z "$status" ]] || return 1

  # ls-files -s contains mode, blob id, and NUL-delimited path, so content,
  # rename, and executable-bit changes all invalidate the stamp.
  git -C "$dir" ls-files -s -z -- \
    . \
    ':(exclude).loop-spec/**' \
    ':(exclude)graphify-out/**' \
    | python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
}

graph_freshness() {
  local dir="${1%/}" fingerprint stamp
  if ! graph_is_usable "$dir"; then
    printf '%s\n' "stale"
    return 0
  fi
  fingerprint="$(source_fingerprint "$dir" 2>/dev/null || true)"
  [[ -n "$fingerprint" ]] || { printf '%s\n' "stale"; return 0; }
  stamp="$dir/graphify-out/$FRESHNESS_FILE"
  if [[ -f "$stamp" ]] \
    && jq -e --argjson schema "$FRESHNESS_SCHEMA" --arg fingerprint "$fingerprint" '
         .schema == $schema and .sourceFingerprint == $fingerprint
       ' "$stamp" >/dev/null 2>&1; then
    printf '%s\n' "fresh"
  else
    printf '%s\n' "stale"
  fi
}

stamp_freshness() {
  local dir="${1%/}" fingerprint stamp tmp
  validate_graph "$dir"
  fingerprint="$(source_fingerprint "$dir")" || {
    echo "loop-spec: cannot stamp graph freshness over changed source inputs: $dir" >&2
    return 1
  }
  stamp="$dir/graphify-out/$FRESHNESS_FILE"
  tmp="${stamp}.tmp.$$"
  jq -cn --argjson schema "$FRESHNESS_SCHEMA" --arg fingerprint "$fingerprint" \
    '{schema: $schema, sourceFingerprint: $fingerprint}' > "$tmp"
  mv "$tmp" "$stamp"
}

localize_graph() {
  local dir="${1%/}"
  [[ -d "$dir/graphify-out" ]] || {
    echo "loop-spec: no graphify-out directory to localize under $dir" >&2
    return 1
  }
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "loop-spec: cannot localize graphify outputs outside a git repository: $dir" >&2
    return 1
  }

  # Keep every newly generated file ignored. Existing repositories may still track a
  # historical graph; mark those paths skip-worktree so a feature branch cannot
  # accidentally add a massive rewrite to its delivery commit. This is deliberately
  # local repository metadata, not a tracked .gitignore policy imposed on consumers.
  bash "$SCRIPT_DIR/runtime-ignore.sh" ensure "$dir"
  # If an older instruction already staged Graphify output, remove it from the
  # index before DELIVER sees it. Do not touch any other staged path.
  git -C "$dir" restore --staged --source=HEAD -- graphify-out/ 2>/dev/null || true

  while IFS= read -r -d '' path; do
    git -C "$dir" update-index --skip-worktree -- "$path"
  done < <(git -C "$dir" ls-files -z -- graphify-out/ 2>/dev/null || true)
}

publish_graph() {
  local dir="${1%/}"
  [[ -d "$dir/graphify-out" ]] || {
    echo "loop-spec: no graphify-out directory to publish under $dir" >&2
    return 1
  }
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "loop-spec: cannot publish graphify outputs outside a git repository: $dir" >&2
    return 1
  }

  # This is the intentional inverse of localize for a dedicated generated-data
  # review. Do not run it from the feature lifecycle.
  while IFS= read -r -d '' path; do
    git -C "$dir" update-index --no-skip-worktree -- "$path"
  done < <(git -C "$dir" ls-files -z -- graphify-out/ 2>/dev/null || true)
  git -C "$dir" add -f -A -- graphify-out/

  # Retain the portable graph and analysis outputs, but never stage host/cache/temp
  # files even when the caller used the explicit publish command.
  git -C "$dir" reset -q HEAD -- \
    graphify-out/cost.json \
    graphify-out/cache \
    graphify-out/.graphify_python \
    graphify-out/.graphify_root \
    graphify-out/.graphify_uncached.txt \
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
    graphify-out/.loop-spec-source-fingerprint.json \
    ':(glob)graphify-out/*.tmp' \
    ':(glob)graphify-out/*.lock' \
    ':(glob)graphify-out/[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/**' \
    2>/dev/null || true
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
  freshness)
    graph_freshness "${2:-.}"
    ;;
  stamp)
    stamp_freshness "${2:-.}"
    ;;
  localize)
    localize_graph "${2:-.}"
    ;;
  publish)
    publish_graph "${2:-.}"
    ;;
  *)
    echo "graphify-preflight.sh: unknown command '${cmd}' (check|graph-status|validate|freshness|stamp|localize|publish)" >&2
    exit 2
    ;;
esac
