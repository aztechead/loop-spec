#!/usr/bin/env bash
# TeammateIdle advisory hook.
#
# Emits a phase-aware advisory message to stderr when a teammate goes idle.
# Always exits 0 (advisory only, never blocks).
#
# Environment:
#   SUPER_SPEC_FEATURE_DIR  path to the feature dir containing feature.json
#                           (e.g. .super-spec/features/my-feature)
#                           If unset, the hook scans .super-spec/features/ for
#                           any feature.json and uses the first one found.
set -euo pipefail

advisory() {
  echo "[teammate-idle advisory] $*" >&2
}

# Locate feature.json
FEATURE_JSON=""
if [[ -n "${SUPER_SPEC_FEATURE_DIR:-}" ]]; then
  FEATURE_JSON="${SUPER_SPEC_FEATURE_DIR}/feature.json"
else
  # Scan for any active feature.json under .super-spec/features/
  if [[ -d ".super-spec/features" ]]; then
    FEATURE_JSON=$(find .super-spec/features -maxdepth 2 -name feature.json | head -1)
  fi
fi

if [[ -z "$FEATURE_JSON" || ! -f "$FEATURE_JSON" ]]; then
  advisory "No feature.json found. No phase context available; teammate is idle with no active feature."
  exit 0
fi

# Parse currentPhase via jq; fall back gracefully on corrupt JSON
CURRENT_PHASE=""
if command -v jq >/dev/null 2>&1; then
  CURRENT_PHASE=$(jq -r '.currentPhase // empty' "$FEATURE_JSON" 2>/dev/null) || true
else
  # Fallback: python3 for zero-dep environments
  CURRENT_PHASE=$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('currentPhase',''))" < "$FEATURE_JSON" 2>/dev/null) || true
fi

if [[ -z "$CURRENT_PHASE" ]]; then
  advisory "Could not read currentPhase from feature.json (missing or corrupt). No phase context; advisory only."
  exit 0
fi

case "$CURRENT_PHASE" in
  discuss)
    advisory "Phase: discuss. Teammate idle during DISCUSS. Await spec-critique gate or lead instruction before claiming new work."
    ;;
  plan)
    advisory "Phase: plan. Teammate idle during PLAN. Await plan-critique/plan-feasibility gate or lead instruction."
    ;;
  execute)
    advisory "Phase: execute. Teammate idle during EXECUTE. Check task list for unclaimed or needs_rework tasks before going idle."
    ;;
  verify)
    advisory "Phase: verify. Teammate idle during VERIFY. Await verifier or code-reviewer completion signal from lead."
    ;;
  completed)
    advisory "Phase: completed. Feature is complete. No further work expected."
    ;;
  *)
    advisory "Phase: $CURRENT_PHASE. Unknown phase; no specific advisory available."
    ;;
esac

exit 0
