# EXECUTE team-rung protocol -- Steps 7-10 (reference)

Extracted verbatim from `skills/execute/SKILL.md`; the SKILL stub points here.
These steps apply on the team rung (explicit or implicit team mode). Apply as written.

### Step 7 - Fallback: Idle/wake protocol

Idle and wake are event-driven. No polling.

When `TaskList()` (client-filtered to `status == "pending"`) returns no unblocked tasks and no `needs_rework` tasks are claimable, the implementer sends `SendMessage({to: "lead", body: "implementer-{N} idle: no available tasks"})`.

The lead maintains an in-memory set of known idle implementers. When the lead receives a `REVIEW PASS` message and new tasks are unblocked, it wakes idle implementers:

```
SendMessage({to: "implementer-{N}", body: "New tasks unblocked: [task-{id}, ...]"})
```

**Harness contract cited:** "Idle teammates can receive messages. Sending a message to an idle teammate wakes them up and they will process it normally."

#### Lead wake-and-reconcile contract (source of truth = TaskList, not messages)

A teammate's plain-text output is invisible to the lead, and a teammate's final `SendMessage` can race with its turn-end and be dropped. So the lead MUST NOT treat any teammate `SendMessage` (`CLAIMED`, `REVIEW PASS`, idle, `TASK BLOCKED`) as the source of truth for progress. Those messages are wake hints and log triggers only.

The harness guarantees one event the lead can rely on: every time a teammate ends a turn it goes idle and the lead receives a `TeammateIdle` notification. The lead treats **every** wake -- any teammate `SendMessage` OR any `TeammateIdle` notification -- as a trigger to reconcile from `TaskList` state:

1. Re-read `TaskList`.
2. **Enqueue** (Step 8) any task now in `completed` status with `metadata.result != "blocked"` whose worktree branch has commits over `feat/{slug}` and that is not already merged or already in `mergeQueue`. This catches a completion whose `REVIEW PASS` was never received. Retry-exhausted tasks (`metadata.result == "blocked"`) are terminal-completed but reviewer-rejected; they are NOT merged here -- Step 10 escalates them.
3. Process the merge queue (Step 8).
4. Re-evaluate the exit condition (Step 10).

The lead is therefore self-correcting: even if every teammate `SendMessage` were dropped, the guaranteed `TeammateIdle` stream still drives the merge queue and the phase to completion. This mirrors the DISCUSS phase, which already synchronizes on `TeammateIdle` plus a state/artifact check rather than on message receipt. The lead must never block waiting for a specific message; it acts on TaskList state at each wake.

### Step 8 - Fallback: Merge queue

The lead serializes worktree merges through a FIFO dependency-aware merge queue. The queue is persisted in `feature.json` under `mergeQueue: ["task-NNN", ...]` to survive kills.

**Enqueue (state-driven):** On every wake (Step 7 reconcile), the lead appends to `mergeQueue` -- via `lib/feature-write.sh append mergeQueue "{taskId}"` -- any task now in `completed` status with `metadata.result != "blocked"` whose worktree branch has commits over `feat/{slug}` and that is not already in `mergeQueue` and not already merged. A `REVIEW PASS: task-{taskId}` message is one wake hint that prompts this reconcile, but enqueue is driven by TaskList state, not by message receipt: a completed task is enqueued even if its `REVIEW PASS` was dropped. A retry-exhausted task (`completed` + `metadata.result == "blocked"`) has worktree commits from its failed attempts but was reviewer-rejected; it is never enqueued -- Step 10 detects it and escalates.

**Process loop:** For each task id at the head of the queue, check that every blockedBy entry is already merged onto `feat/{slug}`. If any blocker is not yet merged, rotate to back of queue. If all blockers merged, proceed with merge then restart from head.

**Merge procedure:**

```bash
worktree_path="$WT_ROOT/.loop-spec/worktrees/{slug}/task-{taskId}/"
worktree_branch="task/{taskId}-{slug}"

if ! bash "${CLAUDE_SKILL_DIR}/../../lib/worktree-commit-check.sh" "feat/{slug}" "{worktree_branch}"; then
  echo "[TEAM-EXECUTE] task-{taskId} worktree has no commits over feat/{slug}; not merging" >&2
  exit_merge_for_task=1
fi

git checkout feat/{slug}
git merge --ff-only {worktree_branch}
# On non-ff: rebase task branch onto feat/{slug}, retry ff-merge.
# On rebase conflict: escalate to user; do not auto-resolve.
```

**Post-merge cleanup:** `git worktree remove "$worktree_path"` and `git branch -D {worktree_branch}`. Remove task id from `mergeQueue` via `lib/feature-write.sh`.

**Post-merge test gate:** run `feature.json.commands.test` (or `lib/detect-test-cmd.sh` if unset). On failure: create a remediation task and re-enter Step 2.

For full detail on the self-claim loop, reviewer loop, rework re-entry, and race-claim serialization, see **`skills/shared/execute-loops.md`**.

### Step 9 - Fallback: Log emission

Implementers send `SendMessage({to: "lead", body: "CLAIMED: task-{taskId}"})` immediately after a successful claim. The lead emits:

```
echo "[TEAM-EXECUTE] task-{taskId} claimed by implementer-{N}"
```

Smoke assertion regex: `^\[TEAM-EXECUTE\] task-[0-9]+ claimed by implementer-[0-9]+$`

Verify command: `grep -oE 'implementer-[0-9]+' run.log | sort -u | wc -l` returns >= 2.

### Step 10 - Fallback: Phase exit condition

The lead re-evaluates this exit condition on every wake (Step 7 reconcile) and after each merge-queue processing pass -- never only on message receipt. Exit fires when:

- Zero tasks in `pending` or `in_progress` status.
- `mergeQueue` is empty.
- Worktree cleanup ran for every merged task.

Because the check is driven by the guaranteed `TeammateIdle` stream rather than by a final `REVIEW PASS`/idle message, the phase still exits cleanly when the last completion message is dropped: the teammate that finished the final task goes idle, the lead wakes, reconciles TaskList (zero open tasks, empty queue), and exits.

If any `completed` task carries `metadata.result == "blocked"` (retry budget exhausted): pause EXECUTE, print the task id and last reviewer findings, return control to the user.

**Plan-adherence gate:**

```bash
adherence_json=$(bash "${CLAUDE_SKILL_DIR}/../../lib/plan-adherence.sh" "$plan_path")
plan_task_ids=$(echo "$adherence_json" | jq -r '.plan_task_ids[]')
gap_message=$(echo "$adherence_json" | jq -r '.gap_message // empty')
```

For each `plan_task_id`, confirm at least one completed task subject contains it as a substring. On gap: `AskUserQuestion` with options to re-queue or abort.

TeamDelete and cleanup:

```
TeamDelete({name: "loop-spec-execute-{slug}"})
```

```bash
lib/feature-write.sh set currentTeamName null
```
