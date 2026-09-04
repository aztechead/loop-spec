#!/usr/bin/env bash
# Serialize and atomically publish feature.json updates with a previous-state backup.
# Usage: feature-write.sh <feature_dir> <json-object>
#        feature-write.sh set|append <feature_dir> <dot_path> <json-value>
# Exit: 0 written and persisted; 1 invalid input; 2 I/O or store failure.
set -euo pipefail

exec python3 "$(dirname "${BASH_SOURCE[0]}")/feature_write.py" "$@"
