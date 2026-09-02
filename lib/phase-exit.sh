#!/usr/bin/env bash
# phase-exit.sh - One command closes a phase: gates, artifact pointers, commit, tag.
#
# Why: every phase ended with the same scattered bookkeeping written as prose — run
# three lints, set four feature.json keys, git add two files, tag a checkpoint, clear
# the team — and a phase that got one of them wrong stalled the next phase on a
# repair it should never have had to do. This script is that ending. A phase skill
# runs it once; a FLAG means the phase fixes its own artifact and runs it again.
#
# Usage:
#   phase-exit.sh <spec|discuss|plan|execute|verify|iterate> --feature-dir DIR [--terminal]
#
# Gates per phase (all deterministic, all already bundled):
#   spec      artifact-lint spec
#   discuss   artifact-lint spec, grounding-lint SPEC.md, codebase-map join
#   plan      artifact-lint plan/patterns/tasks, acceptance-lint, verifyCommand
#             syntax, criteria per task, DAG acyclic, workspace repo field,
#             decision-coverage, criteria-coverage, grounding-lint PLAN.md
#   execute   every PLAN task id published (tasks.json status=done), greenfield
#             command backfill, at-end commit strategy
#   verify    artifact-lint verification, verification-grounding-lint
#   iterate   ITERATION.md present (--terminal also closes the phase)
#
# Output: `FLAG <what>` per finding, then one answer line:
#   phase-exit: ok (<phase>)                 exit 0
#   phase-exit: <n> flag(s) (<phase>)        exit 1
#   phase-exit: NEED map-codebase <domains>  exit 3  (discuss: mappers not landed)
# Exit 2 is a bad invocation.
#
# On ok: records artifacts.* and completedPhases, clears currentTeamName and
# currentTeammates, commits the phase artifacts (single-repo only; a workspace root
# is orchestration state, never a delivery target), and tags the checkpoint.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

phase="${1:-}"; shift || true
feature_dir="" terminal=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --feature-dir) feature_dir="${2:-}"; shift 2 ;;
    --terminal) terminal=1; shift ;;
    *) echo "usage: phase-exit.sh <spec|discuss|plan|execute|verify|iterate> --feature-dir DIR [--terminal]" >&2; exit 2 ;;
  esac
done
case "$phase" in spec|discuss|plan|execute|verify|iterate) ;;
  *) echo "usage: phase-exit.sh <spec|discuss|plan|execute|verify|iterate> --feature-dir DIR [--terminal]" >&2; exit 2 ;;
esac
[[ -n "$feature_dir" && -f "$feature_dir/feature.json" ]] \
  || { echo "phase-exit: --feature-dir must hold a feature.json" >&2; exit 2; }
feature_dir="$(cd "$feature_dir" && pwd -P)"
fj="$feature_dir/feature.json"

lib() { bash "$SCRIPT_DIR/$1.sh" "${@:2}"; }
fget() { jq -r "$1" "$fj"; }
fset() { lib feature-write set "$feature_dir" "$1" "$2" >/dev/null; }

slug="$(fget '.slug')"
ws_root="$(fget '.workspace.root // ""')"
if [[ -n "$ws_root" ]]; then root="$ws_root"; else root="$(git -C "$feature_dir" rev-parse --show-toplevel)"; fi
cd "$root"
docs="docs/loop-spec/features/$slug"
flags=0
flag() { echo "FLAG $*"; flags=$((flags + 1)); }
# run_gate LABEL CMD...: relay the gate's own FLAG/output lines, count a failure once.
run_gate() {
  local label="$1"; shift
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  if (( rc != 0 )); then
    printf '%s\n' "$out" | grep -E '^(FLAG|FLOOR)|^[^ ]' | sed "s/^/FLAG [$label] /" | grep -v 'phase-exit' || true
    flags=$((flags + 1))
  fi
}

