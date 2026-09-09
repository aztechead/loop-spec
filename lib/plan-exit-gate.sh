#!/usr/bin/env bash
# plan-exit-gate.sh - PLAN's exit checks on tasks.json and PLAN.md, one call.
#
# Why: these checks lived as a case branch inside lib/phase-exit.sh, which meant the
# exit gate of a phase was code in a shared script rather than data on the phase's
# graph node. graph/cycle.graph.json's `plan` node names this script in its
# `egress.gates`; phase-exit.sh runs it like any other gate (orchestrator-port-plan.md,
# WP2). The checks themselves are unchanged: tasks.json must exist and mirror PLAN.md's
# task ids, every task needs a parseable verify command that checks rather than
# installs, at least one acceptance criterion, an acyclic DAG, and (in workspace mode)
# a known repo.
#
# Usage: plan-exit-gate.sh <feature-dir>
# Output: `FLAG [<gate>] <finding>` lines; exit 1 when any, 0 when clean, 2 bad call.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/exit-gate-prelude.sh" "${1:-}"

tasks="$feature_dir/tasks.json"
extract="bash lib/plan-tasks.sh extract $docs/PLAN.md > $tasks"
[[ -f "$tasks" ]] || flag "[tasks] $tasks missing: derive it from PLAN.md first ($extract)"
run_gate artifact-lint lib artifact-lint plan "$docs/PLAN.md"
run_gate artifact-lint lib artifact-lint patterns "$docs/PATTERNS.md"
if [[ -f "$tasks" ]]; then
  run_gate artifact-lint lib artifact-lint tasks "$tasks"
  # PLAN.md is the source of tasks.json; a sidecar copied from a chat message can
  # be empty or stale while the plan is whole, and EXECUTE reads only the sidecar.
  plan_ids="$(lib plan-adherence "$docs/PLAN.md" | jq -r '.plan_task_ids | sort | join(" ")')"
  sidecar_ids="$(jq -r 'if type == "array" then [.[] | .id // empty] | sort | join(" ") else "" end' "$tasks" 2>/dev/null || true)"
  [[ "$plan_ids" == "$sidecar_ids" ]] \
    || flag "[tasks] PLAN.md task ids (${plan_ids:-none}) differ from $tasks (${sidecar_ids:-none}): derive it from PLAN.md ($extract)"
  run_gate acceptance-lint lib acceptance-lint "$tasks"
  run_gate doc-deps lib doc-deps gate --tasks "$tasks" --artifact "$docs/PLAN.md"
  # Structural feasibility: a task with no runnable check or no criterion cannot be
  # verified, and a cyclic DAG never dispatches.
  while IFS=$'\t' read -r id cmd ncrit; do
    [[ -n "$cmd" ]] || { flag "[feasibility] $id has no verifyCommand"; continue; }
    bash -n -c "$cmd" 2>/dev/null || flag "[feasibility] $id verifyCommand does not parse: $cmd"
    # A verify command checks; an install belongs to commands.prepare. A plan that
    # bootstrapped the runtime inside every verify failed integration on a venv that
    # already existed and paid a planner round to add --clear.
    if grep -qE '(^|[ ;&|(])(pip3?|uv|npm|yarn|pnpm|cargo|gem|bundle|poetry|apt(-get)?|brew) +(install|add|sync|ci|python install)|uv +venv|python3? +-m +venv' <<<"$cmd"; then
      flag "[feasibility] $id verifyCommand installs or creates an environment; move that step to commands.prepare and keep the command a check: $cmd"
    fi
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
(( flags == 0 )) || exit 1
exit 0
