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
graph_path="${LOOP_SPEC_GRAPH:-$REPO_ROOT/graph/cycle.graph.json}"
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
    unsatisfied="$(python3 - "$feature_dir/feature.json" "$reads" <<'PY'
import json, sys
feat = json.load(open(sys.argv[1]))
reads = json.loads(sys.argv[2])
bad = []
for key in reads:
    if key not in feat or feat[key] is None:
        bad.append(key)
print("\n".join(bad))
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
