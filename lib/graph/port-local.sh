#!/usr/bin/env bash
# Reference handoff-port adapter — stores instances under the feature directory.
# Conformance target, not a recommended production substrate.
set -euo pipefail

ROOT_DIR="${LOOP_SPEC_PORT_ROOT:-}"
usage() { echo "usage: port-local.sh put|get|list|claim|release|complete ..." >&2; exit 2; }

[[ $# -ge 1 ]] || usage
op="$1"; shift

store_root() {
  if [[ -n "$ROOT_DIR" ]]; then
    printf '%s' "$ROOT_DIR"
  else
    printf '%s' "${TMPDIR:-/tmp}/loop-spec-port-local"
  fi
}

ROOT="$(store_root)"
INST="$ROOT/instances"
mkdir -p "$INST"

case "$op" in
  put)
    [[ $# -eq 1 && -f "$1" ]] || usage
    bundle="$1"
    jq -e . "$bundle" >/dev/null || { echo "port-local: invalid bundle JSON" >&2; exit 1; }
    id="$(jq -r '.id // empty' "$bundle")"
    if [[ -z "$id" ]]; then
      id="inst-$(cksum <"$bundle" | awk '{print $1}')"
      tmp="$(mktemp)"
      jq --arg id "$id" '. + {id:$id}' "$bundle" > "$tmp"
      bundle="$tmp"
    fi
    dir="$INST/$id"
    mkdir -p "$dir"
    cp "$bundle" "$dir/bundle.json"
    printf 'id=%s\n' "$id"
    ;;
  get)
    [[ $# -eq 1 ]] || usage
    id="$1"
    [[ -f "$INST/$id/bundle.json" ]] || { echo "port-local: missing $id" >&2; exit 1; }
    cat "$INST/$id/bundle.json"
    ;;
  list)
    claimable=0
    [[ "${1:-}" == "--claimable" ]] && claimable=1
    now="$(date -u +%s)"
    for d in "$INST"/*; do
      [[ -d "$d" ]] || continue
      id="$(basename "$d")"
      if [[ "$claimable" -eq 1 ]]; then
        if [[ -f "$d/claim.json" ]]; then
          exp="$(jq -r '.expires // 0' "$d/claim.json")"
          (( now < exp )) && continue
        fi
      fi
      printf '%s\n' "$id"
    done
    ;;
  claim)
    [[ $# -eq 3 ]] || usage
    id="$1"; owner="$2"; ttl="$3"
    [[ -d "$INST/$id" ]] || { echo "port-local: missing $id" >&2; exit 1; }
    [[ "$ttl" =~ ^[0-9]+$ ]] || usage
    now="$(date -u +%s)"
    claim_file="$INST/$id/claim.json"
    lock="$INST/$id/claim.lock"
    # Atomic claim via mkdir lock
    if ! mkdir "$lock" 2>/dev/null; then
      # lock held — check expiry of existing claim
      if [[ -f "$claim_file" ]]; then
        exp="$(jq -r '.expires // 0' "$claim_file")"
        if (( now < exp )); then
          echo "port-local: already claimed" >&2
          exit 1
        fi
        rmdir "$lock" 2>/dev/null || rm -rf "$lock"
        mkdir "$lock" 2>/dev/null || { echo "port-local: already claimed" >&2; exit 1; }
      else
        echo "port-local: already claimed" >&2
        exit 1
      fi
    fi
    if [[ -f "$claim_file" ]]; then
      exp="$(jq -r '.expires // 0' "$claim_file")"
      if (( now < exp )); then
        rmdir "$lock" 2>/dev/null || true
        echo "port-local: already claimed" >&2
        exit 1
      fi
    fi
    expires=$((now + ttl))
    jq -cn --arg o "$owner" --argjson e "$expires" '{owner:$o,expires:$e}' > "$claim_file"
    rmdir "$lock" 2>/dev/null || true
    printf 'claimed=%s owner=%s expires=%s\n' "$id" "$owner" "$expires"
    ;;
  release)
    [[ $# -eq 1 ]] || usage
    id="$1"
    [[ -d "$INST/$id" ]] || { echo "port-local: missing $id" >&2; exit 1; }
    rm -f "$INST/$id/claim.json"
    rm -rf "$INST/$id/claim.lock"
    exit 0
    ;;
  complete)
    [[ $# -eq 2 && -f "$2" ]] || usage
    id="$1"; result="$2"
    [[ -d "$INST/$id" ]] || { echo "port-local: missing $id" >&2; exit 1; }
    bundle="$INST/$id/bundle.json"
    expected="$(jq -r '.stateHash // empty' "$bundle")"
    actual="$(jq -r '.stateHash // empty' "$result")"
    if [[ -z "$expected" || "$expected" != "$actual" ]]; then
      echo "port-local: state hash mismatch; rejecting stale return" >&2
      exit 1
    fi
    cp "$result" "$INST/$id/result.json"
    rm -f "$INST/$id/claim.json"
    printf 'completed=%s\n' "$id"
    ;;
  *)
    usage
    ;;
esac
