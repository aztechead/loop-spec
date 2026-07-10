#!/usr/bin/env bash
# tuning.sh - Closed-template parameter tuning for the cycle (ROADMAP-3.0 B2).
#
# The second half of the learning loop: where lib/retro.sh turns repeated
# failure patterns into prose RULES, this script turns them into PARAMETER
# adjustments written to .loop-spec/tuning.json, read by the cycle's phase
# skills at use time (next to runtime.json). Same safety construction as rule
# auto-apply: the adjustment set below is CLOSED (the model cannot author an
# adjustment), triggers are deterministic reads of the lib/status.sh metrics
# contract, deltas are bounded (one step off the default, never stacking),
# every change is audited, and LOOP_SPEC_TUNING=0 kills the whole mechanism
# (get returns defaults, apply no-ops).
#
# The closed template set (id / kind / trigger -> params):
#   widen-fast-path            loosen   consecutiveFirstPass >= 5 (--fp-streak)
#       -> fastPathMaxTasks 2->3, fastPathMaxFiles 3->5 (skills/shared/tier-matrix.md
#          structural fast-path; fewer plan critiques on a repo that keeps
#          converging first-pass). LOOSENING DEMOTES on the first contrary
#          signal: the trigger reads a trailing streak, so one non-first-pass
#          run resets it and the next evaluate/apply removes the adjustment.
#   verify-mandatory-check-<class>  tighten   verifyFailureClassCounts[class] >= 3 (--min-repeats)
#       -> verifyMandatoryChecks += <class> for class in: marker, tamper,
#          suite-regression, acceptance, code-review, live-probe. VERIFY reads
#          these via `tuning.sh has-check` (e.g. suite-regression makes the
#          opt-in regression scan mandatory for this repo).
#   raise-gate-rounds-spec     tighten   gapCounts.spec >= 3
#       -> discussMaxCritiqueRounds 2->3
#   raise-gate-rounds-plan     tighten   gapCounts.plan >= 3
#       -> planMaxCritiqueRounds 2->3
#   raise-gate-rounds-execute  tighten   gapCounts.execute >= 3
#       -> executeMaxRetriesPerTask 2->3
#
# Tightening adjustments persist until the USER removes them (you curate the
# file); loosening adjustments are always one bad run from reverting.
#
# Usage:
#   tuning.sh evaluate [--root <dir>] [--json] [--metrics-json <file>]
#                      [--min-repeats N] [--fp-streak N]
#       Read-only: which templates trigger now, which applied loosenings must
#       demote, what is already applied.
#   tuning.sh apply    [same flags as evaluate]
#       Write .loop-spec/tuning.json (add triggered, demote stale loosenings)
#       and append each change to .loop-spec/tuning-audit.jsonl.
#   tuning.sh get <param> <default> [--root <dir>]
#       Print the effective value of a scalar param (tuning overlay or default).
#   tuning.sh has-check <class> [--root <dir>]
#       Exit 0 iff verifyMandatoryChecks contains <class>.
#   tuning.sh auto <feature_dir> [--root <dir>] [flags]
#       Cycle completion hook — NEVER aborts (observability contract).
#       LOOP_SPEC_TUNING=0 -> off; LOOP_SPEC_TUNING_AUTO_APPLY=0 -> count-only
#       report; =1 -> apply; unset -> apply iff feature.json.autonomous.
#
# Exit codes: 0 ok, 1 has-check miss, 2 bad invocation (auto: always 0).
set -uo pipefail

