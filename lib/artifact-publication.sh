#!/usr/bin/env bash
# artifact-publication.sh - Capture ingress tokens and publish staged artifact transactions.
# Usage: artifact-publication.sh capture|publish|recover --feature-dir DIR [--token PATH --manifest PATH]
# Exit codes: 0 done; 1 invalid or stale input; 2 I/O failure.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/artifact_publication.py" "$@"
