#!/usr/bin/env bash
# Node-instance bundle export/import — content-addressed, self-contained.
#
# Usage:
#   handoff.sh export --feature-dir DIR --node ID --verify CMD --out FILE [--graph PATH]
#   handoff.sh import --feature-dir DIR --bundle FILE
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

usage() {
  echo "usage: handoff.sh export --feature-dir DIR --node ID --verify CMD --out FILE [--graph PATH]" >&2
  echo "       handoff.sh import --feature-dir DIR --bundle FILE" >&2
  exit 2
}

[[ $# -ge 1 ]] || usage
cmd="$1"; shift

feature_dir=""; node=""; verify=""; out=""; bundle=""; graph=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --feature-dir) feature_dir="${2:-}"; shift 2 ;;
    --node) node="${2:-}"; shift 2 ;;
    --verify) verify="${2:-}"; shift 2 ;;
    --out) out="${2:-}"; shift 2 ;;
    --bundle) bundle="${2:-}"; shift 2 ;;
    --graph) graph="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

case "$cmd" in
  export)
    [[ -n "$feature_dir" && -n "$node" && -n "$verify" && -n "$out" ]] || usage
    [[ -f "$feature_dir/feature.json" ]] || { echo "handoff: missing feature.json" >&2; exit 1; }
    state_hash="$(cksum <"$feature_dir/feature.json" | awk '{print $1"-"$2}')"
    base_sha="$(jq -r '.baseSha // empty' "$feature_dir/feature.json")"
    [[ -z "$graph" ]] && graph="$REPO_ROOT/graph/cycle.graph.json"
    contract="$(jq -c --arg id "$node" '.nodes[] | select(.id==$id)' "$graph" 2>/dev/null || echo '{}')"
    jq -cn \
      --arg id "$node" \
      --arg node "$node" \
      --arg stateHash "$state_hash" \
      --arg verifyCommand "$verify" \
      --arg baseSha "$base_sha" \
      --argjson contract "$contract" \
      --argjson inputs "$(jq -c '{slug:.slug,currentPhase:.currentPhase,branch:.branch}' "$feature_dir/feature.json")" \
      '{id:$id,node:$node,stateHash:$stateHash,verifyCommand:$verifyCommand,baseSha:$baseSha,contract:$contract,inputs:$inputs}' \
      > "$out"
    ;;
  import)
    [[ -n "$feature_dir" && -n "$bundle" && -f "$bundle" ]] || usage
    [[ -f "$feature_dir/feature.json" ]] || { echo "handoff: missing feature.json" >&2; exit 1; }
    expected="$(cksum <"$feature_dir/feature.json" | awk '{print $1"-"$2}')"
    got="$(jq -r '.stateHash // empty' "$bundle")"
    if [[ "$expected" != "$got" ]]; then
      echo "handoff: state hash mismatch; rejecting stale return (expected=$expected got=$got)" >&2
      exit 1
    fi
    echo "handoff: import accepted"
    ;;
  *)
    usage
    ;;
esac
