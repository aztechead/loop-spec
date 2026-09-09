#!/usr/bin/env bash
# execute-exit-gate.sh - EXECUTE's exit: every PLAN task published, then the at-end
# commit strategy.
#
# Why: the check and the squash lived as a case branch inside lib/phase-exit.sh; the
# `execute` node of graph/cycle.graph.json now names them in its `exit` block and
# phase-exit.sh runs them like any other gate (orchestrator-port-plan.md, WP2).
#
# Usage:
#   execute-exit-gate.sh check  <feature-dir>   FLAG lines; exit 1 when any task is
#                                              unpublished or the greenfield backfill
#                                              left commands.test empty
#   execute-exit-gate.sh finish <feature-dir>   after a clean check: squash the task
#                                              commits into one when the workflow's
#                                              commit strategy is at-end (single-repo)
# Exit 2 bad invocation.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cmd="${1:-}"; feature_dir="${2:-}"
[[ -n "$feature_dir" && -f "$feature_dir/feature.json" ]] || { echo "usage: execute-exit-gate.sh check|finish <feature-dir>" >&2; exit 2; }
feature_dir="$(cd "$feature_dir" && pwd -P)"
fj="$feature_dir/feature.json"
fget() { jq -r "$1" "$fj"; }
lib() { bash "$SCRIPT_DIR/$1.sh" "${@:2}"; }
slug="$(fget '.slug')"
ws_root="$(fget 'if (.workspace != null and (.workspace.mode // "") != "single") then .workspace.root else "" end')"
if [[ -n "$ws_root" ]]; then root="$ws_root"; else root="$(git -C "$feature_dir" rev-parse --show-toplevel)"; fi
cd "$root"

case "$cmd" in
  check)
    flags=0
    tasks="$(fget '.artifacts.tasks // ""')"
    if [[ -n "$tasks" && -f "$tasks" ]]; then
      remaining="$(lib task-progress remaining "$tasks" | paste -sd, -)"
      [[ -z "$remaining" ]] || { echo "FLAG [plan-adherence] tasks not published: $remaining (dispatch them again, or for a task whose commit is already on the feature branch run: bash lib/cycle-driver.sh task integrate --feature-dir $feature_dir --task <id>, or bash lib/task-progress.sh mark-done $(fget '.artifacts.tasks // "tasks.json"') <id>)"; flags=$((flags + 1)); }
    else
      echo "FLAG [plan-adherence] artifacts.tasks sidecar missing; cannot prove every PLAN task landed"; flags=$((flags + 1))
    fi
    rc=0; lib greenfield-bootstrap backfill-check "$feature_dir" >/dev/null 2>&1 || rc=$?
    (( rc == 3 )) && { echo "FLAG [greenfield] commands.test is empty after the scaffold task; re-run detection"; flags=$((flags + 1)); }
    (( flags == 0 )) || exit 1
    ;;
  finish)
    if [[ -z "$ws_root" && "$(lib workflow-config commit-strategy)" == "at-end" ]]; then
      base="$(fget '.baseBranch')"
      git reset -q --soft "$(git merge-base "$base" HEAD)" && git commit -q -m "feat: $slug"
    fi
    ;;
  *) echo "usage: execute-exit-gate.sh check|finish <feature-dir>" >&2; exit 2 ;;
esac
exit 0
