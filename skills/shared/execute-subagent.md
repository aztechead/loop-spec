# EXECUTE subagent path (rungs 1 & 2)

The lightest two rungs of the EXECUTE concurrency ladder (`skills/shared/tier-matrix.md`
-> "EXECUTE concurrency ladder"). Selected by `execute` SKILL Step 3 when the DAG
width `W < t_team`. The lead (the main thread running `execute`) drives the wave loop
itself with one-shot `Agent` dispatches and inline `git` merges. No `TeamCreate`, no
`Workflow`, no `SendMessage`, no harness task list.

This path returns the **same** result object as the workflow and team paths so the
consuming code in `execute` SKILL Step 3 is shape-identical:

```json
{ "merged": ["task-001", ...], "blocked": [{"taskId": "...", "reason": "..."}], "escalation": null | {"reason": "...", "detail": "..."}, "tier": "<tier>" }
```

`blocked[].reason` and `escalation.reason` use the SAME fixed vocabulary as
`lib/workflows/execute-dag.js` (`spec-compliance-block`, `retry-exhausted`,
`commit-missing`, `zero-commit`; `deadlock`, `rebase-conflict`). Display only.

## When this path runs

- **Rung 1 (`W == 1`):** the DAG is a serial chain (or a single task). Each wave has
  exactly one ready task. The lead dispatches one implementer `Agent`, reviews it
  (quality/balanced), merges it, then advances. No real concurrency exists, so the
  team/workflow machinery would be pure overhead.
- **Rung 2 (`2 <= W < t_team`):** modest concurrency. Each wave has a handful of ready
  tasks; the lead fires them as parallel `Agent` calls **in a single assistant
  message** (the harness runs independent tool calls concurrently), then reviews and
  merges the wave before advancing. A persistent team is not worth its coordination
  cost at this width.

Both rungs share the loop below; they differ only in how many `Agent` calls go out per
wave (`min(|ready|, maxParallelImplementers)`).

## Inputs (resolved by `execute` Step 3 before entering this path)

- `tasks[]` — each `{id, subject, files, blockedBy (union), specPath, acceptanceCriteria, readFirst, brief}`.
- `tier`, `maxParallelImplementers`, `maxRetriesPerTask`, `reviewersEnabled` — from the tier matrix.
- `featureWorktreeRoot = $(git rev-parse --show-toplevel)`, `featureBranch = feat/{slug}`.
- `models.implementer`, `models.specComplianceReviewer` — passed as the `Agent` `model`.
- `commands` — `{lint, test, typecheck}` from `feature.json.commands`.

## Lead wave loop

Maintain `mergedSet` (task ids merged onto `feat/{slug}`) and `blocked[]`. Repeat:

1. **Compute the remaining set:** `remaining = tasks - mergedSet - {b.taskId for b in blocked}`. If empty, exit the loop (success).
2. **Compute the ready set:** `ready = [t in remaining if every dep in t.blockedBy is in mergedSet]`.
   - If `ready` is empty while `remaining` is non-empty: set `escalation = {reason: "deadlock", detail: "unmergeable dependency cycle or all remaining blocked"}` and exit.
3. **Form the wave:** `wave = ready[:maxParallelImplementers]`.
4. **Dispatch the wave.** For each `taskId` in `wave`, issue an implementer `Agent`
   call. On rung 2 emit all wave calls in ONE assistant message so they run in
   parallel; on rung 1 the wave has one task. Use the prompt template below with
   `model: models.implementer`. Each call returns `{taskId, branch, committed, sha, notes}`.
5. **Review each committed task** (skip entirely when `reviewersEnabled == false`, i.e.
   quick tier). For each implementer result with `committed == true`, dispatch a
   spec-compliance reviewer `Agent` (`model: models.specComplianceReviewer`) using the
   review prompt below. It returns `{verdict: "pass"|"rework"|"block", findings[]}`.
   - `pass`: the task is ready to merge.
   - `rework` and attempts remaining (`attempt + 1 < maxRetriesPerTask`): re-dispatch the
     implementer with `findings` fed into the prompt; re-review. Loop up to
     `maxRetriesPerTask` attempts.
   - `rework` with attempts exhausted: `blocked.push({taskId, reason: "retry-exhausted"})`.
   - `block`: `blocked.push({taskId, reason: "spec-compliance-block"})`.
   - implementer `committed == false`: `blocked.push({taskId, reason: "commit-missing"})`.
