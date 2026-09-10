#!/usr/bin/env bash
# execute-exit-gate.sh - EXECUTE's exit: every PLAN task published, then the at-end
# commit strategy.
#
# Why: the check and the squash lived as a case branch inside lib/phase-exit.sh; the
# `execute` node of graph/cycle.graph.json now names them in its `egress` block and
# phase-exit.sh runs them like any other gate (the port plan, WP2).
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
cmd="${1:-}"
gate_usage="check|finish <feature-dir>"
. "$SCRIPT_DIR/exit-gate-prelude.sh" "${2:-}"

case "$cmd" in
  check)
    if pending="$(fget '.pendingRemediationTasks')"; then
      if ! jq -e 'type == "array"' <<<"$pending" >/dev/null 2>&1; then
        flag "[plan-adherence] pendingRemediationTasks must be an array; repair the queue before leaving EXECUTE"
      elif [[ "$(jq 'length' <<<"$pending")" != "0" ]]; then
        flag "[plan-adherence] pendingRemediationTasks still contains work; run execute-prepare and dispatch every finding"
      fi
    else
      flag "[plan-adherence] cannot read pendingRemediationTasks; repair feature state before leaving EXECUTE"
    fi
    if ! tasks="$(fget '.artifacts.tasks // ""')"; then
      flag "[plan-adherence] cannot read artifacts.tasks; repair feature state before leaving EXECUTE"
    elif [[ -n "$tasks" && -f "$tasks" ]]; then
      if lint_out="$(lib artifact-lint tasks "$tasks" 2>&1)"; then
        if remaining="$(lib task-progress remaining "$tasks" 2>&1)"; then
          remaining="$(printf '%s' "$remaining" | paste -sd, -)"
          [[ -z "$remaining" ]] || flag "[plan-adherence] tasks not published: $remaining (dispatch them again, or for a task whose commit is already on the feature branch run: bash lib/cycle-driver.sh task integrate --feature-dir $feature_dir --task <id>)"
        else
          flag "[plan-adherence] cannot read task progress: $remaining"
        fi
      else
        flag "[plan-adherence] invalid artifacts.tasks sidecar: $lint_out"
      fi
    else
      flag "[plan-adherence] artifacts.tasks sidecar missing; cannot prove every PLAN task landed"
    fi
    rc=0; lib greenfield-bootstrap backfill-check "$feature_dir" >/dev/null 2>&1 || rc=$?
    (( rc == 3 )) && flag "[greenfield] commands.test is empty after the scaffold task; re-run detection"
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
