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
# latest prints one JSON object, or {"empty":true} when the ledger holds no PARSEABLE
# record. A ledger truncated mid-append (a killed run, a full disk) leaves a partial last
# line; the engine json.loads() that output, so an unvalidated tail turned a recoverable
# resume into a traceback. Scanning back to the last parseable record keeps resume working
# and keeps "no usable checkpoint" a defined state rather than a crash.
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
    latest_record=""
    while IFS= read -r record; do
      [[ -n "${record//[[:space:]]/}" ]] || continue
      jq -e 'type == "object"' >/dev/null 2>&1 <<<"$record" || continue
      latest_record="$record"
    done < "$ledger"
    if [[ -z "$latest_record" ]]; then
      echo '{"empty":true}'
      exit 0
    fi
    printf '%s\n' "$latest_record"
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
