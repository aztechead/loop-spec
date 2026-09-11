---
name: execute
description: "Run PLAN tasks with the execution mode selected from task dependencies and available tools. Internal phase of /loop-spec:cycle. Start there for repository work."
allowed-tools: Bash Read Write Edit Glob Grep Skill Agent AskUserQuestion TeamCreate TeamDelete SendMessage TaskCreate TaskUpdate TaskList TaskGet Workflow ToolSearch
---

# EXECUTE

Publish every PLAN task onto `feat/{slug}`, with one commit per task.
Run each task's `verifyCommand` after integration.
Follow `skills/shared/dispatch.md` for dispatch.
Give each implementer `skills/shared/implementer-contract.md` and `skills/shared/engineering-directives.md`.
Use only the entry packet as input. Prepare dispatch with this call:

```bash
pb="$(bash "${LOOP_SPEC_SKILL_DIR}/../../lib/cycle-driver.sh" phase-begin execute --feature-dir "$feature_dir")"
# .entry.fields .entry.read[] .entry.flags[] (a missing ingress; relay and return)
# .execute = lib/execute-prepare.sh: branch, sidecar, sidecarOk, sidecarFlags, done[], remaining[], tasks[],
#            conflicts{rows,stops,rulings}, width, rung{}, maxRetries, featureRoot, worktreeBase, workspace{}|null, greenfield,
#            remediationRegistered, remediationError (string|null), stop
```

## 1. Branch check

If `.execute.branch.ok` is false, abort and report the expected and actual branches.
Every Git target must use the feature branch. Workspace mode checks each `workspace.repos[]` entry.
The cycle creates or enters that branch. Do not create a replacement branch here.

Never overwrite `baseSha` or `baseBranch`. Fast-forward merges always target `feat/{slug}`, never `baseBranch`.

## 2. Task set

Use `.execute.tasks[]` as the dispatch list. The preparation call already performs these steps:

1. Reads `artifacts.tasks` from `feature_dir/tasks.json`.
2. Registers `pendingRemediationTasks[]` from VERIFY, ITERATE, or DELIVER.
   Missing fields default to `blockedBy: []`, `files: []`, `acceptanceCriteria: [subject]`, and `verifyCommand: feature.commands.test`.
   A missing usable verify command fails intake; it never silently omits the task.
3. Applies `lib/task-batch.sh collapse`.
4. Removes completed IDs. `mergedSet` is `.execute.done[]`, initialized from `lib/task-progress.sh done`.
5. Adds a `blockedBy` dependency from the lower ID to the higher ID when their `files[]` overlap.
   This excludes overlaps fully covered by `feature.json.fileConflictExcludeGlobs[]` or `.loop-spec/file-conflict-exclude.txt`.

Never dispatch an already-published ID again.
If `.execute.remediationError` is non-null, stop and report that error before checking
`.execute.sidecarOk` or the remaining task list. Retain the remediation queue and
sidecar, repair the reported intake problem, then call `phase-begin execute` again.
Never rebuild tasks from PLAN.md to resolve a remediation intake error or claim the
queued work executed.
If `.execute.sidecarOk` is false, parse PLAN.md task blocks into the sidecar.
Then call `phase-begin execute` again.
If `.execute.remaining[]` is empty, go to step 5.

`lib/execute-stop.sh classify` classifies rows from `lib/plan-conflicts.sh table`.
If `.execute.stop` is true, pause EXECUTE. Return the stop row's `reason` to the cycle for escalation.
Stop rows appear in `.execute.conflicts.stops[]`.
The preparation call records all other rulings with `lib/decisions.sh add ... ruling`.

## 3. Rung

`.execute.rung` gives the execution mode selected by `lib/execute-rung.sh select` from `.execute.width`.
Width measures parallel tasks in the dependency graph (DAG).
If a dependency cycle causes `phase-begin` to exit 3, escalate as deadlock.
Print `[EXECUTE] DAG width W=<width> -> rung: <rung.rung> (<rung.reason>)`.

Workspace mode always uses `subagent` and rejects `LOOP_SPEC_EXECUTE_LOOPS=1`.
Use these operating parameters:

- `maxParallelImplementers`: 3, reduced by `LOOP_SPEC_MAX_PARALLEL_IMPLEMENTERS` or `LOOP_SPEC_MAX_PARALLEL_SUBAGENTS`. `LOOP_SPEC_WORKTREES=0` sets it to 1.
- `maxRetriesPerTask`: `.execute.maxRetries`, from `lib/tuning.sh get executeMaxRetriesPerTask 6`.
- Task worktree root: `.execute.worktreeBase`, resolved once by `lib/worktree-base.sh resolve`.

