#!/usr/bin/env bash
# phase-mode.sh - Which path does this phase take? One line, decided from state.
#
# Why: SPEC, DISCUSS, PLAN, and VERIFY each opened with a page of prose describing
# when to interview, self-answer, synthesize, or skip a gate — autonomous, non-
# interactive, maintenance, compact, spec-file, greenfield, ITERATE re-entry — and
# the model re-derived the branch every run. Every one of those conditions is
# readable from feature.json, the environment, and the probes that already exist.
# This is the probe that reads them, so a phase starts on the right path in one call.
#
# Usage:
#   phase-mode.sh spec    --feature-dir DIR
#     path=<ingest|self-answer|synthesize|interview> reason=<text> greenfield=<bool>
#   phase-mode.sh discuss --feature-dir DIR
#     grill=<run|self-answer|skip> critique=<run|skip> reentry=<bool> reason=<text>
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
phase="${1:-}"; shift || true
feature_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in --feature-dir) feature_dir="${2:-}"; shift 2 ;;
    *) echo "usage: phase-mode.sh <spec|discuss|plan|verify> --feature-dir DIR" >&2; exit 2 ;;
  esac
done
case "$phase" in spec|discuss|plan|verify) ;;
  *) echo "usage: phase-mode.sh <spec|discuss|plan|verify> --feature-dir DIR" >&2; exit 2 ;;
esac
[[ -n "$feature_dir" && -f "$feature_dir/feature.json" ]] \
  || { echo "phase-mode: --feature-dir must hold a feature.json" >&2; exit 2; }
feature_dir="$(cd "$feature_dir" && pwd -P)"
fj="$feature_dir/feature.json"
fget() { jq -r "$1" "$fj" 2>/dev/null || echo ""; }

autonomous=false
[[ "$(fget '.autonomous // false')" == "true" || "${LOOP_SPEC_AUTONOMOUS:-}" == "1" ]] && autonomous=true
non_interactive=false
[[ "${LOOP_SPEC_NON_INTERACTIVE:-}" == "1" ]] && non_interactive=true
profile="$(fget '.executionProfile // "standard"')"
style="$(fget '.execStyle // "auto"')"
reentry=false
[[ "$(fget '.iterate.feedback // "null"')" != "null" ]] && reentry=true
slug="$(fget '.slug')"
ws_root="$(fget '.workspace.root // ""')"
if [[ -n "$ws_root" ]]; then root="$ws_root"; else root="$(git -C "$feature_dir" rev-parse --show-toplevel 2>/dev/null || pwd)"; fi
docs="$root/docs/loop-spec/features/$slug"

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
    if [[ -f "$feature_dir/spec-draft.md" ]]; then
      echo "path=ingest reason=spec-draft.md present greenfield=$gf"
    elif [[ "$autonomous" == true ]]; then
      echo "path=self-answer reason=autonomous greenfield=$gf"
    elif [[ "$non_interactive" == true ]]; then
      echo "path=synthesize reason=LOOP_SPEC_NON_INTERACTIVE=1 greenfield=$gf"
    elif [[ "$profile" == "maintenance" ]]; then
      echo "path=synthesize reason=maintenance profile greenfield=$gf"
    elif [[ "$profile" == "compact" && "$(compact_gate specInterview)" == "skip" ]]; then
      echo "path=synthesize reason=compact gatePlan skips specInterview greenfield=$gf"
    else
      echo "path=interview reason=human attached greenfield=$gf"
    fi
    ;;
  discuss)
    if [[ "$autonomous" == true ]]; then grill=self-answer; why=autonomous
    elif [[ "$non_interactive" == true ]]; then grill=skip; why=LOOP_SPEC_NON_INTERACTIVE=1
    elif [[ "$style" == "review-only" ]]; then grill=skip; why="review-only style"
    else grill=run; why="human attached"; fi
    line="$(bash "$SCRIPT_DIR/graph/probes/discuss-critique.sh" --feature-dir "$feature_dir" 2>/dev/null || echo "gate=run reason=probe failed")"
    case "$line" in
      gate=skip*) critique=skip; creason="${line#*reason=}" ;;
      gate=compact*) if [[ "$(compact_gate specCritique)" == "skip" ]]; then critique=skip; creason="compact gatePlan"; else critique=run; creason="compact gatePlan runs it"; fi ;;
      *) critique=run; creason="${line#*reason=}" ;;
    esac
    echo "grill=$grill critique=$critique reentry=$reentry reason=$why; critique: $creason"
    ;;
  plan)
    signal="$(security_signal "$docs/SPEC.md" "$docs/PLAN.md")"
    tasks="$feature_dir/tasks.json"
    if [[ -n "$signal" ]]; then
      echo "critique=run reentry=$reentry reason=security signal: $signal"
    elif [[ "$profile" == "compact" && "$(compact_gate planCritique)" == "skip" ]]; then
      echo "critique=skip reentry=$reentry reason=compact gatePlan skips planCritique"
    elif [[ "$profile" == "maintenance" ]]; then
      echo "critique=skip reentry=$reentry reason=maintenance profile, no security signal"
    elif [[ -f "$tasks" ]]; then
      fp_tasks="$(bash "$SCRIPT_DIR/tuning.sh" get fastPathMaxTasks 2 2>/dev/null || echo 2)"
      fp_files="$(bash "$SCRIPT_DIR/tuning.sh" get fastPathMaxFiles 3 2>/dev/null || echo 3)"
      n="$(jq 'length' "$tasks")"; m="$(jq '[.[].files[]?] | unique | length' "$tasks")"
      if (( n <= fp_tasks && m <= fp_files )); then
        echo "critique=skip reentry=$reentry reason=structural fast-path: $n tasks, $m files, no security signal"
      else
        echo "critique=run reentry=$reentry reason=$n tasks, $m files exceed the fast-path bounds ($fp_tasks/$fp_files)"
      fi
    else
      echo "critique=run reentry=$reentry reason=tasks.json missing; cannot measure scope"
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
