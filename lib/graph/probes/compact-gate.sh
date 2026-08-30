#!/usr/bin/env bash
# Route probe: resolve one compact-profile gate from the persisted gate plan.
#
# A compact run is allowed to omit only the work its classifier named. The plan
# is read from feature.json rather than the transient active-run record so a
# resume takes the same route. Missing or malformed compact state fails upward:
# it runs the gate instead of guessing that a safeguard can be skipped.
#
# Usage:
#   compact-gate.sh --feature-dir DIR --gate NAME
#   compact-gate.sh --answers
#
# Exit: 0 with one `gate=<run|skip|unplanned> reason=<text>` line. `unplanned`
# is the non-compact answer: graph routes can leave maintenance and standard on
# their own probes without treating their full ladder as a compact authorization.
# Invalid invocation
# exits 2. See skills/shared/compact-profile.md for the persisted contract.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "usage: compact-gate.sh --feature-dir DIR --gate NAME | --answers" >&2
  exit 2
}

if [[ "${1:-}" == "--answers" ]]; then
  printf 'gate=run\ngate=skip\ngate=unplanned\n'
  exit 0
fi

feature_dir=""
gate_name=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --feature-dir) feature_dir="${2:-}"; shift 2 ;;
    --gate) gate_name="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[[ -n "$feature_dir" && -n "$gate_name" ]] || usage

feature_json="$feature_dir/feature.json"
[[ -f "$feature_json" ]] || {
  printf 'gate=run reason=no feature.json in %s\n' "$feature_dir"
  exit 0
}

profile="$(jq -r '.executionProfile // "standard"' "$feature_json" 2>/dev/null)" || {
  echo 'gate=run reason=feature.json could not be read'
  exit 0
}
[[ "$profile" == "compact" ]] || {
  printf 'gate=unplanned reason=executionProfile=%s is not compact\n' "${profile:-unset}"
  exit 0
}

if ! bash "$SCRIPT_DIR/../../cycle-profile.sh" validate-gate-plan "$feature_json"; then
  echo 'gate=run reason=compact gatePlan is missing or invalid'
  exit 0
fi

jq -e --arg gate "$gate_name" '.gatePlan | has($gate)' "$feature_json" >/dev/null || usage

run="$(jq -r --arg gate "$gate_name" '.gatePlan[$gate].run' "$feature_json")"
reason="$(jq -r --arg gate "$gate_name" '.gatePlan[$gate].reason' "$feature_json")"
if [[ "$run" == "true" ]]; then
  printf 'gate=run reason=compact gatePlan %s: %s\n' "$gate_name" "$reason"
else
  printf 'gate=skip reason=compact gatePlan %s: %s\n' "$gate_name" "$reason"
fi