_die2() { echo "tuning.sh: $*" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cmd="${1:-}"
shift || true

_warn0() { echo "tuning.sh: $*" >&2; exit 0; }
FEATURE_DIR=""
if [[ "$cmd" == "auto" ]]; then
  FEATURE_DIR="${1:-}"
  shift || true
  [[ -n "$FEATURE_DIR" ]] || _warn0 "auto: missing <feature_dir> — skipping"
fi

ROOT=""
JSON=0
METRICS_FILE=""
MIN=3
FP_STREAK=5
GET_PARAM=""; GET_DEFAULT=""; CHECK_CLASS=""
case "$cmd" in
  get)
    GET_PARAM="${1:-}"; GET_DEFAULT="${2:-}"
    [[ -n "$GET_PARAM" && -n "$GET_DEFAULT" ]] || _die2 "usage: tuning.sh get <param> <default> [--root <dir>]"
    shift 2 || true
    ;;
  has-check)
    CHECK_CLASS="${1:-}"
    [[ -n "$CHECK_CLASS" ]] || _die2 "usage: tuning.sh has-check <class> [--root <dir>]"
    shift || true
    ;;
esac
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 || shift ;;
    --json) JSON=1; shift ;;
    --metrics-json) METRICS_FILE="${2:-}"; shift 2 || shift ;;
    --min-repeats) MIN="${2:-3}"; shift 2 || shift ;;
    --fp-streak) FP_STREAK="${2:-5}"; shift 2 || shift ;;
    *) if [[ "$cmd" == "auto" ]]; then _warn0 "auto: unknown flag '$1' — skipping"; else _die2 "unknown flag '$1'"; fi ;;
  esac
done
[[ "$MIN" =~ ^[0-9]+$ ]] || { [[ "$cmd" == "auto" ]] && _warn0 "auto: bad --min-repeats"; _die2 "--min-repeats must be a number"; }
[[ "$FP_STREAK" =~ ^[0-9]+$ ]] || { [[ "$cmd" == "auto" ]] && _warn0 "auto: bad --fp-streak"; _die2 "--fp-streak must be a number"; }

ROOT="${ROOT:-${CLAUDE_PROJECT_DIR:-.}/.loop-spec}"
TUNING_FILE="$ROOT/tuning.json"
AUDIT_FILE="$ROOT/tuning-audit.jsonl"

KILLED=0
[[ "${LOOP_SPEC_TUNING:-1}" == "0" ]] && KILLED=1

_current() {
  local cur='{"schema":1,"adjustments":[]}'
  if [[ -f "$TUNING_FILE" ]]; then
    cur="$(cat "$TUNING_FILE" 2>/dev/null || echo '')"
    jq -e '(.adjustments | type == "array")' >/dev/null 2>&1 <<<"$cur" \
      || cur='{"schema":1,"adjustments":[]}'
  fi
  printf '%s' "$cur"
}

case "$cmd" in
  get)
    # Kill switch: the overlay does not exist; the default is the value.
    if [[ "$KILLED" == "1" || ! -f "$TUNING_FILE" ]]; then
      printf '%s\n' "$GET_DEFAULT"
      exit 0
    fi
    val="$(_current | jq -r --arg p "$GET_PARAM" '
      [.adjustments[].params | select(has($p)) | .[$p]] | last // empty' 2>/dev/null)"
    if [[ -n "$val" && "$val" != "null" ]]; then
      printf '%s\n' "$val"
    else
      printf '%s\n' "$GET_DEFAULT"
    fi
    exit 0
    ;;

  has-check)
    [[ "$KILLED" == "1" || ! -f "$TUNING_FILE" ]] && exit 1
    _current | jq -e --arg c "$CHECK_CLASS" '
      [.adjustments[].params.verifyMandatoryChecks // [] | .[]] | index($c) != null' \
      >/dev/null 2>&1 && exit 0 || exit 1
    ;;

  evaluate|apply|auto)
    ;;

  *)
    _die2 "unknown subcommand '${cmd:-}' (evaluate|apply|get|has-check|auto)"
    ;;
esac

# ── evaluate / apply / auto share the trigger computation ─────────────────────

if [[ "$cmd" == "auto" && "$KILLED" == "1" ]]; then
  exit 0
fi
if [[ "$KILLED" == "1" ]]; then
  echo "tuning: disabled (LOOP_SPEC_TUNING=0)"
  exit 0
