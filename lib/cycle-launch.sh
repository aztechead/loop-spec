#!/usr/bin/env bash
# Start the outer CLI loop; session adapters retain their Python 3.11 runtime floor.
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$script_dir/../extensions/sessions/cycle_run.py" "$@"
