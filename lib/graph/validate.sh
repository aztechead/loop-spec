#!/usr/bin/env bash
# Validate a loop-spec workflow graph against schema vocabulary + referential rules.
#
# Usage:
#   graph/validate.sh [--strict] <graph.json>
#
# Output: one `FLAG <file>:<pointer>: <message>` per defect, then
#   graph-validate: ok
#   graph-validate: <n> flag(s)
# Exit: 0 clean, 1 any flag, 2 bad invocation.
#
# Referential rules beyond JSON shape:
#   - route condition (and human admit) must be {probe,args,expects}; probe path
#     must be an executable file; expects must be a member of `<probe> --answers`
#     (docs/loop-spec/features/gdd/REMEDIATION-CONTRACT.md sec 2 -- this is the
#     rule that would have caught the shipped PLAN-critique-skip / lost-rewind bug)
#   - edge endpoints must name declared nodes
#   - every node reachable from entry
#   - loop edges require numeric ceiling (+ strategy)
#   - fanin edges require join
#   - chain/route/fanout/fanin subgraph must be a DAG (loop edges excluded); a
#     route back-edge is exempted only when its exact (from,to) pair also carries
#     a bounded loop edge (contract sec 9)
#   - a node body that looks like a path (contains '/') must exist in the tree
#   - every read/write key must be in the state-key space feature-init.sh actually
#     produces, derived at validate time rather than a third hardcoded copy
#
# --strict adds the rules a PUBLISHED graph must also meet (currently: every node
# carries a human-facing `label`). The shipped graphs under graph/ are checked with
# it by tests/graph-conformance.test.sh; extension authors can opt in the same way.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCHEMA="$REPO_ROOT/graph/schema.json"
FEATURE_INIT="$REPO_ROOT/lib/feature-init.sh"

STRICT=0
if [[ "${1:-}" == "--strict" ]]; then
  STRICT=1
  shift
fi

if [[ $# -ne 1 ]]; then
  echo "usage: validate.sh [--strict] <graph.json>" >&2
  exit 2
fi

GRAPH_PATH="$1"
if [[ ! -f "$GRAPH_PATH" || ! -r "$GRAPH_PATH" ]]; then
  echo "graph-validate: cannot read: $GRAPH_PATH" >&2
  exit 2
fi
if [[ ! -f "$SCHEMA" ]]; then
  echo "graph-validate: schema missing: $SCHEMA" >&2
  exit 2
fi
if [[ ! -f "$FEATURE_INIT" ]]; then
  echo "graph-validate: feature-init script missing: $FEATURE_INIT" >&2
  exit 2
fi

# Resolve to absolute for stable FLAG paths
GRAPH_ABS="$(cd "$(dirname "$GRAPH_PATH")" && pwd)/$(basename "$GRAPH_PATH")"

# The allowed read/write key space is derived from a real skeleton, not a third
# hardcoded copy of the schema's stateKey enum (which drifted twice: this exact
# copy was missing currentPhaseStartedAt and iterate). The probe args are inert
# placeholders -- feature-init.sh does not touch git or the network for `skeleton`.
SKELETON_JSON="$(bash "$FEATURE_INIT" skeleton --mode single \
  --slug graph-validate-probe --now 1970-01-01T00:00:00Z --style auto \
  --title graph-validate-probe --branch graph-validate-probe \
  --base-sha 0000000000000000000000000000000000000000 --base-branch main \
  --worktree "" --prepare "" --test "" --lint "" --typecheck "" 2>/dev/null)" || {
  echo "graph-validate: cannot derive skeleton keys from lib/feature-init.sh" >&2
  exit 2
}
SKELETON_KEYS_JSON="$(printf '%s' "$SKELETON_JSON" | jq -c 'keys' 2>/dev/null)" || {
  echo "graph-validate: cannot parse feature-init skeleton output" >&2
  exit 2
}

exec python3 "$SCRIPT_DIR/validate.py" \
  "$GRAPH_ABS" "$SCHEMA" "$REPO_ROOT" "$SKELETON_KEYS_JSON" "$STRICT"