fi

# Resolve the auto gate exactly like retro.sh auto: kill switch, explicit
# override, else the feature's autonomous flag.
if [[ "$cmd" == "auto" ]]; then
  gate="${LOOP_SPEC_TUNING_AUTO_APPLY:-}"
  autonomous="false"
  if [[ -f "$FEATURE_DIR/feature.json" ]]; then
    autonomous="$(jq -r '.autonomous // false' "$FEATURE_DIR/feature.json" 2>/dev/null || echo false)"
  fi
  if [[ "$gate" == "1" || ( "$gate" != "0" && "$autonomous" == "true" ) ]]; then
    cmd="auto-apply"
  else
    cmd="auto-report"
  fi
fi

if [[ -n "$METRICS_FILE" ]]; then
  if [[ ! -f "$METRICS_FILE" ]]; then
    [[ "$cmd" == auto-* ]] && _warn0 "auto: metrics file not found — skipping"
    _die2 "metrics file not found: $METRICS_FILE"
  fi
  metrics="$(jq -c . "$METRICS_FILE" 2>/dev/null)" || {
    [[ "$cmd" == auto-* ]] && _warn0 "auto: metrics file invalid — skipping"
    _die2 "metrics file is not valid JSON: $METRICS_FILE"
  }
else
  metrics="$(bash "$SCRIPT_DIR/status.sh" --root "$ROOT" metrics 2>/dev/null)" || metrics=""
  if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$metrics"; then
    [[ "$cmd" == auto-* ]] && _warn0 "auto: could not read metrics — skipping"
    _die2 "could not read metrics from status.sh"
  fi
fi

CURRENT="$(_current)"

