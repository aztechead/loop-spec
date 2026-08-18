# EXECUTE subagent path (rungs 1 & 2)

The lightest two rungs of the EXECUTE concurrency ladder (`skills/shared/tier-matrix.md`
-> "EXECUTE concurrency ladder"). Selected by `execute` SKILL Step 3 when the DAG
width `W < t_team`. The lead (the main thread running `execute`) drives the wave loop
itself with one-shot `Agent` dispatches and inline `git` merges. No `TeamCreate`, no
`Workflow`, no `SendMessage`, no harness task list.

All waves also obey `skills/shared/subagent-concurrency.md`.

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
- `worktreesEnabled` — read from the `lib/execute-rung.sh` result **before composing any
  prompt**. It selects the mode below; nothing else does. `false` means no worktree path is
  resolved, no worktree command is composed, and no worktree tool is called — the guard in
  `hooks/team/no-worktrees-guard.sh` is the backstop for a bypass, not the branch point. A
  denied `git worktree add` followed by an in-place retry is the defect this ordering
  removes: it costs a denied tool call and an error line on every headless run.
- `worktree_path` — **worktree mode only; resolved per task, never hard-coded.** Compute it
  once and substitute the same absolute value into the implementer prompt, the reviewer
  prompt, and the integration call:

  ```bash
  worktree_path="$(bash "${CLAUDE_SKILL_DIR}/../../lib/worktree-base.sh" \
    resolve "$featureWorktreeRoot" task "{slug}/task-{taskId}" | jq -r '.path')"
  ```

  The resolver keeps the historical `{featureWorktreeRoot}/.loop-spec/worktrees/{slug}/task-{taskId}`
  location whenever that base can hold a checkout, and moves the worktree outside the
  repository when it cannot — a sandboxed harness that denies harness-config paths
  (`.claude/commands/**`) inside the repo makes an in-repo checkout impossible — or when
  the operator sets `LOOP_SPEC_WORKTREE_DIR`.
- `models.implementer`, `models.specComplianceReviewer` — read for each Agent
  call; add `model` only for an alias and omit it for `inherit`.
- `commands.prepare` — from `feature.json.commands`. Repository-wide
  `lint`/`test`/`typecheck` run once at VERIFY, not on this rung.

## In-place single-repository mode

When the rung result has `worktreesEnabled == false`, retain the one-shot Agent
boundary but serialize every task on the checked-out `feat/{slug}` branch. This is the
`LOOP_SPEC_WORKTREES=0` mode: it protects the lead's context without paying for task
worktrees or allowing concurrent writers.

Select this mode BEFORE resolving a worktree path or composing a prompt. The worktree
steps of the template below (Step 1, Step 1.5, Step 5, and the reviewer's
`git -C "{worktree_path}"` diff) do not apply here and are never emitted — not attempted
and fallen back from.

Apply these replacements to the lead wave loop:

1. Force every wave to one ready task. Before dispatch, require the feature root to be
   clean, on `feat/{slug}`, and record `taskBaseSha="$(git rev-parse HEAD)"`.
2. The implementer prompt keeps the same brief, constraints, criteria, scope, and
   verification requirements, but targets the absolute `featureWorktreeRoot` directly.
   It must not create a worktree, branch, or commit. It edits only `task.files`, runs
   `task.verifyCommand`, and returns `{taskId, ready, notes}`.
3. Require `git diff --quiet` to be false and reject any changed path outside
   `task.files`. Dispatch the reviewer against the uncommitted diff:
   `git -C "{featureWorktreeRoot}" diff -- {task.files}`. Rework agents edit the same
   working tree serially; no other task starts while it is dirty.
   4. On reviewer `pass`, the lead reruns `task.verifyCommand`, stages exactly
   `task.files`, and commits `feat: NO_JIRA {task.subject}`. Verify that HEAD advanced
   from `taskBaseSha` and the checkout is clean, then add the task to `mergedSet` and
   persist `bash "${CLAUDE_SKILL_DIR}/../../lib/task-progress.sh" mark-done ".loop-spec/features/${slug}/tasks.json" "{taskId}"`.
   There is no `integrate-task.sh` call because the accepted commit is already on the
   feature branch.
