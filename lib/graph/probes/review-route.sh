#!/usr/bin/env bash
# Recorded bad-spec recovery takes priority; queued findings return to EXECUTE.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${1:-}" == --answers ]]; then
  printf 'review=bad-spec\nreview=remediate\nreview=continue\n'
  exit 0
fi
[[ $# -eq 2 && "$1" == --feature-dir ]] || { echo "usage: review-route.sh --feature-dir DIR | --answers" >&2; exit 2; }
pending="$(bash "$script_dir/../../feature-read.sh" "$2" -r --filter '(.reviewRouting.route == "bad-spec") and (.reviewRouting.pending == true)')"
if [[ "$pending" == true ]]; then
  echo 'review=bad-spec reason=implementation reverted and spec amendment recorded'
else
  state="$(bash "$script_dir/../../feature-read.sh" "$2" --all --drop-strays)"
  queue="$(jq -c 'if has("pendingRemediationTasks") then .pendingRemediationTasks else [] end' <<<"$state")"
  if ! jq -e 'type == "array"' <<<"$queue" >/dev/null 2>&1; then
    echo 'review-route: pendingRemediationTasks must be an array; repair the queue before continuing' >&2
    exit 1
  fi
  if [[ "$(jq 'length' <<<"$queue")" != 0 ]]; then
    echo 'review=remediate reason=pending VERIFY work must reach EXECUTE'
    exit 0
  fi
  echo 'review=continue reason=no pending spec recovery'
fi
