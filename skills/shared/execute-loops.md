# EXECUTE self-claim loops (reference)

Detailed walkthrough of the implementer and reviewer self-claim loops referenced by `skills/execute/SKILL.md` Step 5 and Step 6. The authoritative prompts the teammates actually run are `skills/shared/team-prompts/implementer.md` and `skills/shared/team-prompts/reviewer.md`; this file documents the contract the EXECUTE lead relies on. The 3-state task model lives inline in `skills/execute/SKILL.md` Step 5 because the lead's wake/merge/exit logic depends on it.

## Implementer self-claim loop (per implementer)

Repeat until idle:

1. **Query** for pending tasks AND in-flight tasks awaiting rework:
   ```
   pending     = TaskList({status: "pending"})
   needs_rework = [t for t in TaskList({status: "in_progress"}) if t.metadata.phase == "needs_rework" and t.owner == null]
   ```
2. **Filter** `pending` for tasks whose `blockedBy` entries are all in `completed` status. Concatenate with `needs_rework` (rework tasks are inherently unblocked). Select the first available task.
3. **Claim** via `TaskUpdate({taskId: "<id>", status: "in_progress", owner: "implementer-{N}", metadata: {claimedBy: "implementer-{N}", phase: null}})`.
   - The call sets status (no-op if already `in_progress`), owner, claim record, and clears `metadata.phase` so the task no longer matches the rework filter.
   - On success: proceed to step 4.
   - On error (race loss): go back to step 1.
4. **Read task details** via `TaskGet({taskId: "<id>"})`. Load `metadata.files`, `metadata.verifyCommand`, `metadata.acceptanceCriteria`.

### Worktree creation (per claimed task)

After step 4, the implementer creates its worktree:

```bash
worktree_path=".loop-spec/worktrees/{slug}/task-{taskId}/"
worktree_branch="task/{taskId}-{slug}"

git worktree add -b {worktree_branch} {worktree_path} {branch}
```

The implementer then:

5. **Implements** the task in the worktree, modifying only the files listed in `metadata.files`.
6. **Runs** `metadata.verifyCommand` from inside the worktree. Loops on failure until the command passes.
7. **Commits** in the worktree branch: `feat: NO_JIRA task-{taskId} {subject}`.
8. **Hands off** to review by releasing ownership and flagging review-ready:
   ```
   TaskUpdate({taskId: "<id>", owner: null, metadata: {phase: "awaiting_review"}})
   ```
   Status stays `in_progress` (work is in flight; only the role-holder is changing).
9. Returns to step 1 to claim the next task.

### When no tasks are available

If no unblocked pending tasks exist, the implementer sends:

```
SendMessage({to: "lead", body: "implementer-{N} idle: no available tasks"})
```

Then goes idle. The lead will send a `SendMessage` wake when new tasks are unblocked; the implementer wakes automatically on receipt and re-runs from step 1.

### Completion is state-driven, not message-driven

Every status transition (`TaskUpdate`) is written BEFORE its accompanying `SendMessage`, so `TaskList` is the source of truth even if a message is dropped at turn-end. The lead does not depend on any teammate message arriving: per `skills/execute/SKILL.md` Step 7 (lead wake-and-reconcile contract) it reconciles the merge queue and exit condition from `TaskList` state on every wake, including the guaranteed `TeammateIdle` notification a teammate emits when it goes idle. A dropped `REVIEW PASS`/idle message therefore cannot strand a completed task or hang the phase; the next idle event re-drives the lead.

### Race-claim serialization contract

The harness serializes concurrent `TaskUpdate` calls on the same task id. If two implementers race to claim the same task, exactly one call succeeds and the other returns an error. The losing implementer must catch the error and re-run its self-claim loop from step 1. No additional locking is implemented at the cycle level; the harness serialization is the sole concurrency control.

## Reviewer self-claim loop (per reviewer)

Mirrors the implementer self-claim model.

Repeat until idle:

1. **Query** `awaiting_review` tasks (status stays `in_progress`; `metadata.phase` is the discriminator):
   ```
   review_queue = [t for t in TaskList({status: "in_progress"}) if t.metadata.phase == "awaiting_review" and t.owner == null]
   ```
2. **Claim** by taking ownership (status unchanged, still `in_progress`):
   ```
   TaskUpdate({taskId: "<id>", owner: "reviewer-{N}", metadata: {phase: null}})
   ```
   - The `metadata.phase: null` write removes the task from the awaiting_review filter so no other reviewer races.
   - On success: proceed to step 3.
   - On error (race loss): go back to step 1.
3. **Read task details** via `TaskGet({taskId: "<id>"})`. Load `metadata.verifyCommand`, `metadata.acceptanceCriteria`, and `metadata.claimedBy` (the implementer who implemented this task).
4. **Run** `metadata.verifyCommand` from inside the task's worktree to confirm the implementation still passes.
5. **Review** the implementation against `metadata.acceptanceCriteria` for spec compliance.
6. **Outcome decision:**
   - **Pass:** `TaskUpdate({taskId, status: "completed"})`, then `SendMessage({to: "lead", body: "REVIEW PASS: task-<id>"})`.
   - **Fail (retry budget remaining):** `TaskUpdate({taskId, owner: null, metadata: {phase: "needs_rework", retries: <current+1>}})`, then `SendMessage({to: "<metadata.claimedBy>", body: "REWORK NEEDED: task-<id>\n{findings}"})`. Task stays `in_progress`; implementer picks it back up via the rework filter in their self-claim loop.
   - **Fail (retry budget exhausted, i.e. `retries + 1 > maxRetriesPerTask` (fixed: 2)):** `TaskUpdate({taskId, status: "completed", metadata: {phase: null, result: "blocked"}})`, then `SendMessage({to: "lead", body: "TASK BLOCKED: task-<id> exceeded retry budget"})`. Marking the task `completed` (terminal status) keeps the harness task list moving forward; `metadata.result == "blocked"` flags it for the lead's exit-condition check to pause + escalate.
7. Return to step 1 to claim the next `awaiting_review` task.

### Rework re-entry for implementers

When an implementer receives a `REWORK NEEDED` message from a reviewer, the task is already back in the rework queue (owner=null, metadata.phase="needs_rework"). The implementer re-runs its self-claim loop, which will surface and re-claim the task on the rework filter. Status stays `in_progress` throughout the rework -- only ownership and `metadata.phase` move.
