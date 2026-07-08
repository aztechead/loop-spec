# EXECUTE subagent path (rungs 1 & 2)

The lightest two rungs of the EXECUTE concurrency ladder (`skills/shared/tier-matrix.md`
-> "EXECUTE concurrency ladder"). Selected by `execute` SKILL Step 3 when the DAG
width `W < t_team`. The lead (the main thread running `execute`) drives the wave loop
itself with one-shot `Agent` dispatches and inline `git` merges. No `TeamCreate`, no
`Workflow`, no `SendMessage`, no harness task list.

This path returns the **same** result object as the workflow and team paths so the
consuming code in `execute` SKILL Step 3 is shape-identical:

```json
{ "merged": ["task-001", ...], "blocked": [{"taskId": "...", "reason": "..."}], "escalation": null | {"reason": "...", "detail": "..."} }
```

`blocked[].reason` and `escalation.reason` use the SAME fixed vocabulary as
`lib/workflows/execute-dag.js` (`spec-compliance-block`, `retry-exhausted`,
`commit-missing`, `zero-commit`; `deadlock`, `rebase-conflict`). Display only.

## When this path runs

- **Rung 1 (`W == 1`):** the DAG is a serial chain (or a single task). Each wave has
  exactly one ready task. The lead dispatches one implementer `Agent`, reviews it
  , merges it, then advances. No real concurrency exists, so the
  team/workflow machinery would be pure overhead.
- **Rung 2 (`2 <= W < t_team`):** modest concurrency. Each wave has a handful of ready
  tasks; the lead fires them as parallel `Agent` calls **in a single assistant
  message** (the harness runs independent tool calls concurrently), then reviews and
  merges the wave before advancing. A persistent team is not worth its coordination
  cost at this width.

Both rungs share the loop below; they differ only in how many `Agent` calls go out per
wave (`min(|ready|, maxParallelImplementers)`).

## Inputs (resolved by `execute` Step 3 before entering this path)

- `tasks[]` — each `{id, subject, files, blockedBy (union), specPath, acceptanceCriteria, readFirst, brief, verifyCommand}`. (`verifyCommand` comes straight from the PLAN task block; it is the per-task behavioral assertion re-run post-merge in step 7.)
- `maxParallelImplementers` (3), `maxRetriesPerTask` (2), `reviewersEnabled` (true) — fixed (`skills/shared/tier-matrix.md`).
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
   parallel; on rung 1 the wave has one task. Use the prompt template below.
   **Per-task model resolution** (cheapest model that fits, in priority order):
   1. a concrete `metadata.model` pin on the task, else
   2. `bash "${CLAUDE_SKILL_DIR}/../../lib/model-tier.sh" model "$(task.metadata.modelTier)"` when the task carries a `modelTier`, else
   3. `models.implementer` (the role default).
   Each call returns `{taskId, branch, committed, sha, notes}`. (Per-task model override applies to the subagent and loop rungs; the team rung pre-spawns implementer teammates and uses the role default for all of them.)
5. **Review each committed task** (`reviewersEnabled` is fixed true). For each implementer result with `committed == true`, dispatch a
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
   reached `pass`:

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

   **Post-merge re-verify (all tiers) — trust the INTEGRATED branch, not the implementer's
   worktree.** The implementer's own "TASK PASS" / verify output came from inside its task
   worktree, which is removed immediately above. That signal describes an environment that no
   longer exists and may have been branched from a stale base; it is NOT trustworthy on its
   own. So, right after the worktree is removed and the task is in `mergedSet`, re-run that
   task's `verifyCommand` from the **feature worktree** (`feat/{slug}` with the merge applied):

   ```bash
   if [[ -n "{task.verifyCommand}" ]]; then
     ( cd "$featureWorktreeRoot" && git checkout "feat/{slug}" >/dev/null 2>&1 && eval "{task.verifyCommand}" )
     if [[ $? -ne 0 ]]; then
       # The merged, integrated code fails the task's own behavioral check.
       blocked+=("{taskId}:retry-exhausted")   # surface for re-queue / escalation
       # (Do NOT leave it silently in mergedSet as "passed".)
     fi
   fi
   ```

   A task is only genuinely done when its `verifyCommand` passes against the integrated
   feature branch. This mirrors the team rung's post-merge test gate (`execute` SKILL Step 8)
   but at per-task granularity, and it is the safety net for finding #2/#8: even if an
   implementer ran isolated-from-base and its green check was for a discarded worktree, the
   post-merge re-verify here catches code that never actually integrated.
