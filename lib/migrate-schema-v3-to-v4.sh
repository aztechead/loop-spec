#!/usr/bin/env bash
# Migrate a feature.json from schemaVersion 3 to schemaVersion 4.
#
# Usage:
#   bash lib/migrate-schema-v3-to-v4.sh <feature_dir>
#
# What it does:
#   - Reads <feature_dir>/feature.json
#   - If schemaVersion >= 4: prints "already v4, no-op" and exits 0 (idempotent)
#   - If schemaVersion != 3: prints error and exits 1
#   - Otherwise applies the v4 additions:
#       schemaVersion: 4
#       currentPhase: preserved as-is (does NOT auto-insert "spec")
#       retryBudget.perPhase.spec: same as discuss budget (or 3 if not set)
#       retryBudget.perPhaseUsed.spec: 0
#       artifacts.specInterview: null
#   - Delegates the atomic write to lib/feature-write.sh
#
# Exit codes:
#   0 success (or already v4)
#   1 bad invocation / missing file / invalid JSON / unsupported schemaVersion
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FEATURE_WRITE="$SCRIPT_DIR/feature-write.sh"

if [[ $# -ne 1 ]]; then
  echo "usage: migrate-schema-v3-to-v4.sh <feature_dir>" >&2
  exit 1
fi

feature_dir="$1"
feature_json_path="$feature_dir/feature.json"

if [[ ! -f "$feature_json_path" ]]; then
  echo "migrate-schema-v3-to-v4: feature.json not found in $feature_dir" >&2
  exit 1
fi

if ! jq -e . "$feature_json_path" >/dev/null 2>&1; then
  echo "migrate-schema-v3-to-v4: invalid JSON in $feature_json_path" >&2
  exit 1
fi

schema_version=$(jq -r '.schemaVersion' "$feature_json_path")

if [[ "$schema_version" -ge 4 ]] 2>/dev/null; then
  echo "migrate-schema-v3-to-v4: already v4, no-op"
  exit 0
fi

if [[ "$schema_version" != "3" ]]; then
  echo "migrate-schema-v3-to-v4: unsupported schemaVersion '$schema_version', aborting" >&2
  exit 1
fi

new_json=$(jq '
  # Determine spec budget: same as discuss, or 3 if discuss not set
  (.retryBudget.perPhase.discuss // 3) as $spec_budget
  # perPhaseUsed may be absent in older v3 subschemas; treat as empty object
  | (.retryBudget.perPhaseUsed // {}) as $per_phase_used
  | .schemaVersion = 4
  | .retryBudget.perPhase.spec = $spec_budget
  | .retryBudget.perPhaseUsed = ($per_phase_used | .spec = 0)
  | .artifacts.specInterview = null
' "$feature_json_path")

bash "$FEATURE_WRITE" "$feature_dir" "$new_json"
