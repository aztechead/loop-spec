#!/usr/bin/env bash
# Preserve feature documents outside the branch with recoverable publication.
# Usage: artifact-sink.sh store|recover <feature_dir> <repo_root>
set -euo pipefail
exec python3 "$(dirname "${BASH_SOURCE[0]}")/artifact_sink.py" "$@"
