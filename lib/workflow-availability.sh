#!/usr/bin/env bash
# Print `false`: Workflow fan-out cannot enforce the finite resource cap.
#
# Usage:
#   workflow-availability.sh [ignored-version]
#     The optional argument remains accepted by offline callers; resource policy
#     selects the bounded path before version capability can affect dispatch.
#
# Policy: all finite caps use one-shot waves, whose width the lead can enforce.
# Workflow owns internal fan-out and therefore cannot be enabled by a positive
# capability override while the global policy is bounded.
#
# Exits 0 with the answer on stdout, or propagates an invalid explicit harness
# as a usage error.
set -euo pipefail

# Workflow internals own their fan-out, so one-shot waves enforce the cap.
subagent_cap="$(bash "$(dirname "${BASH_SOURCE[0]}")/resource-bounds.sh" get subagents)" || exit $?

# Harness gate: the Workflow tool is a Claude Code surface. Under opencode and
# ADK it never exists, regardless of any claude binary found on PATH.
#
# Keep the harness gate for diagnostics: a positive override must not claim a
# tool the harness does not ship.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
harness="$(bash "$SCRIPT_DIR/harness.sh" detect)" || exit $?
if [[ "$harness" != "claude" ]]; then
  echo "false"
  exit 0
fi

echo "false"
exit 0
