#!/usr/bin/env bash
# plugin-version.sh - Print the loop-spec version producing the current run.
#
# Every machine-readable artifact loop-spec emits (the terminal cycle result, the
# run digest) carries this so a consumer can date it. Without it, a report from an
# unattended harness cannot be checked against the version that fixed the behavior
# it describes — findings arrive already stale and nobody can tell.
#
# Resolution order:
#   1. LOOP_SPEC_VERSION   explicit override (vendored installs, tests)
#   2. .claude-plugin/plugin.json `.version` relative to this script
#   3. "unknown"
#
# Never fails: an unknown version is a usable datum, an aborted terminal result is
# not. Always exits 0 with the answer on stdout.
set -uo pipefail

if [[ -n "${LOOP_SPEC_VERSION:-}" ]]; then
  echo "${LOOP_SPEC_VERSION}"
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
manifest="$SCRIPT_DIR/../.claude-plugin/plugin.json"

version=""
if [[ -r "$manifest" ]]; then
  version="$(jq -r '.version // empty' "$manifest" 2>/dev/null || true)"
fi

[[ -n "$version" ]] || version="unknown"
echo "$version"
