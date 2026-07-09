#!/usr/bin/env bash
# Print "true" if the Claude Code `Workflow` tool is available, else "false".
#
# The Workflow tool ships in Claude Code >= 2.1.154. Availability is detected
# deterministically from the running CC version rather than model self-report.
#
# Usage:
#   workflow-availability.sh [version]
#     [version]  Optional explicit version string (e.g. "2.1.159") for testing.
#                When omitted, the version is read from `claude --version`.
#
# Override:
#   LOOP_SPEC_WORKFLOWS_AVAILABLE=1|0  forces the result (1 -> true, else false),
#   bypassing version detection entirely.
#
# Always exits 0; the answer is on stdout ("true" or "false").
set -euo pipefail

MIN="2.1.154"

if [[ -n "${LOOP_SPEC_WORKFLOWS_AVAILABLE:-}" ]]; then
  [[ "$LOOP_SPEC_WORKFLOWS_AVAILABLE" == "1" ]] && echo "true" || echo "false"
  exit 0
fi

# Harness gate: the Workflow tool is a Claude Code surface. Under pi it never
# exists, regardless of any claude binary found on PATH.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$(bash "$SCRIPT_DIR/harness.sh" detect)" == "pi" ]]; then
  echo "false"
  exit 0
fi

ver="${1:-}"
if [[ -z "$ver" ]]; then
  ver="$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
fi

# true iff ver is present and ver >= MIN (sort -V ascending puts MIN first when ver >= MIN)
if [[ -n "$ver" && "$(printf '%s\n%s\n' "$ver" "$MIN" | sort -V | head -1)" == "$MIN" ]]; then
  echo "true"
else
  echo "false"
fi
