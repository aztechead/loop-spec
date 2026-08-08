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
    claim_file="$INST/$id/claim.json"
    lock="$INST/$id/claim.lock"
    # The expiry check AND the write must happen inside the SAME mkdir critical
    # section. Splitting them (check, release the lock, then write) is a TOCTOU:
    # two reclaimers can both observe an expired claim before either writes,
    # and both then "win". A holder never forces another holder's lock away —
    # that would defeat the mutex the same way. Back off and retry instead;
    # the critical section is one jq write, so contention is brief.
    attempt=0
    while true; do
      if mkdir "$lock" 2>/dev/null; then
        now="$(date -u +%s)"
        if [[ -f "$claim_file" ]]; then
          exp="$(jq -r '.expires // 0' "$claim_file")"
          if (( now < exp )); then
            rmdir "$lock"
            echo "port-local: already claimed" >&2
            exit 1
          fi
        fi
        expires=$((now + ttl))
        jq -cn --arg o "$owner" --argjson e "$expires" '{owner:$o,expires:$e}' > "$claim_file"
        rmdir "$lock"
        printf 'claimed=%s owner=%s expires=%s\n' "$id" "$owner" "$expires"
        exit 0
      fi
      attempt=$((attempt + 1))
      (( attempt > 50 )) && { echo "port-local: lock contention timeout for $id" >&2; exit 1; }
      sleep 0.05
    done
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
    [[ $# -eq 3 && -f "$2" ]] || usage
    id="$1"; result="$2"; feature_dir="$3"
    [[ -d "$INST/$id" ]] || { echo "port-local: missing $id" >&2; exit 1; }
    [[ -f "$feature_dir/feature.json" ]] || {
      echo "port-local: missing feature.json at $feature_dir" >&2
      exit 1
    }
    bundle="$INST/$id/bundle.json"
    # Re-derived from the live feature.json at feature-dir, never trusted from
    # result-json-file: comparing two claimant-supplied strings (the old bug)
    # proves nothing, since a claimant who does no work can echo one into the
    # other. expected is the state hash captured once at export time, stored
    # in the bundle before the claimant ever saw it; actual is a fresh hash of
    # whatever feature.json currently lives at feature-dir. This generalizes
    # the SPEC/PLAN hash-lock: it catches a claimant that rewrote its own
    # feature.json to match sloppy work, same as a stale return from drift.
    expected="$(jq -r '.stateHash // empty' "$bundle")"
    actual="$(cksum <"$feature_dir/feature.json" | awk '{print $1"-"$2}')"
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
