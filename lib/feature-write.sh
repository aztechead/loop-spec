#!/usr/bin/env bash
# Serialize and atomically publish feature.json updates with a previous-state backup.
# Usage: feature-write.sh <feature_dir> <json-object>
#        feature-write.sh set|append <feature_dir> <dot_path> <json-value>
#        feature-write.sh ack-remediation <feature_dir> <snapshot/generation/receipt object>
# Exit: 0 written and persisted; 1 invalid input; 2 I/O or store failure.
# Sourced participants keep a private current token and explicitly adopt child receipts.
# These helpers run before callers have confirmed `gh` (or other optional tooling) is on
# PATH (lib/checkpoint-pr.sh's precondition checks), so they touch only git, jq, python3,
# bash, dirname, mktemp, and rm -- tests/lib/checkpoint-pr.test.sh's NOGH_BIN pins that set.

loop_spec_publication_read() {
  # Token files are small JSON; bound the read so a corrupted or hostile file cannot
  # balloon memory here, mirroring feature_write.read_bounded's own limit.
  python3 -c '
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from feature_write import read_bounded
try:
    sys.stdout.buffer.write(read_bounded(Path(sys.argv[2]), 1024 * 1024))
except (OSError, ValueError) as exc:
    print("loop_spec_publication_read: {}".format(exc), file=sys.stderr)
    sys.exit(1)
' "$(dirname "$LOOP_SPEC_PUBLICATION_WRITER")" "$1"
}

loop_spec_publication_begin() {
  LOOP_SPEC_PUBLICATION_WRITER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature_write.py"
  if [[ -n "${LOOP_SPEC_PUBLICATION_TOKEN:-}" && "${LOOP_SPEC_PUBLICATION_TOKEN_OUTPUT:-}" == "$LOOP_SPEC_PUBLICATION_TOKEN" ]]; then
    echo "loop_spec_publication_begin: LOOP_SPEC_PUBLICATION_TOKEN_OUTPUT must not be the input token ($LOOP_SPEC_PUBLICATION_TOKEN is immutable)" >&2
    return 1
  fi
  LOOP_SPEC_OPERATION_TOKEN="$(mktemp "${TMPDIR:-/tmp}/loop-spec-publication.XXXXXX")"
  local args=() operation=ingress
  [[ "${2:-}" != read-only ]] || operation=ingress-read
  [[ -z "${LOOP_SPEC_PUBLICATION_TOKEN:-}" ]] || args=(--token "$LOOP_SPEC_PUBLICATION_TOKEN")
  python3 "$LOOP_SPEC_PUBLICATION_WRITER" "$operation" "$1" ${args[@]+"${args[@]}"} > "$LOOP_SPEC_OPERATION_TOKEN"
}

loop_spec_feature_write() {
  local refreshed pending
  pending="$(loop_spec_publication_read "$LOOP_SPEC_OPERATION_TOKEN")" || return $?
  if [[ "$pending" == null ]]; then
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
  local received result=0 refreshed
  received="$(mktemp "${TMPDIR:-/tmp}/loop-spec-publication-child.XXXXXX")"
  LOOP_SPEC_PUBLICATION_TOKEN="$LOOP_SPEC_OPERATION_TOKEN" \
    LOOP_SPEC_PUBLICATION_TOKEN_OUTPUT="$received" "$@" || result=$?
  if [[ -s "$received" ]]; then
    refreshed="$(loop_spec_publication_read "$received")" || { rm -f "$received"; return 1; }
    printf '%s\n' "$refreshed" > "$LOOP_SPEC_OPERATION_TOKEN"
    [[ -z "${LOOP_SPEC_PUBLICATION_TOKEN_OUTPUT:-}" ]] || printf '%s\n' "$refreshed" > "$LOOP_SPEC_PUBLICATION_TOKEN_OUTPUT"
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