# commit_paths MESSAGE PATH...: single-repo commit of the paths that exist; nothing
# else is swept in. Workspace mode leaves the docs as local orchestration evidence.
commit_paths() {
  local msg="$1"; shift
  [[ -z "$ws_root" ]] || { echo "phase-exit: workspace root is not a delivery target; artifacts stay local" >&2; return 0; }
  # An ignored path (a transcript under .loop-spec/features/) is skipped, not forced.
  local existing=() p
  for p in "$@"; do
    [[ -e "$p" ]] || continue
    git add -- "$p" 2>/dev/null || true
    git ls-files --error-unmatch -- "$p" >/dev/null 2>&1 && existing+=("$p")
  done
  [[ ${#existing[@]} -gt 0 ]] || return 0
  git diff --cached --quiet -- "${existing[@]}" 2>/dev/null || git commit -q -m "$msg" -- "${existing[@]}"
}

tag_checkpoint() {
  if [[ -n "$ws_root" ]]; then
    local r; while IFS= read -r r; do
      [[ -n "$r" ]] && lib checkpoint -C "$ws_root/$r" tag "$1" >/dev/null 2>&1 || true
    done < <(fget '.workspace.repos[]?.path')
  else
    lib checkpoint tag "$1" >/dev/null 2>&1 || true
  fi
}

close_phase() {
  lib feature-write append "$feature_dir" completedPhases "\"$phase\"" >/dev/null
  fset currentTeamName null
  fset currentTeammates '[]'
}

case "$phase" in
  spec)
    run_gate artifact-lint lib artifact-lint spec "$docs/SPEC.md"
    if (( flags == 0 )); then
      fset artifacts.spec "\"$docs/SPEC.md\""
      [[ -f "$feature_dir/spec-interview-transcript.md" ]] \
        && fset artifacts.specInterview "\"$feature_dir/spec-interview-transcript.md\""
      commit_paths "spec: $slug" "$docs/SPEC.md" "$docs/EVIDENCE.md" "$feature_dir/spec-interview-transcript.md"
      close_phase
    fi
    ;;
  discuss)
    run_gate artifact-lint lib artifact-lint spec "$docs/SPEC.md"
    run_gate grounding-lint lib grounding-lint "$docs/SPEC.md"
    if (( flags == 0 )) && [[ "$(fget '.bootstrapPendingDomains | length')" != "0" ]]; then
      missing=""
      for d in TECH ARCH QUALITY CONCERNS DOMAIN; do
        [[ -f "docs/loop-spec/codebase/$d.md" ]] || missing="$missing $(tr 'A-Z' 'a-z' <<<"$d")"
      done
      if [[ -n "$missing" ]]; then
        echo "phase-exit: NEED map-codebase${missing}"; exit 3
      fi
      for d in $(fget '.bootstrapPendingDomains[]'); do fset "artifacts.codebaseSource.$d" '"mapper"'; done
      fset bootstrapPendingDomains '[]'
      commit_paths "docs: bootstrap codebase map" docs/loop-spec/codebase
    fi
    if (( flags == 0 )); then
      fset artifacts.spec "\"$docs/SPEC.md\""
      commit_paths "spec: $slug" "$docs/SPEC.md" "$docs/EVIDENCE.md"
      tag_checkpoint post-discuss
      close_phase
    fi
    ;;
  plan)
    tasks="$feature_dir/tasks.json"
    [[ -f "$tasks" ]] || flag "[tasks] $tasks missing: write the planner's tasks[] JSON there first"
    run_gate artifact-lint lib artifact-lint plan "$docs/PLAN.md"
    run_gate artifact-lint lib artifact-lint patterns "$docs/PATTERNS.md"
    if [[ -f "$tasks" ]]; then
      run_gate artifact-lint lib artifact-lint tasks "$tasks"
      run_gate acceptance-lint lib acceptance-lint "$tasks"
      # Structural feasibility: a task with no runnable check or no criterion cannot be
      # verified, and a cyclic DAG never dispatches.
      while IFS=$'\t' read -r id cmd ncrit; do
        [[ -n "$cmd" ]] || { flag "[feasibility] $id has no verifyCommand"; continue; }
        bash -n -c "$cmd" 2>/dev/null || flag "[feasibility] $id verifyCommand does not parse: $cmd"
        [[ "$ncrit" != "0" ]] || flag "[feasibility] $id has no acceptance criteria"
      done < <(jq -r '.[] | [.id, (.verifyCommand // ""), ((.acceptanceCriteria // []) | length)] | @tsv' "$tasks")
      rc=0; lib dag-width < "$tasks" >/dev/null 2>&1 || rc=$?
      (( rc == 3 )) && flag "[feasibility] task DAG has a dependency cycle"
      if [[ -n "$ws_root" ]]; then
        names="$(fget '[.workspace.repos[].name] | join(" ")')"
        while IFS=$'\t' read -r id repo; do
          [[ " $names " == *" $repo "* ]] || flag "[workspace] $id repo '${repo:-missing}' is not a workspace repo ($names)"
        done < <(jq -r '.[] | [.id, (.repo // "")] | @tsv' "$tasks")
      fi
    fi
    spec="$(fget '.artifacts.spec // ""')"; [[ -n "$spec" ]] || spec="$docs/SPEC.md"
    run_gate decision-coverage lib decision-coverage "$spec" "$docs/PLAN.md"
    run_gate criteria-coverage lib criteria-coverage "$spec" "$docs/PLAN.md"
    run_gate grounding-lint lib grounding-lint "$docs/PLAN.md"
    if (( flags == 0 )); then
      fset artifacts.plan "\"$docs/PLAN.md\""
      fset artifacts.patterns "\"$docs/PATTERNS.md\""
      fset artifacts.tasks "\"$tasks\""
      [[ "$(fget '.artifacts.patternsSource // "null"')" != "null" ]] || fset artifacts.patternsSource '"pattern-mapper"'
      commit_paths "plan: $slug" "$docs/PLAN.md" "$docs/PATTERNS.md" "$docs/EVIDENCE.md"
      tag_checkpoint post-plan
      close_phase
    fi
    ;;
  execute)
    tasks="$(fget '.artifacts.tasks // ""')"
    if [[ -n "$tasks" && -f "$tasks" ]]; then
      remaining="$(lib task-progress remaining "$tasks" | paste -sd, -)"
      [[ -z "$remaining" ]] || flag "[plan-adherence] tasks not published: $remaining (re-queue them or mark-done what already landed)"
    else
      flag "[plan-adherence] artifacts.tasks sidecar missing; cannot prove every PLAN task landed"
    fi
    rc=0; lib greenfield-bootstrap backfill-check "$feature_dir" >/dev/null 2>&1 || rc=$?
    (( rc == 3 )) && flag "[greenfield] commands.test is empty after the scaffold task; re-run detection"
    if (( flags == 0 )); then
      if [[ -z "$ws_root" && "$(lib workflow-config commit-strategy)" == "at-end" ]]; then
        base="$(fget '.baseBranch')"
        git reset -q --soft "$(git merge-base "$base" HEAD)" && git commit -q -m "feat: $slug"
      fi
      tag_checkpoint post-execute
      fset mergeQueue '[]'
      fset pendingRemediationTasks '[]'
      close_phase
    fi
    ;;
  verify)
    spec="$(fget '.artifacts.spec // ""')"; [[ -n "$spec" ]] || spec="$docs/SPEC.md"
    run_gate artifact-lint lib artifact-lint verification "$docs/VERIFICATION.md"
    run_gate verification-grounding lib verification-grounding-lint "$docs/VERIFICATION.md" --repo "$root" --spec "$spec"
    if (( flags == 0 )); then
      fset artifacts.verification "\"$docs/VERIFICATION.md\""
      [[ -f "$docs/REVIEW-ORDER.md" ]] && fset artifacts.reviewOrder "\"$docs/REVIEW-ORDER.md\""
      commit_paths "verify: $slug" "$docs/VERIFICATION.md" "$docs/REVIEW-ORDER.md" "$docs/EVIDENCE.md"
      tag_checkpoint post-verify
      close_phase
    fi
    ;;
  iterate)
    [[ -f "$docs/ITERATION.md" ]] || flag "[iteration] $docs/ITERATION.md missing"
    if (( flags == 0 )); then
      fset artifacts.iteration "\"$docs/ITERATION.md\""
      commit_paths "iterate: $slug iteration $(fget '.iterate.used')" "$docs/ITERATION.md" .loop-spec/BACKLOG.md
      (( terminal == 1 )) && close_phase
    fi
    ;;
esac

if (( flags == 0 )); then
  echo "phase-exit: ok ($phase)"
else
  echo "phase-exit: $flags flag(s) ($phase)"; exit 1
fi