6. **Merge the passed tasks** (inline, serial, in `wave` order). For each task that
   reached `pass` (or, on quick tier, simply committed):

   ```bash
   worktree_branch="task/{taskId}-{slug}"
   worktree_path="${featureWorktreeRoot}/.loop-spec/worktrees/{slug}/task-{taskId}"

   if ! bash "${CLAUDE_SKILL_DIR}/../../lib/worktree-commit-check.sh" "feat/{slug}" "$worktree_branch"; then
     # no commits over the feature branch -> not mergeable
     blocked+=("{taskId}:zero-commit")
     continue
   fi

   git checkout "feat/{slug}"
   git merge --ff-only "$worktree_branch"
   # On non-ff: rebase the task branch onto feat/{slug}, retry --ff-only.
   # On rebase conflict: set escalation = {reason: "rebase-conflict", detail: "..."} and exit the loop.
   git worktree remove "$worktree_path"
   git branch -D "$worktree_branch"
   ```

   On a successful merge add the task id to `mergedSet`.
7. **Post-merge test gate** (quality/balanced only; quick skips): run
   `feature.json.commands.test` (or `lib/detect-test-cmd.sh` if unset) from the feature
   worktree. On failure, record a remediation note and surface it via `escalation` or a
   `blocked` entry rather than silently proceeding.
8. Loop back to step 1.

## Agent dispatch convention

Dispatch every implementer and reviewer with the **default** agent (do NOT pass
`subagent_type`), exactly as `lib/workflows/execute-dag.js` does. The prompts below are
self-contained -- they carry the worktree, implement, verify, commit, and review
instructions in full. Do NOT pass `subagent_type: "loop-spec:implementer"`: that agent
declares `isolation: worktree` in its frontmatter, which would create a second worktree
on top of the explicit `git worktree add` in the prompt. Pass the role model via the
`Agent` `model` field (`models.implementer` / `models.specComplianceReviewer`).

## Implementer Agent prompt (per task, per attempt)

Substitute the runtime values. This mirrors the implementer contract in
`lib/workflows/execute-dag.js` so behavior is identical across rungs.

```
You are an implementer agent for task {taskId}.

IMPORTANT: All paths must be ABSOLUTE. Do not use relative paths. Do not use em-dashes.

Step 1 - Create the task worktree (skip if it already exists):
  git -C "{featureWorktreeRoot}" worktree add "{worktree_path}" -b "task/{taskId}-{slug}" "feat/{slug}"

Step 2 - {readFirst clause} Read the assigned files: {task.files}.
{specPath clause}

Step 3 - Implement the task in the worktree at {worktree_path}.
Task subject: {task.subject}
Brief: {task.brief}
Acceptance criteria:
{numbered acceptanceCriteria}
{prior-findings clause on rework attempts}

Touch ONLY the files listed ({task.files}). Do NOT edit unrelated files.

Step 4 - Run the configured quality commands INSIDE the worktree (skip blanks):
  Lint: {commands.lint}
  Test: {commands.test}
  Typecheck: {commands.typecheck}

Step 5 - Stage and commit inside the worktree branch:
  git -C "{worktree_path}" add <files>
  git -C "{worktree_path}" commit -m "feat: NO_JIRA {task.subject}"
Do NOT push. Do NOT run git outside the task worktree.

Return JSON: { taskId: "{taskId}", branch: "task/{taskId}-{slug}", committed: <true|false>, sha: "<sha or empty>", notes: "<notes>" }
```

## Reviewer Agent prompt (quality/balanced only)

```
You are a spec-compliance reviewer for task {taskId} (attempt {n}).

Review the diff of branch "task/{taskId}-{slug}" against "feat/{slug}" in the worktree at "{worktree_path}":
  git -C "{worktree_path}" diff "feat/{slug}"..HEAD

{specPath clause}
Acceptance criteria:
{numbered acceptanceCriteria}

Determine whether the implementation satisfies all acceptance criteria and matches the spec.
Return one of:
  - verdict "pass"   if everything is satisfied
  - verdict "rework" with specific findings if fixable issues exist
  - verdict "block"  if the implementation is fundamentally wrong or unrecoverable

Return JSON: { verdict: "pass"|"rework"|"block", findings: ["<finding 1>", ...] }
```

## Why no team here

The agent-team path (`execute` Steps 4-10) earns its `TeamCreate` cost through dynamic
self-claim, idle/wake messaging, and a persistent merge queue -- all of which matter
when many implementers contend for a wide pool of tasks. At `W < t_team` the pool is
small enough that the lead can dispatch each wave directly and serialize merges inline,
which is cheaper and simpler while producing the identical merged feature branch.
