#!/usr/bin/env bash
# Route probe: DELIVER's declared next phase for graph/cycle.graph.json's
# post-delivery routes (deliver -> execute | completed | deliver).
#
# Usage:
#   deliver-next.sh --feature-dir DIR
#   deliver-next.sh --answers
#
# lib/deliver.sh is the side-effecting action script that actually runs
# delivery; it is never itself a route condition (REMEDIATION-CONTRACT.md
# sec 1). This probe only reads the outcome that script already wrote.
#
# Successful and retry observations live in the ignored sidecar
# delivery.json so the exact checked SHA stays clean. Tracked
# feature.json.delivery.nextPhase is written only when failed checks
# route durable remediation back to EXECUTE. Prefer the sidecar: a ready
# delivery leaves tracked nextPhase null (or stale execute from an earlier
# CI failure), and reading only tracked state made no route satisfy, so
# the engine aborted with a failed terminal result.
#
# Tracked state remains the fallback for dry-run fixtures and a clone
# that has the durable execute-remediation pointer but no local sidecar.
#
# Do not delete the sidecar at DELIVER start. lib/deliver.sh reuses it for
# PR-URL hints and bound-SHA retries (bound_target_sha / .prUrl). An abort
# before the final write then leaves the previous observation in place;
# routing that observation is accepted. Clearing identity would break retry.
#
# Exit: 0 with one `nextPhase=<value> reason=<text>` line on stdout when
# resolved; non-zero and silent otherwise.
set -euo pipefail

usage() {
  echo "usage: deliver-next.sh --feature-dir DIR | --answers" >&2
  exit 2
}

if [[ "${1:-}" == "--answers" ]]; then
  printf 'nextPhase=execute\nnextPhase=completed\nnextPhase=deliver\n'
  exit 0
fi

feature_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --feature-dir) feature_dir="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$feature_dir" ]] || usage

feature_json="$feature_dir/feature.json"
[[ -f "$feature_json" ]] || exit 1

source_field="feature.json.delivery.nextPhase"
next_phase=""
if [[ -f "$feature_dir/delivery.json" ]]; then
  next_phase="$(jq -r '.nextPhase // empty' "$feature_dir/delivery.json" 2>/dev/null)" || exit 1
  if [[ -n "$next_phase" ]]; then
    source_field="delivery.json.nextPhase"
  fi
fi
if [[ -z "$next_phase" ]]; then
  next_phase="$(jq -r '.delivery.nextPhase // empty' "$feature_json" 2>/dev/null)" || exit 1
fi

case "$next_phase" in
  execute|completed|deliver)
    echo "nextPhase=${next_phase} reason=${source_field}=${next_phase}"
    ;;
  *)
    exit 1
    ;;
esac
