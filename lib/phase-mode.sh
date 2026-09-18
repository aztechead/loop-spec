#!/usr/bin/env bash
# phase-mode.sh - Which path does this phase take? One line, decided from state.
#
# Why: SPEC, PLAN, and VERIFY each opened with a page of prose describing
# when to interview, self-answer, synthesize, or skip a gate — autonomous, non-
# interactive, maintenance, compact, spec-file, greenfield, ITERATE re-entry — and
# the model re-derived the branch every run. Every one of those conditions is
# readable from feature.json, the environment, and the probes that already exist.
# This is the probe that reads them, so a phase starts on the right path in one call.
#
# Usage:
#   phase-mode.sh spec    --feature-dir DIR
#     path=<ingest|self-answer|synthesize|interview> [oracle=<supervisor|self>]
#     grill=<run|self-answer|skip> critique=<run|skip> reentry=<bool> reason=<text> greenfield=<bool>
#   (oracle= appears on the self-answer path only; lib/supervisor/oracle.sh decides it)
#   phase-mode.sh plan    --feature-dir DIR
#     critique=<run|skip> reentry=<bool> reason=<text>
#   phase-mode.sh verify  --feature-dir DIR
#     placeholder=<run|skip> tamper=<run|skip> validation=<run|skip>
#     acceptance=<run|skip> codeReview=<run|skip> regression=<run|skip> reason=<text>
#
# Fail-safe: an unreadable input selects the fuller path (interview, run, run).
# Exit: 0 with an answer, 2 bad invocation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
eval "$(bash "$SCRIPT_DIR/profile.sh" env 2>/dev/null || true)"
phase="${1:-}"; shift || true
feature_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in --feature-dir) feature_dir="${2:-}"; shift 2 || { echo "phase-mode: $1 needs a value" >&2; exit 2; } ;;
    *) echo "usage: phase-mode.sh <spec|plan|verify> --feature-dir DIR" >&2; exit 2 ;;
  esac
done
case "$phase" in spec|plan|verify) ;;
  *) echo "usage: phase-mode.sh <spec|plan|verify> --feature-dir DIR" >&2; exit 2 ;;
esac
[[ -n "$feature_dir" && -f "$feature_dir/feature.json" ]] \
  || { echo "phase-mode: --feature-dir must hold a feature.json" >&2; exit 2; }
feature_dir="$(cd "$feature_dir" && pwd -P)"
fj="$feature_dir/feature.json"
# Read one consistent typed snapshot; failures retain the existing fail-safe empty
# reads, which select the fuller mode.
feature_snapshot="$(bash "$SCRIPT_DIR/feature-read.sh" "$feature_dir" --all --drop-strays 2>/dev/null)" || feature_snapshot=""
fget() { [[ -n "$feature_snapshot" ]] && jq -r "$1" <<<"$feature_snapshot" 2>/dev/null || echo ""; }

autonomous=false
[[ "$(fget '.autonomous // false')" == "true" || "${LOOP_SPEC_AUTONOMOUS:-}" == "1" ]] && autonomous=true
non_interactive=false
[[ "${LOOP_SPEC_NON_INTERACTIVE:-}" == "1" ]] && non_interactive=true
profile="$(fget '.executionProfile // "standard"')"
style="$(fget '.execStyle // "auto"')"
reentry=false
[[ "$(fget '.iterate.feedback // "null"')" != "null" ]] && reentry=true
slug="$(fget '.slug')"
ws_root="$(fget 'if (.workspace != null and (.workspace.mode // "") != "single") then .workspace.root else "" end')"
if [[ -n "$ws_root" ]]; then root="$ws_root"; else root="$(git -C "$feature_dir" rev-parse --show-toplevel 2>/dev/null || pwd)"; fi
docs="$root/docs/loop-spec/features/$slug"

# oracle -> supervisor | self: who answers on the self-answer path (lib/supervisor/oracle.sh).
# Carried on the mode line so the phase reads it in the one call it already makes;
# the live run that bit us skipped a separate probe call and never asked.
oracle() {
  local line
  line="$(bash "$SCRIPT_DIR/supervisor/oracle.sh" mode --feature-dir "$feature_dir" 2>/dev/null || true)"
  case "$line" in oracle=supervisor*) echo supervisor ;; *) echo self ;; esac
}

# compact_gate NAME -> skip | run (unplanned and errors read as run: fail upward).
compact_gate() {
  local line
  line="$(bash "$SCRIPT_DIR/graph/probes/compact-gate.sh" --feature-dir "$feature_dir" --gate "$1" 2>/dev/null || true)"
  case "$line" in gate=skip*) echo skip ;; *) echo run ;; esac
}
security_signal() {
  local rc=0 out
  out="$(bash "$SCRIPT_DIR/security-signal.sh" first "$@" 2>/dev/null)" || rc=$?
  (( rc == 0 )) && printf '%s' "$out" || printf ''
}

