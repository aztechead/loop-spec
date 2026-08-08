#!/usr/bin/env bash
# Per-node checkpoint ledger — append-only records at each graph boundary.
#
# Usage:
#   checkpoint.sh append --feature-dir DIR --node ID --edge EDGE --effort MODE
#   checkpoint.sh latest --feature-dir DIR
#
# Ledger path: <feature_dir>/graph-checkpoints.jsonl
# Each record: {node, stateHash, gitSha, ts, effort, edge}
#
# latest prints one JSON object, or {"empty":true} when the ledger has no records.
set -euo pipefail

usage() {
  echo "usage: checkpoint.sh append --feature-dir DIR --node ID --edge EDGE --effort MODE" >&2
  echo "       checkpoint.sh latest --feature-dir DIR" >&2
  exit 2
}

[[ $# -ge 1 ]] || usage
cmd="$1"; shift

feature_dir=""
node=""
edge=""
effort=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --feature-dir) feature_dir="${2:-}"; shift 2 ;;
    --node) node="${2:-}"; shift 2 ;;
    --edge) edge="${2:-}"; shift 2 ;;
    --effort) effort="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -n "$feature_dir" ]] || usage
ledger="$feature_dir/graph-checkpoints.jsonl"

case "$cmd" in
  latest)
    if [[ ! -f "$ledger" ]] || [[ ! -s "$ledger" ]]; then
      echo '{"empty":true}'
      exit 0
    fi
    tail -n 1 "$ledger"
    exit 0
    ;;
  append)
    [[ -n "$node" && -n "$edge" && -n "$effort" ]] || usage
    [[ -d "$feature_dir" ]] || { echo "checkpoint.sh: feature dir missing" >&2; exit 1; }
    fj="$feature_dir/feature.json"
    if [[ -f "$fj" ]]; then
      state_hash="$(cksum <"$fj" | awk '{print $1"-"$2}')"
    else
      state_hash="no-feature-json"
    fi
    git_sha="$(git -C "$feature_dir" rev-parse HEAD 2>/dev/null \
      || git rev-parse HEAD 2>/dev/null \
      || echo unknown)"
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mkdir -p "$feature_dir"
    jq -cn \
      --arg node "$node" \
      --arg stateHash "$state_hash" \
      --arg gitSha "$git_sha" \
      --arg ts "$ts" \
      --arg effort "$effort" \
      --arg edge "$edge" \
      '{node:$node, stateHash:$stateHash, gitSha:$gitSha, ts:$ts, effort:$effort, edge:$edge}' \
      >> "$ledger"
    exit 0
    ;;
  *)
    usage
    ;;
esac
