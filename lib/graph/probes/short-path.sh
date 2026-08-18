#!/usr/bin/env bash
# Route probe: may this run take the short path through the cycle graph?
#
# Why: the graph's shape was fixed. Every run walked all seven phases and the full
# critique protocol, so an hour was the FLOOR even for a dependency bump — and the only
# escape was routing to a different protocol entirely (micro/debug), which trades the
# cycle's continuity for the saving. This probe puts the flexibility on the graph itself:
# the same nodes, the same checkpoint ledger, the same terminal result, along a shorter
# declared path.
#
# Two conditions, both already deterministic elsewhere, and BOTH must hold:
#   1. `feature.json.executionProfile == "maintenance"` -- earned by a validated low-risk
#      classification or an explicit operator override (lib/cycle-profile.sh).
#   2. `lib/security-signal.sh` finds nothing in the feature's own artifacts. The signal
#      is re-checked HERE rather than trusted from classification time, because SPEC and
#      DISCUSS write artifacts after the profile was chosen: a change that turns out to
#      touch a security surface must lengthen its own path.
#
# Usage:
#   short-path.sh --feature-dir DIR
#   short-path.sh --answers
#
# Exit: 0 with one `path=<short|full> reason=<text>` line. Anything undeterminable
# answers `path=full` -- the long path is the safe direction, and an unresolved probe
# never satisfies a route (graph-contract.md, route-condition rule).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECURITY_SIGNAL="$SCRIPT_DIR/../../security-signal.sh"

if [[ "${1:-}" == "--answers" ]]; then
  printf 'path=short\npath=full\n'
  exit 0
fi

full() {
  printf 'path=full reason=%s\n' "$1"
  exit 0
}

feature_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --feature-dir) feature_dir="${2:-}"; shift 2 ;;
    *) echo "usage: short-path.sh --feature-dir DIR | --answers" >&2; exit 2 ;;
  esac
done
[[ -n "$feature_dir" ]] || { echo "usage: short-path.sh --feature-dir DIR | --answers" >&2; exit 2; }

feature_json="$feature_dir/feature.json"
[[ -f "$feature_json" ]] || full "no feature.json in $feature_dir"

profile="$(jq -r '.executionProfile // "standard"' "$feature_json" 2>/dev/null)" \
  || full "feature.json could not be read"
[[ "$profile" == "maintenance" ]] || full "executionProfile=${profile:-unset} is not maintenance"

# Only artifacts that exist: a run reaching this probe before DISCUSS has written its
# own has nothing yet to contradict the classification.
artifacts=()
while IFS= read -r artifact; do
  [[ -n "$artifact" && -f "$artifact" ]] && artifacts+=("$artifact")
done < <(jq -r '(.artifacts // {}) | to_entries[] | select(.value | type == "string") | .value' \
  "$feature_json" 2>/dev/null)

if [[ "${#artifacts[@]}" -gt 0 ]]; then
  [[ -x "$SECURITY_SIGNAL" ]] || full "security-signal.sh is not executable"
  signal_rc=0
  signal="$(bash "$SECURITY_SIGNAL" first "${artifacts[@]}" 2>/dev/null)" || signal_rc=$?
  case "$signal_rc" in
    0) full "security signal in the feature's artifacts (${signal})" ;;
    1) ;;
    *) full "security-signal scan could not run (exit ${signal_rc})" ;;
  esac
fi

printf 'path=short reason=maintenance profile, no security signal in %d artifact(s)\n' \
  "${#artifacts[@]}"