case "$phase" in
  spec)
    gf="$(fget '.greenfield // false')"
    budget_line="$(bash "$SCRIPT_DIR/design-budget.sh" --feature-dir "$feature_dir" --phase spec)"
    if [[ "$autonomous" == true ]]; then grill=self-answer
    elif [[ "$non_interactive" == true ]]; then grill=skip
    elif [[ "$style" == "review-only" ]]; then grill=skip
    else grill=run; fi
    line="$(bash "$SCRIPT_DIR/graph/probes/spec-critique.sh" --feature-dir "$feature_dir" 2>/dev/null || echo "gate=run reason=probe failed")"
    case "$line" in
      gate=skip*) critique=skip; creason="${line#*reason=}" ;;
      gate=compact*) if [[ "$(compact_gate specCritique)" == "skip" ]]; then critique=skip; creason="compact gatePlan"; else critique=run; creason="compact gatePlan runs it"; fi ;;
      *) critique=run; creason="${line#*reason=}" ;;
    esac
    fields="grill=$grill critique=$critique reentry=$reentry"
    if [[ -f "$feature_dir/spec-draft.md" ]]; then
      echo "path=ingest $budget_line $fields reason=spec-draft.md present; critique: $creason greenfield=$gf"
    elif [[ "$autonomous" == true ]]; then
      echo "path=self-answer oracle=$(oracle) $budget_line $fields reason=autonomous; critique: $creason greenfield=$gf"
    elif [[ "$non_interactive" == true ]]; then
      echo "path=synthesize $budget_line $fields reason=LOOP_SPEC_NON_INTERACTIVE=1; critique: $creason greenfield=$gf"
    elif [[ "$profile" == "maintenance" ]]; then
      echo "path=synthesize $budget_line $fields reason=maintenance profile; critique: $creason greenfield=$gf"
    elif [[ "$profile" == "compact" && "$(compact_gate specInterview)" == "skip" ]]; then
      echo "path=synthesize $budget_line $fields reason=compact gatePlan skips specInterview; critique: $creason greenfield=$gf"
    else
      echo "path=interview $budget_line $fields reason=human attached; critique: $creason greenfield=$gf"
    fi
    ;;
  plan)
    signal="$(security_signal "$docs/SPEC.md" "$docs/PLAN.md")"
    tasks="$feature_dir/tasks.json"
    budget_line="$(bash "$SCRIPT_DIR/design-budget.sh" --feature-dir "$feature_dir" --phase plan)"
    if [[ -n "$signal" ]]; then
      echo "critique=run reentry=$reentry $budget_line reason=security signal: $signal"
    elif [[ "$profile" == "compact" && "$(compact_gate planCritique)" == "skip" ]]; then
      echo "critique=skip reentry=$reentry $budget_line reason=compact gatePlan skips planCritique"
    elif [[ "$profile" == "maintenance" ]]; then
      echo "critique=skip reentry=$reentry $budget_line reason=maintenance profile, no security signal"
    elif [[ -f "$tasks" ]]; then
      fp_tasks="$(bash "$SCRIPT_DIR/tuning.sh" get fastPathMaxTasks 2 2>/dev/null || echo 2)"
      fp_files="$(bash "$SCRIPT_DIR/tuning.sh" get fastPathMaxFiles 3 2>/dev/null || echo 3)"
      n="$(jq 'length' "$tasks")"; m="$(jq '[.[].files[]?] | unique | length' "$tasks")"
      if (( n <= fp_tasks && m <= fp_files )); then
        echo "critique=skip reentry=$reentry $budget_line reason=structural fast-path: $n tasks, $m files, no security signal"
      else
        echo "critique=run reentry=$reentry $budget_line reason=$n tasks, $m files exceed the fast-path bounds ($fp_tasks/$fp_files)"
      fi
    else
      echo "critique=run reentry=$reentry $budget_line reason=tasks.json missing; cannot measure scope"
    fi
    ;;
  verify)
    if [[ "$profile" == "compact" ]]; then
      ph="$(compact_gate placeholderScan)"; tm="$(compact_gate tamperScan)"; va="$(compact_gate repositoryValidation)"
      ac="$(compact_gate acceptance)"; cr="$(compact_gate codeReview)"; why="compact gatePlan"
    else
      ph=run; tm=run; va=run; ac=run; cr=run; why="full gate set"
    fi
    rg=skip
    if [[ "${LOOP_SPEC_REGRESSION_SCAN:-0}" == "1" ]] || bash "$SCRIPT_DIR/tuning.sh" has-check suite-regression >/dev/null 2>&1; then rg=run; fi
    echo "placeholder=$ph tamper=$tm validation=$va acceptance=$ac codeReview=$cr regression=$rg reason=$why"
    ;;
esac
