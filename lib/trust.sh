#!/usr/bin/env bash
# trust.sh - Graduated-trust track record and governor (ROADMAP-3.0 D1-D3).
#
# Answers "how much unattended authority has THIS repo earned?" from evidence,
# never from opinion: the inputs are the committed metrics contract
# (lib/status.sh metrics — run digests under docs/loop-spec/telemetry/runs/),
# not self-reports. `level` reports; `authorize` (D2/D3, 2.18) is the verb the
# ACTING scripts call and obey — authority checks live in the scripts that act,
# never in skill prose, so a skill cannot talk itself past this file.
#
# Levels (defaults; thresholds configurable in .loop-spec/trust.conf):
#   L0  default forever — PR-and-wait (today's behavior)
#   L1  >= L1_STREAK (5) consecutive converged cycles AND postMergeFixRate == 0
#   L2  L1 + >= L2_STREAK (10) streak + live-verify rung enabled and passing
#   L3  L2 + >= L3_STREAK (20) streak + clean post-merge watch window
#
# FAIL-CLOSED is the whole design: any signal that is missing, null, or
# unparseable resolves to the LOWER level, and an action the map does not
# unlock resolves to DENIED. Promotion is slow, demotion is instant (one bad
# signal drops the level; the streak input resets because the metrics contract
# recomputes the trailing streak from the digests).
#
# Usage:
#   trust.sh level [--json] [--root <dir>] [--conf <file>] [--metrics-json <file>]
#       Print the current level AND the evidence lines that produced it.
#       --metrics-json bypasses lib/status.sh metrics (fixture seam for tests);
#       --root is forwarded to status.sh.
#   trust.sh authorize --action <sentinel-batch|auto-merge> [--completed <n>]
#                      [--json] [--root <dir>] [--conf <file>] [--metrics-json <file>]
#       Deterministic authority check; the exit code IS the verdict (0 =
#       authorized, 1 = denied). Level -> authority map (2.18: L1 only):
#         sentinel-batch  L0: max batch 1 (PR-and-wait, one item per
#                         invocation regardless of env). L1+: the user's
#                         LOOP_SPEC_MAX_FEATURES is honored, capped at
#                         BATCH_L1 (conf, default 5). Authorized while
#                         --completed (default 0) < the effective max.
#         auto-merge      ALWAYS denied in this release: unlocks at L2/L3 with
#                         the deterministic diff classifier (ships in 3.0).
#                         Until that exists, any doubt resolves to no-merge.
#
# Config (.loop-spec/trust.conf, KEY=VALUE lines, parsed never sourced):
#   L1_STREAK=5  L2_STREAK=10  L3_STREAK=20  BATCH_L1=5
#
# Exit codes: level: 0 computed, 2 bad invocation / unreadable metrics.
#             authorize: 0 authorized, 1 denied, 2 bad invocation.
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
case "$cmd" in level|authorize) ;; *) _die2 "unknown subcommand '${cmd:-}' (usage: trust.sh level|authorize ...)" ;; esac
shift

JSON=0
ROOT=""
CONF="${CLAUDE_PROJECT_DIR:-.}/.loop-spec/trust.conf"
METRICS_FILE=""
ACTION=""
COMPLETED=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON=1; shift ;;
    --root) ROOT="${2:-}"; shift 2 || shift ;;
    --conf) CONF="${2:-}"; shift 2 || shift ;;
    --metrics-json) METRICS_FILE="${2:-}"; shift 2 || shift ;;
    --action) ACTION="${2:-}"; shift 2 || shift ;;
    --completed) COMPLETED="${2:-}"; shift 2 || shift ;;
    *) _die2 "unknown flag '$1'" ;;
  esac
done

if [[ "$cmd" == "authorize" ]]; then
  case "$ACTION" in sentinel-batch|auto-merge) ;; *) _die2 "authorize needs --action sentinel-batch|auto-merge (got '${ACTION:-}')" ;; esac
  [[ "$COMPLETED" =~ ^[0-9]+$ ]] || _die2 "--completed must be a non-negative integer (got '$COMPLETED')"
fi

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
  # watchWindowClean is produced by lib/watch.sh verdicts (C2, 2.18);
  # liveVerifyPassing has no metrics producer until the L2 wave (3.0).
  # Reading keys that may not exist keeps this forward-compatible: when the
  # metrics contract grows one, this script starts honoring it unchanged.
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

if [[ "$cmd" == "level" ]]; then
  if [[ "$JSON" == "1" ]]; then
    jq . <<<"$verdict"
    exit 0
  fi
  jq -r '"trust level: \(.level)", "evidence:", (.evidence[] | "  \(.)")' <<<"$verdict"
  exit 0
fi

# ── authorize: the level -> authority map (fail-closed) ──────────────────────
level="$(jq -r '.level' <<<"$verdict")"

if [[ "$ACTION" == "auto-merge" ]]; then
  # Hard-denied regardless of level: the L2/L3 authority classes and the
  # deterministic diff classifier ship in 3.0. Until the classifier exists,
  # nothing can prove a diff low-risk, so the answer is no-merge — by
  # construction, not by threshold.
  answer="$(jq -cn --arg level "$level" '{
    schema: 1, action: "auto-merge", level: $level, authorized: false,
    reason: "auto-merge requires L2+ and the deterministic diff classifier (ships in 3.0); fail-closed"
  }')"
  if [[ "$JSON" == "1" ]]; then jq . <<<"$answer"; else
    jq -r '"authorize \(.action): DENIED (level \(.level)) — \(.reason)"' <<<"$answer"
  fi
  exit 1
fi

# sentinel-batch: L0 processes exactly ONE item per invocation no matter what
# the env asks for; L1+ honors the user's LOOP_SPEC_MAX_FEATURES up to the
# BATCH_L1 cap. Both bounds must agree — trust unlocks, it never volunteers.
batch_l1="$(conf_get "$CONF" BATCH_L1 5)"
max_features="${LOOP_SPEC_MAX_FEATURES:-1}"
[[ "$max_features" =~ ^[0-9]+$ ]] || max_features=1
if [[ "$level" == "L0" ]]; then
  max_batch=1
else
  max_batch="$max_features"
  if (( max_batch > batch_l1 )); then max_batch="$batch_l1"; fi
fi

if (( COMPLETED < max_batch )); then authorized=true; ec=0; else authorized=false; ec=1; fi
answer="$(jq -cn --arg level "$level" --argjson authorized "$authorized" \
  --argjson maxBatch "$max_batch" --argjson completed "$COMPLETED" \
  --argjson maxFeatures "$max_features" --argjson batchL1 "$batch_l1" '{
  schema: 1, action: "sentinel-batch", level: $level, authorized: $authorized,
  maxBatch: $maxBatch, completed: $completed,
  reason: (if $authorized then "completed \($completed) < maxBatch \($maxBatch)"
           else "batch bound reached: completed \($completed) >= maxBatch \($maxBatch)" end),
  evidence: [
    "level: \($level) (L0 caps sentinel batches at 1; L1+ honors LOOP_SPEC_MAX_FEATURES up to BATCH_L1)",
    "LOOP_SPEC_MAX_FEATURES: \($maxFeatures), BATCH_L1: \($batchL1) -> maxBatch \($maxBatch)"
  ]
}')"
if [[ "$JSON" == "1" ]]; then jq . <<<"$answer"; else
  jq -r '"authorize \(.action): \(if .authorized then "AUTHORIZED" else "DENIED" end) (level \(.level), maxBatch \(.maxBatch), completed \(.completed))"' <<<"$answer"
fi
exit "$ec"
