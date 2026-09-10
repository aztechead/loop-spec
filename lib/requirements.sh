#!/usr/bin/env bash
# requirements.sh - Read the versioned SPEC inventory as JSON without writes.
# Usage: requirements.sh inventory --spec PATH --feature-dir DIR
# Exit: 0 inventory, 1 invalid artifact/state, 2 bad invocation.
set -euo pipefail
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$LIB_DIR/requirements.py" "$@"
