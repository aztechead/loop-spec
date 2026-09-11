#!/usr/bin/env bash
# plan-exit-gate.sh - PLAN's exit checks on tasks.json and PLAN.md, one call.
#
# Why: these checks lived as a case branch inside lib/phase-exit.sh, which meant the
# exit gate of a phase was code in a shared script rather than data on the phase's
# graph node. graph/cycle.graph.json's `plan` node names this script in its
# `egress.gates`; phase-exit.sh runs it like any other gate (the port plan,
# WP2). The checks themselves are unchanged: tasks.json must exist and mirror PLAN.md's
# task ids, every task needs a parseable verify command that checks rather than
# installs, at least one acceptance criterion, an acyclic DAG, and (in workspace mode)
# a known repo. Once ids match, every other DISPATCH field tasks.json carries is also
# compared against a fresh PLAN.md extraction (task-005): id, subject, files, blockedBy,
# verifyCommand, acceptanceCriteria, requirements, obligations, executionInputs -- the
# fields EXECUTE actually dispatches on. readFirst, interfaces, repo, batchGroup,
# modelTier and specPath are scheduling/presentation hints checked by acceptance-lint
# and doc-deps above, not by this parity check, so a difference there is not flagged
# here. Under a v1 requirementsContract, criteria-coverage.sh additionally validates
# every task's requirements/obligations against the live SPEC inventory -- the new
# relation check the legacy `## Spec coverage` gate (graph/cycle.graph.json) cannot do,
# since it never sees the feature's contract or tasks.json.
#
# Usage: plan-exit-gate.sh <feature-dir>
# Output: `FLAG [<gate>] <finding>` lines; exit 1 when any, 0 when clean, 2 bad call.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/exit-gate-prelude.sh" "${1:-}"

tasks="$feature_dir/tasks.json"
extract="bash lib/plan-tasks.sh extract $docs/PLAN.md > $tasks"
[[ -f "$tasks" ]] || flag "[tasks] $tasks missing: derive it from PLAN.md first ($extract)"
run_gate artifact-lint lib artifact-lint plan "$docs/PLAN.md" --feature-dir "$feature_dir"
run_gate artifact-lint lib artifact-lint patterns "$docs/PATTERNS.md"
if [[ -f "$tasks" ]]; then
  run_gate artifact-lint lib artifact-lint tasks "$tasks" --feature-dir "$feature_dir"
  # PLAN.md is the source of tasks.json; a sidecar copied from a chat message can
  # be empty or stale while the plan is whole, and EXECUTE reads only the sidecar.
  plan_ids="$(lib plan-adherence "$docs/PLAN.md" | jq -r '.plan_task_ids | sort | join(" ")')"
  sidecar_ids="$(jq -r 'if type == "array" then [.[] | .id // empty] | sort | join(" ") else "" end' "$tasks" 2>/dev/null || true)"
  if [[ "$plan_ids" != "$sidecar_ids" ]]; then
    flag "[tasks] PLAN.md task ids (${plan_ids:-none}) differ from $tasks (${sidecar_ids:-none}): derive it from PLAN.md ($extract)"
  else
    # Ids match; a hand-edited sidecar can still drift on the fields EXECUTE reads.
    fresh="$(bash "$SCRIPT_DIR/plan-tasks.sh" extract "$docs/PLAN.md" 2>/dev/null)" || fresh="[]"
    # `plan tasks` (lib/graph/driver.py cmd_plan) publishes that extraction with
    # plan-conflicts.sh's inferred edges folded in, so the comparison folds them in too:
    # otherwise every inferred edge reads as drift, and a live sonnet run copied the
    # driver's own edges into PLAN.md by hand to pass here.
    fresh_file="$(mktemp "${TMPDIR:-/tmp}/plan-exit-fresh.XXXXXX")"
    printf '%s' "$fresh" > "$fresh_file"
    inferred="$(bash "$SCRIPT_DIR/plan-conflicts.sh" edges "$fresh_file" 2>/dev/null)" && fresh="$inferred"
    rm -f "$fresh_file"
    while IFS= read -r finding; do
      [[ -n "$finding" ]] && flag "[tasks] $finding"
    done < <(python3 - "$fresh" "$tasks" <<'PY'
import json
import sys

fresh = json.loads(sys.argv[1])
with open(sys.argv[2], encoding="utf-8") as stream:
    sidecar = json.load(stream)

DISPATCH_FIELDS = ("subject", "files", "blockedBy", "verifyCommand",
                    "acceptanceCriteria", "requirements", "obligations", "executionInputs")


def value(task, field):
    # tasks.json's earlier schema wrote the heading text as "brief"; plan-tasks.sh
    # extract calls the same thing "subject" -- treat them as the one dispatch field.
    if field == "subject":
        return task.get("subject") or task.get("brief")
    return task.get(field)


by_id = {t["id"]: t for t in sidecar if isinstance(t, dict) and "id" in t}
for task in fresh:
    other = by_id.get(task["id"])
    if other is None:
        continue
    for field in DISPATCH_FIELDS:
        if value(task, field) != value(other, field):
            print("%s.%s differs between PLAN.md and %s: derive it from PLAN.md"
                  % (task["id"], field, sys.argv[2]))
PY
)
  fi
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
  # A v1 requirementsContract gets the new relation checks in place of (never in
  # addition to a weaker fallback for) legacy positional coverage -- an explicitly
  # versioned cycle cannot pass PLAN by omitting the metadata that would gate it.
  if [[ "$(fget '(.requirementsContract.format // "legacy")')" == "v1" ]]; then
    run_gate coverage lib criteria-coverage "$docs/SPEC.md" "$docs/PLAN.md" --feature-dir "$feature_dir" --tasks "$tasks"
  fi
fi
(( flags == 0 )) || exit 1
exit 0
