---
name: execute
description: EXECUTE phase - dispatches the task DAG up the capability-aware concurrency ladder (inline, subagent waves, loop fleet, agent team, workflow DAG) by measured width. Cycle-internal - invoked by /loop-spec:cycle; not for ad-hoc invocation (start there).
allowed-tools: Bash Read Write Edit Glob Grep Skill Agent AskUserQuestion TeamCreate TeamDelete SendMessage TaskCreate TaskUpdate TaskList TaskGet Workflow ToolSearch
---

# EXECUTE

You publish every PLAN task onto `feat/{slug}`, one commit per task, each verified by
its own `verifyCommand` after integration. Dispatch follows `skills/shared/dispatch.md`;
the design gate every implementer carries is `skills/shared/implementer-contract.md`
(more modular? more extensible? least code? does this hold at production scale?) and
the directive set is `skills/shared/engineering-directives.md`. Your inputs are the
entry packet and nothing else, and the whole pre-dispatch bookkeeping is one call:

```bash
pb="$(bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-driver.sh" phase-begin execute --feature-dir "$feature_dir")"
# .entry.fields .entry.read[] .entry.flags[] (a missing ingress; relay and return)
# .execute = lib/execute-prepare.sh: branch, sidecar, sidecarOk, sidecarFlags, done[], remaining[], tasks[],
#            conflicts{rows,stops,rulings}, width, rung{}, maxRetries, featureRoot, worktreeBase, greenfield,
#            remediationRegistered, stop
```

## 1. Branch check

`.execute.branch.ok` false aborts with the expected and actual branch: every git target
must be on the feature branch (the cycle entered the worktree or created the in-place
branch; never create one here to compensate; workspace mode checks each
`workspace.repos[]`). Never overwrite `baseSha`/`baseBranch`; the ff-merge target is
always `feat/{slug}`, never `baseBranch`.

## 2. Task set

`.execute.tasks[]` is the dispatch list: `artifacts.tasks` (`feature_dir/tasks.json`)
with `pendingRemediationTasks[]` (from VERIFY, ITERATE, or DELIVER) already normalized
to full shape and registered (`blockedBy` → `[]`, `files` → `[]`, `acceptanceCriteria`
→ `[subject]`, `verifyCommand` → `feature.commands.test`; a task with no verify command
at all is dropped with a warning), `lib/task-batch.sh collapse` applied, done ids
removed (`mergedSet` = `.execute.done[]`, seeded from `lib/task-progress.sh done`;
already-published ids are never re-dispatched), and a synthetic `blockedBy` edge from
the lower id to the higher on every pair whose `files[]` overlap (unless a glob in
`feature.json.fileConflictExcludeGlobs[]` or `.loop-spec/file-conflict-exclude.txt`
excludes every overlapping file). `.execute.sidecarOk` false: fall back to parsing
PLAN.md task blocks into the sidecar, then call `phase-begin execute` again. If
`.execute.remaining[]` is empty, go to step 5.

Conflicts: `lib/plan-conflicts.sh table` rows were classified by
`lib/execute-stop.sh classify`; `.execute.stop` true (a row in `.execute.conflicts.stops[]`)
pauses EXECUTE (escalate through the cycle with its `reason`); every other row is a
ruling already recorded with `lib/decisions.sh add ... ruling`.

## 3. Rung

`.execute.rung` is `lib/execute-rung.sh select` over `.execute.width` (the DAG width
of the dispatch list; a dependency cycle made `phase-begin` exit 3: escalate as
deadlock). Print
`[EXECUTE] DAG width W=<width> -> rung: <rung.rung> (<rung.reason>)`. Workspace mode
skips the ladder: the rung is `subagent` (`LOOP_SPEC_EXECUTE_LOOPS=1` is refused
there). Operating parameters: `maxParallelImplementers = 3`, lowered by
`LOOP_SPEC_MAX_PARALLEL_IMPLEMENTERS` or `LOOP_SPEC_MAX_PARALLEL_SUBAGENTS`, forced to
1 by `LOOP_SPEC_WORKTREES=0`; `maxRetriesPerTask` is `.execute.maxRetries`
(`lib/tuning.sh get executeMaxRetriesPerTask 6`). Task worktrees live under
`.execute.worktreeBase` (`lib/worktree-base.sh resolve`), resolved once.

