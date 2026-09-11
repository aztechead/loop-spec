#!/usr/bin/env bash
# requirements-migrate.sh - Read-only legacy-to-v1 migration preview and status.
# Usage: requirements-migrate.sh preview|status --feature-dir DIR
#        requirements-migrate.sh apply|resume|rollback --feature-dir DIR ...  (not yet)
# Exit: 0 preview/status JSON on stdout; 1 refusal with a diagnostic; 2 bad
# invocation, or apply/resume/rollback (not implemented in this revision --
# task-011).
set -euo pipefail
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$LIB_DIR/requirements_migrate.py" "$@"
