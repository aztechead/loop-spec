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
entry packet and nothing else:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/phase-entry.sh" execute --feature-dir "$feature_dir"
# fields=<the feature.json keys this phase consumes>  read=<each file to read>  FLAG on a missing ingress
```

## 1. Branch check

Every git target must be on the feature branch: single-repo `git branch --show-current`
equals `feature.json.branch` (the cycle entered the worktree or created the in-place
branch; never create one here to compensate); workspace mode checks each
`workspace.repos[]` with `git -C`. A mismatch aborts with the expected and actual
branch. Never overwrite `baseSha`/`baseBranch`; the ff-merge target is always
`feat/{slug}`, never `baseBranch`.

## 2. Task set

Read `artifacts.tasks` (`feature_dir/tasks.json`; fall back to parsing PLAN.md task
blocks only when the sidecar is missing or `lib/artifact-lint.sh tasks` rejects it).
Seed `mergedSet` from `lib/task-progress.sh done <sidecar>`; already-published ids are
never re-dispatched. Append `pendingRemediationTasks[]` (from VERIFY, ITERATE, or
DELIVER) after normalizing each to full shape: `blockedBy` → `[]`, `files` → `[]`,
`acceptanceCriteria` → `[subject]`, `verifyCommand` → `feature.commands.test`; a task
with no verify command at all is dropped with a warning. Clear the array once the tasks
are registered. If nothing remains, go to step 5.

Then, on every entry:

```bash
mkdir -p "$feature_dir/dispatch"
bash "${CLAUDE_SKILL_DIR}/../../lib/plan-conflicts.sh" table "$sidecar" > "$feature_dir/dispatch/conflict-table.json"
bash "${CLAUDE_SKILL_DIR}/../../lib/task-batch.sh" collapse "$sidecar" > "$feature_dir/dispatch/tasks-collapsed.json"
```

For each pair of pending tasks whose `files[]` overlap (and no glob in
`feature.json.fileConflictExcludeGlobs[]` or `.loop-spec/file-conflict-exclude.txt`
excludes every overlapping file) add a synthetic `blockedBy` edge from the lower id to
the higher. For each conflict-table row, `lib/execute-stop.sh classify "<summary>"`:
`stop=true` pauses EXECUTE (escalate through the cycle); `stop=false reason=ruling`
records the ruling with `lib/decisions.sh add "$feature_dir" execute "<conflict>"
"<call>" "<why>" ruling` and continues. The collapsed array is the dispatch list.

## 3. Rung

```bash
W="$(printf '%s' "$tasks_json" | bash "${CLAUDE_SKILL_DIR}/../../lib/dag-width.sh")"   # exit 3 = cycle: escalate as deadlock
rung_rc=0; rung_err="$(mktemp)"
rung_json="$(bash "${CLAUDE_SKILL_DIR}/../../lib/execute-rung.sh" select --width "$W" \
  --teams-mode "$(jq -r '.teamsMode // "none"' .loop-spec/runtime.json)" \
  --workflows-available "$(jq -r '.workflowsAvailable // false' .loop-spec/runtime.json)" \
  --workflow-optin "$(jq -r '.workflowExecuteOptIn // false' .loop-spec/runtime.json)" \
  --implementer-model "$(jq -r '.models.implementer // "inherit"' "$feature_dir/feature.json")" \
  2>"$rung_err")" || rung_rc=$?
if [[ "$rung_rc" -ne 0 ]]; then
  rung_msg="$(jq -r '.message // empty' <<<"$rung_json" 2>/dev/null || true)"
  [[ -n "$rung_msg" ]] || rung_msg="$(cat "$rung_err")"
  echo "[EXECUTE] ERROR: ${rung_msg:-dispatch capability probe failed}" >&2; rm -f "$rung_err"; exit 2