5. On `block`, retry exhaustion, out-of-scope dirt, verification failure, missing
   commit, or an unreadable Git state, stop with the existing structured blocked or
   escalation reason. Preserve the working tree for diagnosis; never reset or clean it.
6. Each task runs its own `verifyCommand` before publication. The repository-wide
   test/lint/typecheck comparison is NOT run here: it runs exactly once per cycle, at
   VERIFY Step 1.75, against the fully integrated candidate.

The direct implementer prompt keeps every non-worktree step of the template below and
replaces its Steps 1, 1.5, 3, and 5 with:

```text
Repository root: {featureWorktreeRoot}
Branch: feat/{slug} (already checked out)

Do not create a branch, worktree, commit, or push. Edit only {task.files} directly
under the repository root, run {task.verifyCommand}, and leave the verified diff for
the lead and a fresh reviewer agent. Return:
{ taskId: "{taskId}", ready: <true|false>, notes: "<notes>" }
```

The reviewer reads the uncommitted diff at the repository root
(`git -C "{featureWorktreeRoot}" diff -- {task.files}`) instead of a task branch.

All reasoning, simplicity, design-for-change, evidence, and acceptance-criteria text
from the normal prompt remains mandatory.

## Lead wave loop

`mergedSet` is seeded in execute SKILL Step 2a from `task-progress.sh done`. If this
protocol is entered directly, seed it the same way before the loop. Maintain `mergedSet`
(task ids merged onto `feat/{slug}`) and `blocked[]`. Repeat:

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
   On this Agent rung, add `model` only when the result is one of the four
   aliases and omit it for `inherit`. A full/native ID requires the loop-fleet
   rung; fail loud if it reaches this Agent boundary.
   Each call returns `{taskId, branch, committed, sha, notes}`. (Per-task model override applies to the subagent and loop rungs; the team rung pre-spawns implementer teammates and uses the role default for all of them.)
5. **Review each committed task** (`reviewersEnabled` is fixed true). For each implementer result with `committed == true`, dispatch a
   spec-compliance reviewer `Agent` using the activated
   `models.specComplianceReviewer` selector (alias → add `model`; `inherit` → omit) and the
   review prompt below. It returns `{verdict: "pass"|"rework"|"block", findings[]}`.
   - `pass`: the task is ready to merge.
   - `rework` and attempts remaining (`attempt + 1 < maxRetriesPerTask`): re-dispatch the
     implementer with `findings` fed into the prompt; re-review. Loop up to
     `maxRetriesPerTask` attempts.
   - `rework` with attempts exhausted: `blocked.push({taskId, reason: "retry-exhausted"})`.
   - `block`: `blocked.push({taskId, reason: "spec-compliance-block"})`.
   - implementer `committed == false`: `blocked.push({taskId, reason: "commit-missing"})`.
6. **Integrate the passed tasks** (inline, serial, in `wave` order). For each task
   that reached `pass`, use the transactional helper. It checks for commits and
   clean worktrees, rebases a divergent task once, verifies the exact prospective
   candidate, fast-forwards the feature branch only after all checks pass, and
   cleans up only after publication:

   ```bash
   worktree_branch="task/{taskId}-{slug}"
   worktree_path="$(bash "${CLAUDE_SKILL_DIR}/../../lib/worktree-base.sh" \
     resolve "$featureWorktreeRoot" task "{slug}/task-{taskId}" | jq -r '.path')"

   integration_json=$(bash "${CLAUDE_SKILL_DIR}/../../lib/integrate-task.sh" \
     --feature-root "$featureWorktreeRoot" \
     --feature-branch "feat/{slug}" \
     --task-worktree "$worktree_path" \
     --task-branch "$worktree_branch" \
   --verify "{task.verifyCommand}" \
     --cleanup)
   integration_rc=$?
   ```

   Parse `integration_json`, never command prose. If `.published == true`, add the
   task id to `mergedSet` even when cleanup reports a failure, then persist:

   ```bash
   bash "${CLAUDE_SKILL_DIR}/../../lib/task-progress.sh" mark-done \
     ".loop-spec/features/${slug}/tasks.json" "{taskId}"
   ```

   Otherwise map
   `zero-commit` to the existing `zero-commit` blocked reason, `verify-failed` or
   `prepare-failed` to `retry-exhausted`, and any rebase/publication/cleanliness
   failure to `escalation.reason = "rebase-conflict"` with the helper's `reason`
   and `detail`, then stop. Never remove or reset a failed task worktree manually.
   The helper runs `verifyCommand` after any required rebase and before publication,
   so each task's focused proof covers exactly the commit that fast-forwards the feature
   branch. It deliberately does not run the repository-wide suite here.
