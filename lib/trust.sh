#!/usr/bin/env bash
# trust.sh - Graduated-trust track record, computed and read-only (ROADMAP-3.0 D1).
#
# Answers "how much unattended authority has THIS repo earned?" from evidence,
# never from opinion: the inputs are the committed metrics contract
# (lib/status.sh metrics — run digests under docs/loop-spec/telemetry/runs/),
# not self-reports. In 2.16 this script only REPORTS the level; nothing reads
# it to authorize anything yet (the authorize verb ships with D2/D3).
#
# Levels (defaults; thresholds configurable in .loop-spec/trust.conf):
#   L0  default forever — PR-and-wait (today's behavior)
#   L1  >= L1_STREAK (5) consecutive converged cycles AND postMergeFixRate == 0
#   L2  L1 + >= L2_STREAK (10) streak + live-verify rung enabled and passing
#   L3  L2 + >= L3_STREAK (20) streak + clean post-merge watch window
#
# FAIL-CLOSED is the whole design: any signal that is missing, null, or
# unparseable resolves to the LOWER level. postMergeFixRate and the
# live-verify / watch signals do not exist until pillars C1/C2 ship — so with
# 2.16-era telemetry every repo computes to L0, by construction, not by
# accident. Promotion is slow, demotion is instant (one bad signal drops the
# level; the streak input resets because the metrics contract recomputes the
# trailing streak from the digests).
#
# Usage:
#   trust.sh level [--json] [--root <dir>] [--conf <file>] [--metrics-json <file>]
#       Print the current level AND the evidence lines that produced it.
#       --metrics-json bypasses lib/status.sh metrics (fixture seam for tests);
#       --root is forwarded to status.sh.
#
# Config (.loop-spec/trust.conf, KEY=VALUE lines, parsed never sourced):
#   L1_STREAK=5  L2_STREAK=10  L3_STREAK=20
#
# Exit codes: 0 level computed, 2 bad invocation / unreadable metrics.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_die2() { echo "trust.sh: $*" >&2; exit 2; }

conf_get() {
  local file="$1" key="$2" default="$3" val
  if [[ -f "$file" ]]; then
    val="$(grep -m1 -E "^${key}=[0-9]+$" "$file" 2>/dev/null | cut -d= -f2 || true)"
    [[ -n "$val" ]] && { printf '%s' "$val"; return; }
  fi
  printf '%s' "$default"
}

cmd="${1:-}"
[[ "$cmd" == "level" ]] || _die2 "unknown subcommand '${cmd:-}' (usage: trust.sh level [--json] [--root <dir>] [--conf <file>] [--metrics-json <file>])"
shift

JSON=0
ROOT=""
CONF="${CLAUDE_PROJECT_DIR:-.}/.loop-spec/trust.conf"
METRICS_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON=1; shift ;;
    --root) ROOT="${2:-}"; shift 2 || shift ;;
    --conf) CONF="${2:-}"; shift 2 || shift ;;
    --metrics-json) METRICS_FILE="${2:-}"; shift 2 || shift ;;
    *) _die2 "unknown flag '$1'" ;;
  esac
done

if [[ -n "$METRICS_FILE" ]]; then
  [[ -f "$METRICS_FILE" ]] || _die2 "metrics file not found: $METRICS_FILE"
  metrics="$(jq -c . "$METRICS_FILE" 2>/dev/null)" || _die2 "metrics file is not valid JSON: $METRICS_FILE"
else
  root_args=()
  [[ -n "$ROOT" ]] && root_args=(--root "$ROOT")
  metrics="$(bash "$SCRIPT_DIR/status.sh" ${root_args[@]+"${root_args[@]}"} metrics 2>/dev/null)" \
    || _die2 "could not read metrics from status.sh"
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$metrics" || _die2 "status.sh metrics did not return an object"
fi

l1_streak="$(conf_get "$CONF" L1_STREAK 5)"
l2_streak="$(conf_get "$CONF" L2_STREAK 10)"
l3_streak="$(conf_get "$CONF" L3_STREAK 20)"

# All level arithmetic in one jq program so the verdict and its evidence are
# derived from the same reads — no bash/jq drift.
verdict="$(jq -c \
  --argjson l1 "$l1_streak" --argjson l2 "$l2_streak" --argjson l3 "$l3_streak" '
  (.consecutiveConverged // 0) as $streak
  | .postMergeFixRate as $pmfr
  | .verifyFailureRate as $vfr
  # Live-verify and watch signals have no producer yet (C1/C2). Reading keys
  # that may not exist keeps this forward-compatible: when the metrics
  # contract grows them, this script starts honoring them unchanged.
  | (.liveVerifyPassing // null) as $live
  | (.watchWindowClean // null) as $watch

  | ($pmfr == 0) as $pmfr_clean
  | ($streak >= $l1 and $pmfr_clean) as $l1_ok
  | ($l1_ok and $streak >= $l2 and $live == true) as $l2_ok
  | ($l2_ok and $streak >= $l3 and $watch == true) as $l3_ok

  | {
      schema: 1,
      level: (if $l3_ok then "L3" elif $l2_ok then "L2" elif $l1_ok then "L1" else "L0" end),
      inputs: {
        consecutiveConverged: $streak,
        postMergeFixRate: $pmfr,
        verifyFailureRate: $vfr,
        liveVerifyPassing: $live,
        watchWindowClean: $watch
      },
      evidence: [
        "consecutiveConverged: \($streak) (L1 needs >= \($l1), L2 >= \($l2), L3 >= \($l3))",
        "postMergeFixRate: \(if $pmfr == null then "unknown — no post-merge watch data; fail-closed" else ($pmfr | tostring) end) (L1 needs 0)",
        "liveVerify: \(if $live == null then "unavailable — live-verify rung not reporting; fail-closed" else ($live | tostring) end) (L2 requires passing)",
        "watchWindow: \(if $watch == null then "unavailable — post-merge watch not reporting; fail-closed" else ($watch | tostring) end) (L3 requires clean)"
      ]
    }' <<<"$metrics")" || _die2 "level computation failed"

if [[ "$JSON" == "1" ]]; then
  jq . <<<"$verdict"
  exit 0
fi

jq -r '"trust level: \(.level)", "evidence:", (.evidence[] | "  \(.)")' <<<"$verdict"