| rung | follow | notes |
|---|---|---|
| `subagent` | `skills/shared/execute-subagent.md` | one-shot implementer + reviewer Agents per wave, lead ff-merges; workspace mode always lands here |
| `team` | `skills/shared/execute-rungs.md` "Agent team" | self-claiming `loop-spec:implementer` teammates over `TaskCreate`; `TaskList` is the source of truth at every wake |
| `loop` | `skills/shared/execute-loop-fleet.md` | headless loop-runner fleet |
| `session` | `skills/shared/execute-rungs.md` "Disposable session" | headless: each implementer and reviewer is its own `claude -p` / `codex exec` / `opencode run` process through `extensions/sessions/session_run.py`; the lead ff-merges as on the subagent rung |
| `inline` | `skills/shared/execute-rungs.md` "Inline" | no dispatch tool: you implement each task on `feat/{slug}` |
| `workflow` | `skills/shared/execute-rungs.md` "Workflow DAG" | `lib/workflows/execute-dag.js`, opt-in |
| `foreign` | `skills/shared/execute-rungs.md` "Foreign claimants" | bundles on the handoff port; results collected on re-entry |

Every rung returns `{merged, blocked, escalation}`.
If `escalation` is non-null or `blocked` is non-empty, print the reasons and return to the cycle for escalation.
Dispatch, then stop. Never AskUserQuestion as a wait.

Use one driver call per task step: `cycle-driver.sh task dispatch|package|verdict|integrate` through `lib/execute-step.sh`.
`dispatch` creates the task worktree and records its base SHA, brief, report paths, and model.
It emits `dispatch` and `task_start`.
`integrate` publishes the task, runs `lib/task-progress.sh mark-done`, and emits `task_end`.
`dispatch` and `package` emit `dispatch` for the implementer and reviewer respectively. The lead emits no task events.

Pass the packet's `.model` to the Agent call unless it is `inherit`.
Issue each wave's Agent calls in one message.

**Greenfield backfill:** integrating task-001, the scaffold, detects `commands.test` and `commands.prepare` again.
It uses `lib/detect-test-cmd.sh` and `lib/prepare-environment.sh`, then runs `lib/greenfield-bootstrap.sh backfill-check`.
If `detail` names a missing backfill, check SPEC.md's Foundations requirements.
Write all four command slots before dispatching more tasks.

## 4. Merge discipline

`task integrate` runs:

```bash
lib/integrate-task.sh --feature-root "$WT_ROOT" --feature-branch feat/{slug} \
  --task-worktree <path> --task-branch task/{id}-{slug} \
  --verify "<verifyCommand>" --cleanup
```

In-place mode runs the verify command through `lib/output-digest.sh`, then commits exactly `task.files`.
Read the JSON result. Do not infer success from the exit code.

- `.published == true`: the task merged.
- `zero-commit`: the task cannot merge.
- `verify-failed`: return the task for remediation.
- `rebase-conflict`, `check-dirty-worktree`, `feature-moved`, or `publish-failed`: escalate.

Never stash, reset, or delete after a failed result.
EXECUTE runs only per-task verify commands. The repository-wide suite runs once, in VERIFY.

## 5. Exit

In explicit teams mode, call `TeamDelete` first.
Return to the cycle. The graph selects VERIFY.
The cycle's `next --returned-from execute` runs `lib/phase-exit.sh execute`.
On success, it applies the project's commit strategy, tags `post-execute`, clears the merge queue, and closes the phase.
The `at-end` strategy squashes `feat/{slug}` to one commit. The default `per-task` strategy keeps the history.

A `[plan-adherence]` FLAG returns `REDO` with unpublished PLAN IDs.
On re-entry, re-queue and dispatch those tasks. Alternatively, use `mark-done` for an ID published under another commit.
Autonomous and non-interactive runs always re-queue missing tasks.
Interactive styles may ask "re-queue or abort EXECUTE?"

## Resume

`phase-begin execute` initializes `mergedSet` from the sidecar and lists only remaining work.
Never recapture a baseline or rebuild progress from Git history.
For the workflow rung, pass `doneTaskIds`.
For the foreign rung, collect finished bundles before offering tasks again.
