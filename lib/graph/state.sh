#!/usr/bin/env bash
# Typed state channel over feature.json — declaration layer, not a second store.
#
# Writes always delegate to lib/feature-write.sh (or LOOP_SPEC_FEATURE_WRITE).
# This script never mutates feature.json itself.
#
# Usage:
#   state.sh assert-reads --feature-dir DIR --node NODE_ID [--graph PATH]
#   state.sh write --feature-dir DIR --node NODE_ID --key KEY <json-value> [--graph PATH]
#
# Exit: 0 ok; 1 contract violation / write failure; 2 bad invocation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FEATURE_WRITE="${LOOP_SPEC_FEATURE_WRITE:-$REPO_ROOT/lib/feature-write.sh}"

usage() {
  echo "usage: state.sh assert-reads --feature-dir DIR --node ID [--graph PATH]" >&2
  echo "       state.sh write --feature-dir DIR --node ID --key KEY <json> [--graph PATH]" >&2
  exit 2
}

[[ $# -ge 1 ]] || usage
cmd="$1"; shift

feature_dir=""
node_id=""
graph_path=""
key=""
value=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --feature-dir) feature_dir="${2:-}"; shift 2 ;;
    --node) node_id="${2:-}"; shift 2 ;;
    --graph) graph_path="${2:-}"; shift 2 ;;
    --key) key="${2:-}"; shift 2 ;;
    *)
      if [[ "$cmd" == "write" && -z "$value" && "$1" != --* ]]; then
        value="$1"; shift
      else
        usage
      fi
      ;;
  esac
done

[[ -n "$feature_dir" && -n "$node_id" ]] || usage
[[ -z "$graph_path" ]] && graph_path="$REPO_ROOT/graph/cycle.graph.json"
[[ -f "$feature_dir/feature.json" ]] || {
  echo "state.sh: feature.json not found in $feature_dir" >&2
  exit 1
}
[[ -f "$graph_path" ]] || {
  echo "state.sh: graph not found: $graph_path" >&2
  exit 1
}

node_json="$(jq -c --arg id "$node_id" '.nodes[] | select(.id==$id)' "$graph_path")"
[[ -n "$node_json" ]] || {
  echo "state.sh: unknown node: $node_id" >&2
  exit 1
}

case "$cmd" in
  assert-reads)
    reads="$(jq -c '.reads // []' <<<"$node_json")"
    # Workspace mode relocates branch/baseSha/baseBranch onto workspace.repos[]
    # and leaves the top-level keys null by design (feature-state-schema.md).
    # A flat feat[key] is None check treats that as a missing read, so the
    # shipped execute node (reads: [..., "branch"]) always failed the gate.
    unsatisfied="$(python3 - "$feature_dir/feature.json" "$reads" <<'PY'
import json, sys

# The only keys the schema relocates. Every other key stays top-level in both
# modes, so a null one is a missing read here exactly as it is in single mode.
RELOCATED = ("branch", "baseSha", "baseBranch")

feat = json.load(open(sys.argv[1]))
reads = json.loads(sys.argv[2])
ws = feat.get("workspace")
repos = ws.get("repos") if isinstance(ws, dict) else None
if not isinstance(repos, list):
    repos = None

def repo_has(repo, key):
    if not isinstance(repo, dict):
        return False
    val = repo.get(key)
    return isinstance(val, str) and val.strip() != ""

def satisfied(key):
    if key in feat and feat[key] is not None:
        return True
    if repos is None or key not in RELOCATED:
        return False
    # An empty repos[] is a workspace with no authoritative identity at all.
    return len(repos) > 0 and all(repo_has(r, key) for r in repos)

print("\n".join(key for key in reads if not satisfied(key)))
PY
)"
    if [[ -n "$unsatisfied" ]]; then
      echo "state.sh: unsatisfied reads for node $node_id:" >&2
      printf '%s\n' "$unsatisfied" >&2
      exit 1
    fi
    exit 0
    ;;
  write)
    [[ -n "$key" && -n "$value" ]] || usage
    allowed="$(jq -r --arg k "$key" '.writes // [] | index($k) != null' <<<"$node_json")"
    if [[ "$allowed" != "true" ]]; then
      echo "state.sh: key '$key' not in writes[] for node $node_id" >&2
      exit 1
    fi
    bash "$FEATURE_WRITE" set "$feature_dir" "$key" "$value"
    exit $?
    ;;
  *)
    usage
    ;;
esac
