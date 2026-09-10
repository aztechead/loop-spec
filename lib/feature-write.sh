#!/usr/bin/env bash
# Serialize and atomically publish feature.json updates with a previous-state backup.
# Usage: feature-write.sh <feature_dir> <json-object>
#        feature-write.sh set|append <feature_dir> <dot_path> <json-value>
#        feature-write.sh ack-remediation <feature_dir> <snapshot/generation/receipt object>
# Exit: 0 written and persisted; 1 invalid input; 2 I/O or store failure.
# Sourced participants keep a private current token and explicitly adopt child receipts.
loop_spec_publication_begin() {
  LOOP_SPEC_PUBLICATION_WRITER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature_write.py"
  LOOP_SPEC_OPERATION_TOKEN="$(mktemp "${TMPDIR:-/tmp}/loop-spec-publication.XXXXXX")"
  local args=() operation=ingress
  [[ "${2:-}" != read-only ]] || operation=ingress-read
  [[ -z "${LOOP_SPEC_PUBLICATION_TOKEN:-}" ]] || args=(--token "$LOOP_SPEC_PUBLICATION_TOKEN")
  python3 "$LOOP_SPEC_PUBLICATION_WRITER" "$operation" "$1" ${args[@]+"${args[@]}"} > "$LOOP_SPEC_OPERATION_TOKEN"
}

loop_spec_feature_write() {
  local refreshed
  if [[ "$(cat "$LOOP_SPEC_OPERATION_TOKEN")" == null ]]; then
    python3 "$LOOP_SPEC_PUBLICATION_WRITER" "$@"
    return $?
  fi
  refreshed="$(python3 "$LOOP_SPEC_PUBLICATION_WRITER" "$@" --token "$LOOP_SPEC_OPERATION_TOKEN")" || return $?
  printf '%s\n' "$refreshed" > "$LOOP_SPEC_OPERATION_TOKEN"
  if [[ -n "${LOOP_SPEC_PUBLICATION_TOKEN_OUTPUT:-}" ]]; then
    printf '%s\n' "$refreshed" > "$LOOP_SPEC_PUBLICATION_TOKEN_OUTPUT"
  fi
}

loop_spec_publication_run() {
  local received result=0
  received="$(mktemp "${TMPDIR:-/tmp}/loop-spec-publication-child.XXXXXX")"
  LOOP_SPEC_PUBLICATION_TOKEN="$LOOP_SPEC_OPERATION_TOKEN" \
    LOOP_SPEC_PUBLICATION_TOKEN_OUTPUT="$received" "$@" || result=$?
  if [[ -s "$received" ]]; then
    cp "$received" "$LOOP_SPEC_OPERATION_TOKEN"
    [[ -z "${LOOP_SPEC_PUBLICATION_TOKEN_OUTPUT:-}" ]] || cp "$received" "$LOOP_SPEC_PUBLICATION_TOKEN_OUTPUT"
  fi
  rm -f "$received"
  return "$result"
}

loop_spec_publication_lib() {
  local directory="$1" name="$2"
  shift 2
  if [[ "$name" == feature-write ]]; then
    loop_spec_feature_write "$@"
  else
    loop_spec_publication_run bash "$directory/$name.sh" "$@"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  exec python3 "$(dirname "${BASH_SOURCE[0]}")/feature_write.py" "$@"
fi
