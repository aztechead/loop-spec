#!/usr/bin/env bash
# Node-instance bundle export/import — content-addressed, self-contained.
#
# Usage:
#   handoff.sh export --feature-dir DIR --node ID --verify CMD --out FILE [--task ID] [--graph PATH] [--brief TEXT] [--files JSON]
#   handoff.sh import --feature-dir DIR --bundle FILE
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

usage() {
  echo "usage: handoff.sh export --feature-dir DIR --node ID --verify CMD --out FILE [--task ID] [--graph PATH] [--brief TEXT] [--files JSON]" >&2
  echo "       handoff.sh import --feature-dir DIR --bundle FILE" >&2
  exit 2
}

[[ $# -ge 1 ]] || usage
cmd="$1"; shift

feature_dir=""; node=""; verify=""; out=""; bundle=""; graph=""; task=""; brief=""; files="[]"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --feature-dir) feature_dir="${2:-}"; shift 2 ;;
    --node) node="${2:-}"; shift 2 ;;
    --task) task="${2:-}"; shift 2 ;;
    --verify) verify="${2:-}"; shift 2 ;;
    --out) out="${2:-}"; shift 2 ;;
    --bundle) bundle="${2:-}"; shift 2 ;;
    --graph) graph="${2:-}"; shift 2 ;;
    --brief) brief="${2:-}"; shift 2 ;;
    --files) files="${2:-}"; shift 2 ;;
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
    # inputs must cover every key contract.reads declares, or a claimant can't
    # satisfy the reads it was promised without reaching back into the
    # originating session. slug/currentPhase/branch are always included as
    # baseline identity even when a node's reads don't name them.
    inputs="$(jq -c --argjson reads "$(jq -c '.reads // []' <<<"$contract")" \
      '. as $f | (reduce $reads[] as $k ({}; . + {($k): ($f[$k] // null)}))
       + {slug: $f.slug, currentPhase: $f.currentPhase, branch: $f.branch}' \
      "$feature_dir/feature.json")"
    # Instance id is content-addressed from node + task + state hash, so two
    # task bundles under the same node (e.g. two EXECUTE tasks both handed
    # out as execute.worker) never collide (SPEC.md:61-62).
    id_base="$node"
    [[ -n "$task" ]] && id_base="${node}.${task}"
    content_hash="$(cksum <<<"${id_base}|${state_hash}" | awk '{print $1"-"$2}')"
    id="${id_base}.${content_hash}"
    jq -e . <<<"$files" >/dev/null 2>&1 || { echo "handoff: --files must be a JSON array" >&2; exit 2; }
    # brief/files close the gap a bundle otherwise leaves for a claimant that
    # shares nothing with the originating session: inputs+verifyCommand tell
    # it what STATE the task runs against and how to check its own output,
    # but not what to build or where the result belongs. Both mirror fields
    # the planner already carries per task (skills/plan/SKILL.md's
    # {..., files, ..., brief, verifyCommand} shape) -- this just threads them
    # onto the bundle instead of leaving them behind in the caller's session.
    jq -cn \
      --arg id "$id" \
      --arg node "$node" \
      --arg task "$task" \
      --arg stateHash "$state_hash" \
      --arg verifyCommand "$verify" \
      --arg baseSha "$base_sha" \
      --arg brief "$brief" \
      --argjson files "$files" \
      --argjson contract "$contract" \
      --argjson inputs "$inputs" \
      '{id:$id,node:$node,task:(if $task == "" then null else $task end),stateHash:$stateHash,verifyCommand:$verifyCommand,baseSha:$baseSha,brief:(if $brief == "" then null else $brief end),files:$files,contract:$contract,inputs:$inputs}' \
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
