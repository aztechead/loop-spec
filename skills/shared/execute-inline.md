# EXECUTE inline path (rung 0 — no subagent harness)

Selected by `execute` SKILL Step 3b when the harness has no `Agent` tool at all
(`bash "${CLAUDE_SKILL_DIR}/../../lib/harness.sh" subagents` prints `false` —
today that means pi, per `skills/shared/pi-harness.md`) and the loop-fleet rung
was not selected. The lead performs every task itself. This is one rung BELOW
the subagent path: `execute-subagent.md` still fans out one-shot `Agent` calls;
here even those do not exist.

This path returns the **same** result object as every other rung, so the
consuming code in `execute` SKILL Step 3b-exit is shape-identical:

```json
{ "merged": ["task-001", ...], "blocked": [{"taskId": "...", "reason": "..."}], "escalation": null | {"reason": "...", "detail": "..."} }
```

`blocked[].reason` uses the same fixed vocabulary (`spec-compliance-block`,
`retry-exhausted`, `commit-missing`; `deadlock` for escalation). `zero-commit`
and `rebase-conflict` cannot occur on this path — there are no task branches to
merge.

## What changes vs the subagent path

- **No per-task worktrees or branches.** Worktree isolation buys parallel
  safety; with a single executor there is nothing to isolate. Work happens
  directly on `feat/{slug}` in the feature worktree, and the merge step
  disappears — a committed task is already integrated.
- **No separate reviewer dispatch.** The spec-compliance review still happens
  (same brief, same verdict vocabulary), performed by the lead against the
  task's acceptance criteria immediately after the task's verify passes. Review
  discipline per the inline dispatch rule in `pi-harness.md`: judge against the
  criteria, record the verdict in gate-logs, THEN proceed.
- **Post-merge re-verify collapses into the task loop.** The subagent path
  re-runs `verifyCommand` on the integrated branch because the implementer's
  green came from a task worktree that may have been stale. Here the green IS
  from the integrated branch, so one verify per task suffices.
- **Per-task models are ignored.** `metadata.model` / `modelTier` route
  subagent and loop dispatches; inline work runs on the session model.

## Inputs

Same as `execute-subagent.md`: `tasks[]` (`{id, subject, files, blockedBy,
specPath, acceptanceCriteria, readFirst, brief, verifyCommand}`),
`maxRetriesPerTask` (2), `featureBranch = feat/{slug}`, `commands`
(`{lint, test, typecheck}` from `feature.json.commands`).
`maxParallelImplementers` is moot (executor count is 1).

## Lead task loop

Maintain `mergedSet` and `blocked[]`. Repeat until `remaining` is empty:

1. **Ready set:** `remaining = tasks - mergedSet - blocked`; `ready = [t in
   remaining if every dep in t.blockedBy is in mergedSet]`. Empty `ready` with
   non-empty `remaining` → `escalation = {reason: "deadlock", detail:
   "unmergeable dependency cycle or all remaining blocked"}`; exit.
2. **Pick ONE task** (`ready[0]` in DAG order) and confirm `git status` is
   clean — uncommitted drift from a previous task must be committed or reverted
   before the next task starts, or task attribution dissolves.
3. **Execute the task yourself** under the implementer charter
   (`agents/implementer.md`): read `readFirst`, TDD (failing test first where
   the task admits one), touch only `files`, keep to the brief.
4. **Verify:** run the task's `verifyCommand`, then `commands.test` (and lint /
   typecheck when configured). Not green after fixes → retry the task up to
   `maxRetriesPerTask` attempts total, then `blocked += {taskId, reason:
   "retry-exhausted"}` and `git checkout -- .` to clear the failed attempt.
5. **Commit** on `feat/{slug}` with the task id in the message (same message
   contract as the implementer prompt). Nothing staged → `blocked += {taskId,
   reason: "commit-missing"}`.
6. **Inline spec-compliance review** against `acceptanceCriteria` (reviewer
   brief semantics; verdict `pass | rework | block`):
   - `pass` → add the task id to `mergedSet`, log the verdict, continue.
   - `rework` with attempts remaining → fix in place, re-run step 4, re-review.
   - `rework` exhausted → `blocked += {taskId, reason: "retry-exhausted"}`
     (revert the task's commits: `git revert --no-edit <shas>`).
   - `block` → `blocked += {taskId, reason: "spec-compliance-block"}` (revert
     likewise).

Dispatch telemetry (`skills/shared/dispatch-events.md`) still fires per task
with the rung recorded as `inline`.

## What does NOT change

Artifacts, gates, PLAN.md task blocks, `feature.json` schema, gate-log
locations, the phase-exit contract. A feature started on any other rung can
resume on this one and vice versa — the DAG state is recomputed from PLAN.md
plus the commits on `feat/{slug}`, exactly like a workflow-path resume.