7. Loop back to step 1. EXECUTE runs no repository-wide suite of its own: every task's
   focused `verifyCommand` runs after any rebase and before publication, and the
   test/lint/typecheck comparison runs exactly once per cycle, at VERIFY Step 1.75,
   against the fully integrated candidate.

## Agent dispatch convention

Dispatch every implementer and reviewer with the **default** agent (do NOT pass
`subagent_type`), exactly as `lib/workflows/execute-dag.js` does. The prompts below are
self-contained -- they carry the worktree, implement, verify, commit, and review
instructions in full. The template below is the WORKTREE-mode prompt; with
`worktreesEnabled == false` compose the in-place prompt from "In-place single-repository
mode" above instead. Do NOT pass `subagent_type: "loop-spec:implementer"`: that agent
declares `isolation: worktree` in its frontmatter, which would create a second worktree
on top of the explicit `git worktree add` in the prompt. Read the role selector
from `models.implementer` or `models.specComplianceReviewer`; add the Agent
`model` field only for an alias and omit it for `inherit`.

**Dispatch telemetry (`skills/shared/dispatch-events.md`):** emit one `dispatch` event per implementer/reviewer Agent call — `bash "${CLAUDE_SKILL_DIR}/../../lib/events.sh" emit ".loop-spec/features/${slug}" dispatch --phase "execute" --data '{"role":"<implementer|spec-compliance-reviewer>","model":"<resolved selector>","rung":"subagent"}' || true`. Retries of the same task are new launches and DO re-emit.

**Task progress (required).** EXECUTE is the longest phase; without this it reports
only `[EXECUTE] start` and an operator watching a streamed log cannot tell task 1 of 6
from task 5 of 6, or steady progress from a stall. Emit one `task_start` before
dispatching each task and one `task_end` after its merge/failure is decided:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/events.sh" emit ".loop-spec/features/${slug}" \
  task_start --phase execute \
  --data '{"index":<1-based position>,"total":<total tasks in the DAG>,"id":"<task id>","subject":"<task subject>"}' || true
# ... dispatch, verify, merge ...
bash "${CLAUDE_SKILL_DIR}/../../lib/events.sh" emit ".loop-spec/features/${slug}" \
  task_end --phase execute \
  --data '{"index":<same>,"total":<same>,"id":"<task id>","result":"<merged|failed|skipped>"}' || true