# THE CLOSED SET. Everything below is data + fixed templates; adding a
# template is a code change to this block, pinned by
# tests/lib/tuning.test.sh's closed-set test.
VERDICT="$(jq -cn \
  --argjson m "$metrics" --argjson cur "$CURRENT" \
  --argjson min "$MIN" --argjson fp "$FP_STREAK" '
  def classes: ["marker", "tamper", "suite-regression", "acceptance", "code-review", "live-probe"];

  ([
    (if ($m.consecutiveFirstPass // 0) >= $fp then
      {id: "widen-fast-path", kind: "loosen",
       trigger: ("consecutiveFirstPass \($m.consecutiveFirstPass) >= \($fp)"),
       params: {fastPathMaxTasks: 3, fastPathMaxFiles: 5}}
     else empty end),
    (classes[] as $c
     | (($m.verifyFailureClassCounts // {})[$c] // 0) as $n
     | if $n >= $min then
         {id: ("verify-mandatory-check-" + $c), kind: "tighten",
          trigger: ("verifyFailureClassCounts.\($c) \($n) >= \($min)"),
          params: {verifyMandatoryChecks: [$c]}}
       else empty end),
    (if (($m.gapCounts // {}).spec // 0) >= $min then
      {id: "raise-gate-rounds-spec", kind: "tighten",
       trigger: ("gapCounts.spec \($m.gapCounts.spec) >= \($min)"),
       params: {discussMaxCritiqueRounds: 3}}
     else empty end),
    (if (($m.gapCounts // {}).plan // 0) >= $min then
      {id: "raise-gate-rounds-plan", kind: "tighten",
       trigger: ("gapCounts.plan \($m.gapCounts.plan) >= \($min)"),
       params: {planMaxCritiqueRounds: 3}}
     else empty end),
    (if (($m.gapCounts // {}).execute // 0) >= $min then
      {id: "raise-gate-rounds-execute", kind: "tighten",
       trigger: ("gapCounts.execute \($m.gapCounts.execute) >= \($min)"),
       params: {executeMaxRetriesPerTask: 3}}
     else empty end)
  ]) as $triggered

  | ($triggered | map(.id)) as $tids
  | ($cur.adjustments | map(.id)) as $applied
  # Loosening demotes the moment its trigger stops holding; tightening stays
  # (the user curates removals).
  | ($cur.adjustments | map(select(.kind == "loosen" and ((.id as $i | $tids | index($i)) | not)) | .id)) as $demote
  | ($triggered | map(select(.id as $i | ($applied | index($i)) | not))) as $new

  | {triggered: $triggered, new: $new, demote: $demote, applied: $applied}')" \
  || { [[ "$cmd" == auto-* ]] && _warn0 "auto: trigger computation failed — skipping"; _die2 "trigger computation failed"; }

if [[ "$cmd" == "evaluate" ]]; then
  if [[ "$JSON" == "1" ]]; then
    jq . <<<"$VERDICT"
  else
    jq -r '
      "tuning evaluate:",
      "  applied:   \(.applied | if length == 0 then "none" else join(", ") end)",
      "  triggered: \(.triggered | if length == 0 then "none" else (map(.id) | join(", ")) end)",
      "  to add:    \(.new | if length == 0 then "none" else (map(.id) | join(", ")) end)",
      "  to demote: \(.demote | if length == 0 then "none" else join(", ") end)"
    ' <<<"$VERDICT"
  fi
  exit 0
fi

if [[ "$cmd" == "auto-report" ]]; then
  n="$(jq '(.new | length) + (.demote | length)' <<<"$VERDICT" 2>/dev/null || echo 0)"
  if [[ "${n:-0}" -gt 0 ]]; then
    echo "Tuning: ${n} pending parameter adjustment(s) — review with 'tuning.sh evaluate', apply with 'tuning.sh apply'"
  fi
  exit 0
fi

# ── apply (and auto-apply) ────────────────────────────────────────────────────
n_new="$(jq '.new | length' <<<"$VERDICT")"
n_demote="$(jq '.demote | length' <<<"$VERDICT")"
if [[ "$n_new" == "0" && "$n_demote" == "0" ]]; then
  echo "tuning apply: nothing to change"
  exit 0
fi

mkdir -p "$ROOT" 2>/dev/null || { [[ "$cmd" == "auto-apply" ]] && _warn0 "auto: cannot create $ROOT"; _die2 "cannot create $ROOT"; }

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
NEXT="$(jq -cn --argjson cur "$CURRENT" --argjson v "$VERDICT" --arg ts "$ts" '
  {schema: 1, updatedAt: $ts,
   adjustments: (($cur.adjustments | map(select(.id as $i | ($v.demote | index($i)) | not)))
                 + ($v.new | map(. + {appliedAt: $ts})))}')"

printf '%s\n' "$NEXT" > "$TUNING_FILE.tmp" && mv "$TUNING_FILE.tmp" "$TUNING_FILE" \
  || { [[ "$cmd" == "auto-apply" ]] && _warn0 "auto: cannot write $TUNING_FILE"; _die2 "cannot write $TUNING_FILE"; }

# Audit trail: one line per change, DECISIONS-style.
{
  jq -c --arg ts "$ts" '.new[] | {ts: $ts, action: "add", id: .id, kind: .kind, evidence: .trigger}' <<<"$VERDICT"
  jq -c --arg ts "$ts" '.demote[] | {ts: $ts, action: "demote", id: ., kind: "loosen", evidence: "trigger no longer holds (contrary signal)"}' <<<"$VERDICT"
} >> "$AUDIT_FILE" 2>/dev/null || echo "tuning: WARN could not append audit trail to $AUDIT_FILE" >&2

[[ "$cmd" == "auto-apply" ]] && echo "Tuning auto-apply (autonomous run; kill switch LOOP_SPEC_TUNING=0):"
jq -r '
  (.new[] | "  add: \(.id) (\(.trigger))"),
  (.demote[] | "  demote: \(.) (loosening reverts on first contrary signal)")
' <<<"$VERDICT"
echo "tuning apply: wrote $TUNING_FILE"
exit 0