fi
rm -f "$rung_err"
echo "[EXECUTE] DAG width W=$W -> rung: $(jq -r .rung <<<"$rung_json") ($(jq -r .reason <<<"$rung_json"))"
```

A non-zero exit is a configuration error (invalid `LOOP_SPEC_WORKTREES`, bad width): the
message is on stdout as JSON or on stderr as plain text, so both are captured. Stop. Workspace mode skips the ladder: the rung is `subagent`
(`LOOP_SPEC_EXECUTE_LOOPS=1` is refused there). Operating parameters:
`maxParallelImplementers = 3`, lowered by `LOOP_SPEC_MAX_PARALLEL_IMPLEMENTERS` or
`LOOP_SPEC_MAX_PARALLEL_SUBAGENTS`, forced to 1 by `LOOP_SPEC_WORKTREES=0`;
`maxRetriesPerTask` from `lib/tuning.sh get executeMaxRetriesPerTask 6`. Task worktrees
live at `lib/worktree-base.sh resolve "$WT_ROOT" task "{slug}"`, resolved once.

| rung | follow | notes |
|---|---|---|
| `subagent` | `skills/shared/execute-subagent.md` | one-shot implementer + reviewer Agents per wave, lead ff-merges; workspace mode always lands here |
| `team` | `skills/shared/execute-rungs.md` "Agent team" | self-claiming `loop-spec:implementer` teammates over `TaskCreate`; `TaskList` is the source of truth at every wake |
| `loop` | `skills/shared/execute-loop-fleet.md` | headless loop-runner fleet |
| `inline` | `skills/shared/execute-rungs.md` "Inline" | no dispatch tool: you implement each task on `feat/{slug}` |
| `workflow` | `skills/shared/execute-rungs.md` "Workflow DAG" | `lib/workflows/execute-dag.js`, opt-in |
| `foreign` | `skills/shared/execute-rungs.md` "Foreign claimants" | bundles on the handoff port; results collected on re-entry |

Every rung returns `{merged, blocked, escalation}`. `escalation` non-null or `blocked`
non-empty pauses EXECUTE: print the reasons and return to the cycle (it escalates).
Dispatch, then stop; never AskUserQuestion as a wait.
Emit one `dispatch` event per agent launched. After each successful publication run
`lib/task-progress.sh mark-done "$sidecar" <id>`.

**Greenfield backfill:** right after task-001 (the scaffold) merges, re-detect
`commands.test` (`lib/detect-test-cmd.sh .`) and `commands.prepare`
(`lib/prepare-environment.sh run --root .`), cross-check SPEC.md's Foundations
requirements, write all four command slots, and run
`bash "${CLAUDE_SKILL_DIR}/../../lib/greenfield-bootstrap.sh" backfill-check "$feature_dir"`
before dispatching anything else; exit 3 means fix the backfill first.

## 4. Merge discipline

Each task's branch is integrated with
`lib/integrate-task.sh --feature-root "$WT_ROOT" --feature-branch feat/{slug}
--task-worktree <path> --task-branch task/{id}-{slug} --verify "<verifyCommand>" --cleanup`;
read its JSON, never infer from the exit code. `.published == true` is merged.
`zero-commit` is not mergeable; `verify-failed` returns to remediation;
`rebase-conflict`, `check-dirty-worktree`, `feature-moved`, `publish-failed` escalate.
Never stash, reset, or delete after a failed result. EXECUTE runs only per-task verify
commands; the repository-wide suite runs once, in VERIFY.

## 5. Exit

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/phase-exit.sh" execute --feature-dir "$feature_dir"
```

A `[plan-adherence]` FLAG names PLAN ids not yet published: re-queue them (autonomous
and non-interactive runs always re-queue; interactive styles may ask "re-queue or abort
EXECUTE?") and dispatch again, or `mark-done` an id that landed under another commit.
`phase-exit: ok (execute)` applies the project's commit strategy (`at-end` squashes
`feat/{slug}` to one commit; default `per-task` keeps the history), tags
`post-execute`, clears the merge queue, and closes the phase. In explicit teams mode
`TeamDelete` first. Return to the cycle; the graph selects VERIFY.

## Resume

Step 2 seeds `mergedSet` from the sidecar and dispatches only remaining work; never
recapture a baseline or rebuild progress from git history. Workflow rung: pass
`doneTaskIds`. Foreign rung: collect finished bundles before re-offering.