| rung | follow | notes |
|---|---|---|
| `subagent` | `skills/shared/execute-subagent.md` | one-shot implementer + reviewer Agents per wave, lead ff-merges; workspace mode always lands here |
| `team` | `skills/shared/execute-rungs.md` "Agent team" | self-claiming `loop-spec:implementer` teammates over `TaskCreate`; `TaskList` is the source of truth at every wake |
| `loop` | `skills/shared/execute-loop-fleet.md` | headless loop-runner fleet |
| `session` | `skills/shared/execute-rungs.md` "Disposable session" | headless: each implementer and reviewer is its own `claude -p` / `codex exec` / `opencode run` process through `extensions/sessions/session_run.py`; the lead ff-merges as on the subagent rung |
| `inline` | `skills/shared/execute-rungs.md` "Inline" | no dispatch tool: you implement each task on `feat/{slug}` |
| `workflow` | `skills/shared/execute-rungs.md` "Workflow DAG" | `lib/workflows/execute-dag.js`, opt-in |
| `foreign` | `skills/shared/execute-rungs.md` "Foreign claimants" | bundles on the handoff port; results collected on re-entry |

Every rung returns `{merged, blocked, escalation}`. `escalation` non-null or `blocked`
non-empty pauses EXECUTE: print the reasons and return to the cycle (it escalates).
Dispatch, then stop; never AskUserQuestion as a wait. The per-task steps are one driver
call each (`cycle-driver.sh task dispatch|package|verdict|integrate`,
`lib/execute-step.sh`): `dispatch` creates the task worktree, records the base SHA,
writes the brief and report paths, resolves the model, and emits the `dispatch` and
`task_start` events; `integrate` publishes, runs `lib/task-progress.sh mark-done`, and
emits `task_end`. `dispatch` and `package` emit the `dispatch` event for the implementer
and the reviewer; the lead emits none. Pass the packet's `.model` to the Agent call when
it is not `inherit`, and issue a wave's Agent calls in one message.

**Greenfield backfill:** `task integrate` on task-001 (the scaffold) re-detects
`commands.test` (`lib/detect-test-cmd.sh`) and `commands.prepare`
(`lib/prepare-environment.sh`) and runs
`lib/greenfield-bootstrap.sh backfill-check`; a `detail` naming a missing backfill means
cross-check SPEC.md's Foundations requirements and write all four command slots before
dispatching anything else.

## 4. Merge discipline

`task integrate` runs `lib/integrate-task.sh --feature-root "$WT_ROOT" --feature-branch
feat/{slug} --task-worktree <path> --task-branch task/{id}-{slug} --verify
"<verifyCommand>" --cleanup` (in-place mode: the verify command through
`lib/output-digest.sh`, then a commit of exactly `task.files`); read its JSON, never infer
from the exit code. `.published == true` is merged. `zero-commit` is not mergeable;
`verify-failed` returns to remediation; `rebase-conflict`, `check-dirty-worktree`,
`feature-moved`, `publish-failed` escalate. Never stash, reset, or delete after a failed
result. EXECUTE runs only per-task verify commands; the repository-wide suite runs once,
in VERIFY.

## 5. Exit

In explicit teams mode `TeamDelete` first. Return to the cycle; the graph selects
VERIFY. Its `next --returned-from execute` runs `lib/phase-exit.sh execute`: ok applies
the project's commit strategy (`at-end` squashes `feat/{slug}` to one commit; default
`per-task` keeps the history), tags `post-execute`, clears the merge queue, and closes
the phase. A `[plan-adherence]` FLAG (answered as `REDO`) names PLAN ids not yet
published: you are invoked again to re-queue them (autonomous and non-interactive runs
always re-queue; interactive styles may ask "re-queue or abort EXECUTE?") and dispatch
again, or `mark-done` an id that landed under another commit.

## Resume

`phase-begin execute` seeds `mergedSet` from the sidecar and lists only remaining work;
never recapture a baseline or rebuild progress from git history. Workflow rung: pass
`doneTaskIds`. Foreign rung: collect finished bundles before re-offering.