7. **Post-merge test gate**: run
   `feature.json.commands.test` (or `lib/detect-test-cmd.sh` if unset) from the feature
   worktree. On failure, record a remediation note and surface it via `escalation` or a
   `blocked` entry rather than silently proceeding. (The per-task re-verify above asserts each
   task's own behavior; this whole-suite gate catches cross-task regressions.)
8. Loop back to step 1.

## Agent dispatch convention

Dispatch every implementer and reviewer with the **default** agent (do NOT pass
`subagent_type`), exactly as `lib/workflows/execute-dag.js` does. The prompts below are
self-contained -- they carry the worktree, implement, verify, commit, and review
instructions in full. Do NOT pass `subagent_type: "loop-spec:implementer"`: that agent
declares `isolation: worktree` in its frontmatter, which would create a second worktree
on top of the explicit `git worktree add` in the prompt. Pass the role model via the
`Agent` `model` field (`models.implementer` / `models.specComplianceReviewer`).

**Dispatch telemetry (`skills/shared/dispatch-events.md`):** emit one `dispatch` event per implementer/reviewer Agent call — `bash "${CLAUDE_SKILL_DIR}/../../lib/events.sh" emit ".loop-spec/features/${slug}" dispatch --phase "execute" --data '{"role":"<implementer|spec-compliance-reviewer>","model":"<resolved alias>","rung":"subagent"}' || true`. Retries of the same task are new launches and DO re-emit.

## Implementer Agent prompt (per task, per attempt)

Substitute the runtime values. This mirrors the implementer contract in
`lib/workflows/execute-dag.js` so behavior is identical across rungs.

This dispatch uses the DEFAULT agent (not loop-spec:implementer), so the agent definition's
ponytail directive does NOT apply here and a SessionStart hook does not reach this subagent.
The simplicity directive is therefore inlined verbatim below (canonical source:
`skills/shared/laziness-ladder.md`) so EXECUTE follows ponytail on this rung every time.

```
You are an implementer agent for task {taskId}.

IMPORTANT: All paths must be ABSOLUTE. Do not use relative paths. Do not use em-dashes.

SIMPLICITY (ponytail laziness ladder — on by default). Write the shortest solution that
actually works; the best code is the code never written. BEFORE writing code, stop at the
first rung that holds: (1) does it need to exist at all? speculative = skip it (YAGNI);
(2) already in this codebase? reuse the existing helper/util/type/pattern, do not
re-implement it; (3) stdlib does it? use it; (4) native platform feature covers it? use it;
(5) an already-installed dependency solves it? use it, never add a new one for what a few
lines do; (6) can it be one line? one line; (7) only then, the minimum code that works. The
ladder runs AFTER you understand the problem. Bug fix = root cause, not symptom. NEVER cut
input validation at trust boundaries, error handling that prevents data loss, security,
accessibility, or anything the spec requires. Non-trivial logic leaves ONE runnable check
behind. Mark deliberate shortcuts with a `simplicity:` comment naming the ceiling.

DESIGN FOR CHANGE (seams, not speculation — on by default). Design to the task's stated
interface, not an implementation detail; one unit, one reason to change. New units receive
their collaborators (params/args/env), never construct them deep inside. Never cut a seam
to save lines, and never build speculation behind one (YAGNI cuts artifacts, not seams).
Bug-fix tasks: after the root cause is fixed, sweep callers, copy-pasted patterns, and
parallel paths for the same mechanism; fix same-cause siblings within the task's files
scope, report the rest.

EXECUTION DISCIPLINE (evidence over recall — on by default). You execute a brief a
stronger reasoning pass produced; your job is fidelity, not improvisation. Verify, don't
recall: never assert what a file/command/API does from memory — read it, run it, paste
the actual output. Surprise is signal: output contradicting your expectation is
information — stop, re-read, revise; never explain it away. Re-read the acceptance
criteria before DONE and check each against actual output. Depth over breadth: read the
load-bearing file completely instead of skimming five. "Should work" / "probably fine" /
"tests likely pass" each mean run it now.

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

## Reviewer Agent prompt

```
You are a spec-compliance reviewer for task {taskId} (attempt {n}).

Review the diff of branch "task/{taskId}-{slug}" against "feat/{slug}" in the worktree at "{worktree_path}":
  git -C "{worktree_path}" diff "feat/{slug}"..HEAD

{specPath clause}
Acceptance criteria:
{numbered acceptanceCriteria}

Determine whether the implementation satisfies all acceptance criteria and matches the spec.

Over-engineering pass (ponytail): scan the diff for
complexity it does not need. Flag each as a rework finding — delete: dead/speculative code;
stdlib: hand-rolled thing the standard library already ships; yagni: abstraction with one
implementation or config nobody sets; shrink: same logic in fewer lines. Do NOT flag the
ponytail minimum (a single smoke/assert check, or an accepted `simplicity:`-marked shortcut).

Return one of:
  - verdict "pass"   if everything is satisfied
  - verdict "rework" with specific findings if fixable issues exist (incl. over-engineering)
  - verdict "block"  if the implementation is fundamentally wrong or unrecoverable

Return JSON: { verdict: "pass"|"rework"|"block", findings: ["<finding 1>", ...] }
```

## Why no team here

The agent-team path (`execute` Steps 4-10) earns its `TeamCreate` cost through dynamic
self-claim, idle/wake messaging, and a persistent merge queue -- all of which matter
when many implementers contend for a wide pool of tasks. At `W < t_team` the pool is
small enough that the lead can dispatch each wave directly and serialize merges inline,
which is cheaper and simpler while producing the identical merged feature branch.

## Workspace mode

When `feature.workspace` is non-null, the subagent rung is always selected (the rung is
hard-pinned in `execute` SKILL Step 3). The wave loop below runs with these differences.

### Wave construction

Group the ready task set by `repo` field before forming a wave. Never schedule two tasks
with the same `repo` concurrently -- a repo's branch history must remain a clean linear
sequence of commits:

```
ready_tasks = [tasks in ready set]
# Group by repo, take at most one per repo per wave:
wave = []
repos_in_wave = set()
for task in ready_tasks:
  if task.repo not in repos_in_wave and len(wave) < maxParallelImplementers:
    wave.append(task)
    repos_in_wave.add(task.repo)
```

Tasks from different repos may still run in the same wave (parallel across repos,
serialized within each repo). The wave is still capped by `maxParallelImplementers`.

### Implementer prompts (workspace mode)

Each implementer `Agent` call in workspace mode receives a prompt that includes:
- `repo`: the repo name (e.g., `frontend`)
- `abs_repo`: the absolute path to the repo (`{feature.workspace.root}/{repo.path}`)
- `branch`: `feat/{slug}` (the in-place branch on that repo)

The prompt instructs the implementer:

```
You are an implementer agent for task {taskId} in repo '{repo}'.

IMPORTANT: All paths must be ABSOLUTE. Do not use em-dashes.

SIMPLICITY (ponytail laziness ladder — on by default). Write the shortest solution that
actually works. BEFORE writing code, stop at the first rung that holds: (1) needed at all?
speculative = skip (YAGNI); (2) already in this codebase? reuse it; (3) stdlib does it?
use it; (4) native platform feature? use it; (5) installed dependency solves it? use it,
add no new one for what a few lines do; (6) one line? one line; (7) only then the minimum
that works. Ladder runs AFTER understanding the problem; bug fix = root cause not symptom.
NEVER cut validation at trust boundaries, data-loss error handling, security, accessibility,
or anything the spec requires. Non-trivial logic leaves ONE runnable check behind.

DESIGN FOR CHANGE (seams, not speculation — on by default). Design to the task's stated
interface; one unit, one reason to change; new units receive collaborators (params/args/env),
never construct them deep inside. Never cut a seam to save lines, never build speculation
behind one. Bug-fix tasks: sweep for the same mechanism (callers, copies, parallel paths)
and fix same-cause siblings in scope; report the rest.

EXECUTION DISCIPLINE (evidence over recall — on by default). Verify, don't recall: never
assert what a file/command does from memory — read it, run it, paste the actual output.
Surprise is signal: output contradicting expectation means stop and revise, never explain
away. Re-read the acceptance criteria before DONE and check each against actual output.
"Should work" / "probably fine" / "tests likely pass" each mean run it now.

Repo: {repo}
Repo path: {abs_repo}   (absolute; all git and file operations target this directory)
Branch: feat/{slug}     (already checked out in this repo; do NOT create a worktree)

Step 1 - Read the assigned files. Files are workspace-relative ({repo}/{path}); resolve
         them as absolute paths under {abs_repo}.
{readFirst clause}
{specPath clause}

Step 2 - Implement the task directly in the repo at {abs_repo}.
Task subject: {task.subject}
Brief: {task.brief}
Acceptance criteria:
{numbered acceptanceCriteria}
{prior-findings clause on rework attempts}

Touch ONLY the files listed ({task.files}). Do NOT edit unrelated files.
Do NOT create a git worktree. Edit files directly in {abs_repo}.

Step 3 - Run the configured quality commands with cwd = {abs_repo} (skip blanks):
  Lint: {repo.commands.lint}
  Test: {repo.commands.test}
  Typecheck: {repo.commands.typecheck}

Step 4 - Stage and commit using git -C so git does not depend on cwd:
  git -C "{abs_repo}" add <files>
  git -C "{abs_repo}" commit -m "feat: NO_JIRA {task.subject}"
Do NOT push. Do NOT run git against any path other than {abs_repo}.

Return JSON: { taskId: "{taskId}", repo: "{repo}", committed: <true|false>, sha: "<sha or empty>", notes: "<notes>" }
```

### Merge and ff steps (workspace mode -- skipped)

In workspace mode the per-task ff-merge steps from the standard wave loop (step 6:
`git checkout feat/{slug}` / `git merge --ff-only`) are **skipped entirely**. Implementers
commit directly on `feat/{slug}` in the repo; there is no task branch and no per-task
worktree to merge. The lead does not run `git merge` or `git worktree remove` for
workspace tasks.

The post-wave test gate (step 7) still applies: run each participating repo's detected
test command (`repo.commands.test`) from `abs_repo` after the wave completes; on
failure, record a remediation note and surface via `escalation` or `blocked`.

### Completion verification (workspace mode)

After each wave, the lead verifies that each completed task actually produced commits.
Use `lib/worktree-commit-check.sh -C <abs_repo>` to check commit presence over the
repo's `baseSha`:

```bash
abs_repo="${workspace_root}/${repo.path}"
base_sha="${repo.baseSha}"   # from feature.workspace.repos[] entry

if ! bash "${CLAUDE_SKILL_DIR}/../../lib/worktree-commit-check.sh" \
    -C "$abs_repo" "$base_sha" "feat/${slug}"; then
  # No commits over baseSha on feat/{slug} in this repo -- task commit is missing.
  blocked+=("{taskId}:zero-commit")
fi
```

A task is considered committed when `worktree-commit-check.sh -C <abs_repo> <baseSha>
feat/{slug}` exits 0, meaning the commit count over `baseSha` on `feat/{slug}` in that
repo has grown. This replaces the worktree-branch commit check used in single-repo mode.