```

`total` is the task count for the whole DAG, not the current wave, so the ratio
advances monotonically across waves. In a parallel wave emit every `task_start` as the
wave launches; `index` is the task's position in the DAG order. `lib/events.sh` renders
these as `[EXECUTE] task 2/5 start - task-002: <subject>`. Retries re-emit.

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
(2) DRY — already in this codebase? reuse the existing helper/util/type/pattern, do not
re-implement it; (3) stdlib does it? use it; (4) native platform feature covers it? use it;
(5) an already-installed dependency solves it? use it, never add a new one for what a few
lines do; (6) can it be one line? one line; (7) only then, the minimum code that works. The
ladder runs AFTER you understand the problem. Bug fix = root cause, not symptom. NEVER cut
input validation at trust boundaries, error handling that prevents data loss, security,
accessibility, or anything the spec requires. Non-trivial logic leaves ONE runnable check
behind. Mark deliberate shortcuts with a `simplicity:` comment naming the ceiling.

Rung 1 is measured too: the layer nobody needed always looks justified while you write it.
Before DONE run `bash "${CLAUDE_SKILL_DIR}/../../lib/indirection-scan.sh" scan <files you
touched>` — it names each small private helper you added that is called exactly once. Inline
it, or say why the name earns its hop. It stays silent on a long function with one caller
(decomposition), on exported symbols, and on dead code.

Rung 2 is measured, not recalled: you cannot find a helper in a file you never opened, so
before reporting DONE run `bash "${CLAUDE_SKILL_DIR}/../../lib/duplication-scan.sh" scan
<files you touched>`. It names each block you duplicated and the file that block already
lives in: `duplicate=` for the same lines, `similar=` for the same lines with every name
changed — the latter is what writing one module beside a similar one actually produces, so
it counts the same. Resolve every finding — call the existing thing, or lift the shared part
into one place both callers use. Never leave a second copy that drifts. The one exception is a
coincidental resemblance (two blocks that look alike but change for different reasons);
say so once in your report rather than merging them, because that merge is a coupling bug.

DESIGN FOR CHANGE (seams, not speculation — on by default). Design to the task's stated
interface, not an implementation detail; one unit, one reason to change. New units receive
their collaborators (params/args/env), never construct them deep inside. Never cut a seam
to save lines, and never build speculation behind one (YAGNI cuts artifacts, not seams).
Bug-fix tasks: after the root cause is fixed, sweep callers, copy-pasted patterns, and
parallel paths for the same mechanism; fix same-cause siblings within the task's files
scope, report the rest.

CODE FOR HUMANS (house style over habit — on by default). Code is read far more than it
is written; your diff must read like the code around it. Read the neighbors of every file
in the task's files list FIRST and match them: naming, error idiom, test structure, file
layout, import order. The house convention outranks your defaults even where you would
have chosen differently — disagreeing with it is a self-review finding, never a licence to
deviate. Where the convention is unclear, measure it: `bash "${CLAUDE_SKILL_DIR}/../../lib/house-style.sh" probe
<files>` reports comment density, doc-comment usage, indentation, and naming case from the
actual neighbors. Before DONE, check your own work with `bash
"${CLAUDE_SKILL_DIR}/../../lib/house-style.sh" compare <files you touched>`: it holds each
file out of its own baseline and names where it deviates from its same-language neighbors
(indent, naming, quotes, semicolons, module system). `probe` pools your file into the
sample, so it can never show you a deviation — only `compare` can.
Comments carry WHY, never what: a constraint not visible locally, a
decision and the alternative it beat, a workaround and its reason. Never narrate the code,
restate a signature, announce the edit ("Added...", "Updated..."), or narrate history
("previously...", "renamed from...") — `bash "${CLAUDE_SKILL_DIR}/../../lib/comment-tells.sh" scan <files>` catches
those three before you report DONE. Comment DENSITY matches the file, not an absolute: no
docstrings added to a module that has none. A good name deletes a comment. No drive-by
reformatting or renames that bury the change. NEVER cut `simplicity:` markers, file-header
purpose blocks where the codebase uses them, TODO/FIXME/NOTE/HACK/SAFETY markers, or any
comment encoding a non-obvious why.

CODE A HUMAN CAN OPERATE (the failure path — on by default). When this code breaks at 03:00 the person on call has only what it said. Never swallow an error — a handler that catches and does nothing erases the one record of what happened; log it, re-raise it, or state why the failure is uninteresting (a narrow exception type states it for you, `except Exception: pass` states nothing). An error message names what broke and, where you know it, the next move: which file, which field, which limit — "invalid input" is not something a person can act on. Never exit non-zero in silence: say why on stderr first, or leave the failing command to speak. Before DONE run `bash "${CLAUDE_SKILL_DIR}/../../lib"/failure-tells.sh scan <files you touched>`: it flags a handler that does nothing, a non-zero exit with nothing said, and a message whose every word is a synonym for "it broke". 

DOCS FOR HUMANS (the markdown is a deliverable too — on by default). A person maintains and operates every document you write, long after this run ends. Name its reader in the first line — someone about to CHANGE this system, or someone about to RUN it — and hold one job per document: a how-to gets a task done, a reference states facts, an explanation says why; blending them serves neither reader. A procedure states its prerequisites, then the exact copy-pasteable command, then what success looks like, then what to do when the step fails. Cite, never copy: point at `file:line` instead of restating what the code says — stale prose is worse than none, because it is wrong with authority. If your change makes a document false (README, help text, runbook, config table), fix it IN THIS DIFF; a follow-up documentation task is deferred scope. Ground every claim: never write what the code probably does. Prefer one page the project will keep true over five that decay, and never invent a documentation convention this repository does not already have. Before DONE run `bash "${CLAUDE_SKILL_DIR}/../../lib"/doc-tells.sh scan <the markdown you touched>`: it flags a relative link with no target, an inline-code path the tree no longer holds, and a command holding a placeholder your prose never explains. NEVER cut frontmatter, machine-read contract sections, required artifact headings, EVID citation lines, or license blocks. Full reference: `skills/shared/human-docs.md`.

EXECUTION DISCIPLINE (evidence over recall — on by default). You execute a brief a
stronger reasoning pass produced; your job is fidelity, not improvisation. Verify, don't
recall: never assert what a file/command/API does from memory — read it, run it, paste
the actual output. Surprise is signal: output contradicting your expectation is
information — stop, re-read, revise; never explain it away. Re-read the acceptance
criteria before DONE and check each against actual output. Depth over breadth: read the
load-bearing file completely instead of skimming five. "Should work" / "probably fine" /
"tests likely pass" each mean run it now. Scope is closed: the acceptance criteria are
the whole job — never skip, trim, or defer an item, and never write
follow-up/deferred/future-work notes; a criterion you cannot meet is a loud failure
with evidence, never a note.

Step 1 - Create the task worktree (worktree mode only; skip if it already exists):
  git -C "{featureWorktreeRoot}" worktree add "{worktree_path}" -b "task/{taskId}-{slug}" "feat/{slug}"

Step 1.5 - Prepare declared dev/test dependencies inside the task worktree:
  bash "${CLAUDE_SKILL_DIR}/../../lib/prepare-environment.sh" run --root "{worktree_path}" --command "{commands.prepare}" --reuse-from "{featureWorktreeRoot}"
Preparation failure is infrastructure failure; do not edit around it.

Step 2 - {readFirst clause} Read the assigned files: {task.files}.
{specPath clause}

Step 3 - Implement the task in the worktree at {worktree_path}.
Task subject: {task.subject}
Brief: {task.brief}
Global constraints (from PLAN.md "## Global constraints", verbatim; every one binds):
{global constraints lines, or "- none"}
Interfaces (from the task block; contracts your neighbors consume/produce):
{task Interfaces lines, or "- none"}
Acceptance criteria:
{numbered acceptanceCriteria}
{prior-findings clause on rework attempts}

Touch ONLY the files listed ({task.files}). Do NOT edit unrelated files.

Step 4 - Run the task's feature-specific verify command inside the worktree:
  {task.verifyCommand}
The integration helper reruns this focused command after any required rebase. This is the
only command EXECUTE runs; the repository-wide no-new-failures comparison happens once per
cycle, at VERIFY.

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
speculative = skip (YAGNI); (2) DRY — already in this codebase? reuse it; (3) stdlib does
it? use it; (4) native platform feature? use it; (5) installed dependency solves it? use it,
add no new one for what a few lines do; (6) one line? one line; (7) only then the minimum
that works. Ladder runs AFTER understanding the problem; bug fix = root cause not symptom.
NEVER cut validation at trust boundaries, data-loss error handling, security, accessibility,
or anything the spec requires. Non-trivial logic leaves ONE runnable check behind.
Rung 1 is measured too: `bash "${CLAUDE_SKILL_DIR}/../../lib/indirection-scan.sh" scan <files you touched>`
names each small private helper called exactly once; inline it or justify the hop.
Rung 2 is measured: before DONE run `bash "${CLAUDE_SKILL_DIR}/../../lib/duplication-scan.sh"
scan <files you touched>` — it names each duplicated block and the file it already lives in
(`duplicate=` same lines, `similar=` same lines with every name changed; both count).
Call the existing thing or lift the shared part out; never leave a second copy that drifts.
A coincidental resemblance is the one exception — report it rather than merging it.

DESIGN FOR CHANGE (seams, not speculation — on by default). Design to the task's stated
interface; one unit, one reason to change; new units receive collaborators (params/args/env),
never construct them deep inside. Never cut a seam to save lines, never build speculation
behind one. Bug-fix tasks: sweep for the same mechanism (callers, copies, parallel paths)
and fix same-cause siblings in scope; report the rest.

CODE FOR HUMANS (house style over habit — on by default). Your diff must read like the
code around it. Read the neighbors of every file in the task's files list FIRST and match
them: naming, error idiom, test structure, layout, import order. The house convention
outranks your defaults; disagreeing with it is a self-review finding, never a licence to
deviate. Measure rather than guess: `bash "${CLAUDE_SKILL_DIR}/../../lib/house-style.sh" probe <files>`, and before
DONE run `bash "${CLAUDE_SKILL_DIR}/../../lib/house-style.sh" compare <files you touched>` — it holds each file out of
its own baseline and names where it deviates from its same-language neighbors; `probe` pools your file in and cannot. Comments carry
WHY, never what. Never narrate the code, announce the edit ("Added...", "Updated..."), or
narrate history ("previously...") — `bash "${CLAUDE_SKILL_DIR}/../../lib/comment-tells.sh" scan <files>` catches those
three. Comment DENSITY matches the file, not an absolute. A good name deletes a comment.
No drive-by reformatting or renames that bury the change. NEVER cut `simplicity:` markers,
file-header purpose blocks the codebase uses, TODO/FIXME/NOTE/HACK/SAFETY markers, or any
comment encoding a non-obvious why.

CODE A HUMAN CAN OPERATE (the failure path — on by default). When this code breaks at 03:00 the person on call has only what it said. Never swallow an error — a handler that catches and does nothing erases the one record of what happened; log it, re-raise it, or state why the failure is uninteresting (a narrow exception type states it for you, `except Exception: pass` states nothing). An error message names what broke and, where you know it, the next move: which file, which field, which limit — "invalid input" is not something a person can act on. Never exit non-zero in silence: say why on stderr first, or leave the failing command to speak. Before DONE run `bash "${CLAUDE_SKILL_DIR}/../../lib"/failure-tells.sh scan <files you touched>`: it flags a handler that does nothing, a non-zero exit with nothing said, and a message whose every word is a synonym for "it broke". 

DOCS FOR HUMANS (the markdown is a deliverable too — on by default). A person maintains and operates every document you write, long after this run ends. Name its reader in the first line — someone about to CHANGE this system, or someone about to RUN it — and hold one job per document: a how-to gets a task done, a reference states facts, an explanation says why; blending them serves neither reader. A procedure states its prerequisites, then the exact copy-pasteable command, then what success looks like, then what to do when the step fails. Cite, never copy: point at `file:line` instead of restating what the code says — stale prose is worse than none, because it is wrong with authority. If your change makes a document false (README, help text, runbook, config table), fix it IN THIS DIFF; a follow-up documentation task is deferred scope. Ground every claim: never write what the code probably does. Prefer one page the project will keep true over five that decay, and never invent a documentation convention this repository does not already have. Before DONE run `bash "${CLAUDE_SKILL_DIR}/../../lib"/doc-tells.sh scan <the markdown you touched>`: it flags a relative link with no target, an inline-code path the tree no longer holds, and a command holding a placeholder your prose never explains. NEVER cut frontmatter, machine-read contract sections, required artifact headings, EVID citation lines, or license blocks. Full reference: `skills/shared/human-docs.md`.

EXECUTION DISCIPLINE (evidence over recall — on by default). Verify, don't recall: never
assert what a file/command does from memory — read it, run it, paste the actual output.
Surprise is signal: output contradicting expectation means stop and revise, never explain
away. Re-read the acceptance criteria before DONE and check each against actual output.
"Should work" / "probably fine" / "tests likely pass" each mean run it now. Scope is
closed: the acceptance criteria are the whole job — never skip, trim, or defer an item,
and never write follow-up/deferred/future-work notes; a criterion you cannot meet is a
loud failure with evidence, never a note.

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
Global constraints (from PLAN.md "## Global constraints", verbatim; every one binds):
{global constraints lines, or "- none"}
Interfaces (from the task block; contracts your neighbors consume/produce):
{task Interfaces lines, or "- none"}
Acceptance criteria:
{numbered acceptanceCriteria}
{prior-findings clause on rework attempts}

Touch ONLY the files listed ({task.files}). Do NOT edit unrelated files.
Do NOT create a git worktree. Edit files directly in {abs_repo}.

Step 3 - Prepare dependencies, then run the task-specific verify command with cwd = {abs_repo}:
  bash "${CLAUDE_SKILL_DIR}/../../lib/prepare-environment.sh" run --root "{abs_repo}" --command "{repo.commands.prepare}"
  {task.verifyCommand}

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

No post-wave suite gate runs here either. The repository-wide comparison across every
participating repo happens once, at VERIFY Step 1.75.

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
