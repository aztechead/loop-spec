#!/usr/bin/env bash
# cycle-driver.sh - The cycle's mechanical loop: launcher for lib/graph/driver.py.
#
# The loop itself is Python, in the same process as the graph engine
# (orchestrator-port-plan.md, WP4); this file owns only the path. Every subcommand,
# answer line, and exit code is documented in lib/graph/driver.py's header, and
# `cycle-driver.sh` with no arguments prints it.
#
# Usage: cycle-driver.sh <start|init|resume|begin|phase-begin|next|finish|escalate|deliver|task|spec|oneshot|verification|critique|verify|iterate> ...
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/graph/driver.py" "$@"
