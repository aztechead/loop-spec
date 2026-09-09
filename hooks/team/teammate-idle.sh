#!/usr/bin/env bash
# TeammateIdle hook: tell the lead what to do next when a teammate goes idle.
#
# Emits a phase-aware advisory message to stderr. Always exits 0 (advisory only,
# never blocks).
#
# Environment:
#   LOOP_SPEC_FEATURE_DIR  path to the feature dir containing feature.json
#                           (e.g. .loop-spec/features/my-feature)
#                           If unset, the hook scans .loop-spec/features/ for
#                           any feature.json and uses the first one found.
set -euo pipefail

advisory() {
  echo "[teammate-idle advisory] $*" >&2
}

# Locate feature.json
FEATURE_JSON=""
if [[ -n "${LOOP_SPEC_FEATURE_DIR:-}" ]]; then
  FEATURE_JSON="${LOOP_SPEC_FEATURE_DIR}/feature.json"
else
  # Scan for any active feature.json under .loop-spec/features/
  if [[ -d ".loop-spec/features" ]]; then
    FEATURE_JSON=$(find .loop-spec/features -maxdepth 2 -name feature.json | head -1)
  fi
fi

if [[ -z "$FEATURE_JSON" || ! -f "$FEATURE_JSON" ]]; then
  advisory "No feature.json found. No phase context available; teammate is idle with no active feature."
  exit 0
fi

# The typed reader; empty on a missing or corrupt file, advisory below.
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CURRENT_PHASE=$(bash "$PLUGIN_ROOT/lib/feature-read.sh" "$FEATURE_JSON" -r --filter '.currentPhase // empty' 2>/dev/null) || true

if [[ -z "$CURRENT_PHASE" ]]; then
  advisory "Could not read currentPhase from feature.json (missing or corrupt). No phase context; advisory only."
  exit 0
fi

case "$CURRENT_PHASE" in
  discuss)
    advisory "Phase: discuss. Teammate idle during DISCUSS. Await spec-critique gate or lead instruction before claiming new work."
    ;;
  plan)
    advisory "Phase: plan. Teammate idle during PLAN. Await the plan-critique gate or lead instruction."
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
