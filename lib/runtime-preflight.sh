#!/usr/bin/env bash
# runtime-preflight.sh - Base runtime dependency checks that do not require jq.
set -euo pipefail

case "${1:-}" in
  check-jq)
    if ! command -v jq >/dev/null 2>&1; then
      echo "loop-spec: jq >= 1.5 is required; install jq and retry (Alpine: apk add jq)." >&2
      exit 1
    fi
    version="$(jq --version 2>&1 || true)"
    if [[ ! "$version" =~ jq-([0-9]+)\.([0-9]+) ]]; then
      echo "loop-spec: jq >= 1.5 is required; found unrecognized version '$version'." >&2
      exit 1
    fi
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    if (( major < 1 || (major == 1 && minor < 5) )); then
      echo "loop-spec: jq >= 1.5 is required; found $version. Upgrade jq and retry." >&2
      exit 1
    fi
    ;;
  *)
    echo "usage: runtime-preflight.sh check-jq" >&2
    exit 2
    ;;
esac
