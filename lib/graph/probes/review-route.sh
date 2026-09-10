#!/usr/bin/env bash
# A bad-spec review returns to DISCUSS only after the driver recorded recovery.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${1:-}" == --answers ]]; then
  printf 'review=bad-spec\nreview=continue\n'
  exit 0
fi
[[ $# -eq 2 && "$1" == --feature-dir ]] || { echo "usage: review-route.sh --feature-dir DIR | --answers" >&2; exit 2; }
pending="$(bash "$script_dir/../../feature-read.sh" "$2" -r --filter '(.reviewRouting.route == "bad-spec") and (.reviewRouting.pending == true)')"
if [[ "$pending" == true ]]; then
  echo 'review=bad-spec reason=implementation reverted and spec amendment recorded'
else
  echo 'review=continue reason=no pending spec recovery'
fi
