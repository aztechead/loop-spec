# EXECUTE subagent path (rungs 1 & 2)

The lightest two rungs of the EXECUTE concurrency ladder (`skills/shared/tier-matrix.md`
-> "EXECUTE concurrency ladder"). Selected by `execute` SKILL Step 3 when the DAG
width `W < t_team`. The lead (the main thread running `execute`) drives the wave loop
itself with one-shot `Agent` dispatches and inline `git` merges. No `TeamCreate`, no
`Workflow`, no `SendMessage`, no harness task list.

All waves also obey `skills/shared/subagent-concurrency.md`.

Contents: when this path runs · inputs · in-place single-repository mode · lead wave
loop · agent dispatch convention · implementer contract stanza · implementer Agent
prompt · reviewer Agent prompt · workspace mode (wave construction, implementer
prompts, merge/ff, completion verification).

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
- `maxParallelImplementers` (3), `maxRetriesPerTask` (effective cap from execute Step 3; default 6), `reviewersEnabled` (true) — `skills/shared/tier-matrix.md`. At the default cap: one initial attempt plus five fix rounds; `lib/fix-loop.sh max` prints 6 (the default first attempt index that trips the breaker). Pass the effective cap into `fix-loop.sh action`, not that default.
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
- `subagentIsolation` — read from the same `execute-rung.sh` result. `lead-worktree` means
  the **lead** creates each task worktree before any Agent call; `none` means in-place
  (no isolation). One-shot Agents share the session cwd and cannot isolate themselves,
  even when `LOOP_SPEC_WORKTREES=1`. Collision-safety is therefore this lead-created
  worktree (plus the lead's file partitioning), not a hope that parallel subagents will
  each `git worktree add`. Wave width > 1 is allowed only when every member of the wave
  has a created worktree. Raising `maxParallelImplementers` (caps → 3 and beyond) is
  gated on this remaining true.
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
6. Each task runs its own `verifyCommand` before publication; the repository-wide
   comparison is NOT run here (wave-loop step 7 owns that invariant).

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

The reviewer reads the review package for the uncommitted range when one exists;
otherwise `git -C "{featureWorktreeRoot}" diff -- {task.files}`.

All reasoning, simplicity, design-for-change, evidence, and acceptance-criteria text
from the normal prompt remains mandatory.

## Lead wave loop

`mergedSet` is seeded in execute SKILL Step 2a from `task-progress.sh done`. If this
protocol is entered directly, seed it the same way before the loop. Maintain `mergedSet`
(task ids merged onto `feat/{slug}`) and `blocked[]`. Repeat:

1. **Compute the remaining set:** `remaining = tasks - mergedSet - {b.taskId for b in blocked}`. If empty, exit the loop (success).
2. **Compute the ready set:** `ready = [t in remaining if every dep in t.blockedBy is in mergedSet]`.
   - If `ready` is empty while `remaining` is non-empty: set `escalation = {reason: "deadlock", detail: "unmergeable dependency cycle or all remaining blocked"}` and exit.
3. **Form the wave:** `wave = ready[:maxParallelImplementers]`. Collapse same-shape
   members first: `bash "${CLAUDE_SKILL_DIR}/../../lib/task-batch.sh" collapse
   ".loop-spec/features/${slug}/tasks.json"` — a `batchGroup` with matching
   verifyCommand and no cross-group `blockedBy` becomes one dispatch whose
   `files[]` is the union. Fail-closed: no hint, or an outside task waiting on a
   member the collapse would erase, means one-task-one-dispatch.
3.5 **Isolate the wave (worktree mode only).** One-shot Agents share the lead's cwd;
    they do not get a harness worktree. When `subagentIsolation == "lead-worktree"`,
    the lead creates each task worktree **before** any Agent call:

    ```bash
    worktree_path="$(bash "${CLAUDE_SKILL_DIR}/../../lib/worktree-base.sh" \
      resolve "$featureWorktreeRoot" task "{slug}/task-{taskId}" | jq -r '.path')"
    git -C "$featureWorktreeRoot" worktree add "$worktree_path" \
      -b "task/{taskId}-{slug}" "feat/{slug}"
    ```

    A failed add drops that task from this wave (it stays ready). If the wave would
    be empty, dispatch **one** remaining ready task in-place on `feat/{slug}` —
    never overlap writers in the feature root. Wave width > 1 is allowed only when
    every member of the wave has a created worktree. Do not raise
    `maxParallelImplementers` above this isolation.
4. **Dispatch the wave.** For each `taskId` in `wave`, write the file handoff
   then issue an implementer `Agent` call. Record `taskBaseSha` before dispatch
   (`git rev-parse HEAD` in the task worktree, or the feature HEAD in in-place
   mode) — review packages must use that SHA, never `HEAD~1`.

   ```bash
   fdir=".loop-spec/features/${slug}"
   brief="$(bash "${CLAUDE_SKILL_DIR}/../../lib/dispatch-files.sh" brief \
     --feature-dir "$fdir" --task-id "{taskId}")"
   report="$(bash "${CLAUDE_SKILL_DIR}/../../lib/dispatch-files.sh" report-path \
     --feature-dir "$fdir" --task-id "{taskId}")"
   ```

   The dispatch prompt carries those paths plus a one-line fit. Exact values live
   only in the brief. On rung 2 emit all wave calls in ONE assistant message so they run in
   parallel; on rung 1 the wave has one task. Use the prompt template below.
   **Per-task model resolution** (cheapest model that fits, in priority order):
   1. a concrete `metadata.model` pin on the task, else
   2. `bash "${CLAUDE_SKILL_DIR}/../../lib/model-tier.sh" model "$(task.metadata.modelTier)"` when the task carries a `modelTier`, else
   3. `models.implementer` (the role default).
   On this Agent rung, add `model` only when the result is one of the four
   aliases and omit it for `inherit`. A full/native ID requires the loop-fleet
   rung; fail loud if it reaches this Agent boundary.
   Issue the Agent call(s), then stop. Never AskUserQuestion as a wait
   (`skills/shared/harness-call-contracts.md`). The harness resumes this turn
   when they complete. Then review.
   Each call returns `{taskId, branch, committed, sha, notes}`. (Per-task model override applies to the subagent and loop rungs; the team rung pre-spawns implementer teammates and uses the role default for all of them.)
5. **Review each committed task** (`reviewersEnabled` is fixed true). For each implementer result with `committed == true`, write a review package from the recorded BASE to the implementer's HEAD, then dispatch a spec-compliance reviewer `Agent` using the activated
   `models.specComplianceReviewer` selector (alias → add `model`; `inherit` → omit) and the
   review prompt below. It returns `{verdict: "pass"|"rework"|"block", findings[], unverified[]}`.
   - Resolve every `unverified[]` item before marking the task complete: confirm from
     the plan / prior tasks (ledger a note) or promote to `rework`. Unverified items
     must not evaporate.
   - `pass` with empty unresolved unverified: the task is ready to merge.
   - `rework` and attempts remaining: run `bash "${CLAUDE_SKILL_DIR}/../../lib/fix-loop.sh" action "{attempt}" "{maxRetriesPerTask}"`
     (pass the effective cap so a tuned `executeMaxRetriesPerTask` moves the breaker with it).
     `resume` on a live teammate (`fix-loop.sh live team` → `resumeable`) is
     `SendMessage` to that identity with the findings. `oneshot` rungs re-dispatch
     a fresh Agent that must read the report file. `fresh-upgrade` re-dispatches
     on `bash "${CLAUDE_SKILL_DIR}/../../lib/model-tier.sh" upgrade "{current}"`.
     `breaker` stops: park residuals in `warnings[]` and
     `blocked.push({taskId, reason: "retry-exhausted"})`.
     Re-review is scoped (`skills/shared/review-prompts/re-review.md`) against
     `FIX_BASE..HEAD`, not a full-task re-read.
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
   branch.
7. Loop back to step 1. EXECUTE runs no repository-wide suite of its own: every task's
   focused `verifyCommand` runs after any rebase and before publication, and the
   test/lint/typecheck comparison runs exactly once per cycle, at VERIFY Step 1.75,
   against the fully integrated candidate.

## Agent dispatch convention

Dispatch every implementer and reviewer with the **default** agent (do NOT pass
`subagent_type`), exactly as `lib/workflows/execute-dag.js` does. The prompts below are
self-contained -- they carry the implement, verify, commit, and review
instructions in full. The template below is the WORKTREE-mode prompt; with
`worktreesEnabled == false` compose the in-place prompt from "In-place single-repository
mode" above instead. Do NOT pass `subagent_type: "loop-spec:implementer"`: this path
uses the default Agent with a self-contained prompt, and the lead already created
the task worktree. Read the role selector
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

## Implementer contract stanza (open EVERY implementer prompt with this, verbatim)

This dispatch uses the DEFAULT agent (not loop-spec:implementer), so the agent definition's
directives do NOT apply here and a SessionStart hook does not reach this subagent.
The stanza therefore names each contract and the resolved probes (canonical sources under
`skills/shared/`) so EXECUTE follows them on this rung every time — the agent reads the
files; it does not paste them. Both prompt templates below (worktree and workspace) open
with this block after their first line; the stanza is written once here so the two
templates cannot drift.

```
IMPORTANT: All paths must be ABSOLUTE. Do not use relative paths. Do not use em-dashes.

FOUR QUESTIONS (design gate — on by default). Before implementing and again before DONE,
ask of the change: can I make it more modular? can I make it more extensible? is this the
least amount of code that makes it happen? does this hold at production scale (memory and
work bounded against deployment-sized input, not the fixture)? Full contract:
`${CLAUDE_SKILL_DIR}/../../skills/shared/implementer-contract.md`.

SIMPLICITY (ponytail laziness ladder — on by default). Read
`${CLAUDE_SKILL_DIR}/../../skills/shared/laziness-ladder.md` before writing code — do not
paste it. YAGNI, then DRY: reuse what is already here. Before DONE run
`bash "${CLAUDE_SKILL_DIR}/../../lib/indirection-scan.sh" scan <files you touched>` and
`bash "${CLAUDE_SKILL_DIR}/../../lib/duplication-scan.sh" scan <files you touched>` (`duplicate=` same lines, `similar=` names-changed; both count).

DESIGN FOR CHANGE (seams, not speculation — on by default). Read
`${CLAUDE_SKILL_DIR}/../../skills/shared/design-for-change.md` — do not paste it.

CODE FOR HUMANS (house style over habit — on by default). Read
`${CLAUDE_SKILL_DIR}/../../skills/shared/human-code.md` before writing code — do not paste
it. Read the neighbors. Comments carry WHY, never what. Density matches the file. NEVER cut
`simplicity:` markers. Before DONE: `bash "${CLAUDE_SKILL_DIR}/../../lib/house-style.sh" probe
<files>`; `bash "${CLAUDE_SKILL_DIR}/../../lib/house-style.sh" compare <files you touched>`;
`bash "${CLAUDE_SKILL_DIR}/../../lib/comment-tells.sh" scan <files>`.

CODE A HUMAN CAN OPERATE (the failure path — on by default). Fail loudly, or say why you did
not. Before DONE run `bash "${CLAUDE_SKILL_DIR}/../../lib/failure-tells.sh" scan <files you
touched>`.

DOCS FOR HUMANS (the markdown is a deliverable too — on by default). Read
`${CLAUDE_SKILL_DIR}/../../skills/shared/human-docs.md` — do not paste it. One job per
document. Cite, never copy. If your change makes a document false, fix it IN THIS DIFF; a
follow-up documentation task is deferred scope. Before DONE run
`bash "${CLAUDE_SKILL_DIR}/../../lib/doc-tells.sh" scan <the markdown you touched>`. NEVER
cut frontmatter, machine-read contract sections, required artifact headings, EVID citation
lines, or license blocks.

WRITING GOOD TESTS. Read `${CLAUDE_SKILL_DIR}/../../skills/shared/writing-good-tests.md`
before adding or changing a test — do not paste it. Name the break; no string-presence
traps; no change detectors.

TDD (red then green). Code-producing tasks: write the failing test FIRST, run it,
confirm red, then implement, confirm green. Skill/config/docs tasks are excluded.
Omitting a TDD label does not exempt this step.

NO NESTED SUBAGENTS. Do this task yourself. Never dispatch a helper or a reviewer.
Review arrives from the lead after your report.

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
```

## Implementer Agent prompt (per task, per attempt)

Substitute the runtime values. This mirrors the implementer contract in
`lib/workflows/execute-dag.js` so behavior is identical across rungs.

```
You are an implementer agent for task {taskId}.

[implementer contract stanza — insert the block above, verbatim]

Step 1 - The task worktree already exists at {worktree_path} on branch
  task/{taskId}-{slug}. Do not run `git worktree add`. If the path is missing,
  fail loudly; do not create a worktree and do not edit the feature root.
  All git and file operations use that directory (`git -C "{worktree_path}"`).

Step 1.5 - Prepare declared dev/test dependencies inside the task worktree:
  bash "${CLAUDE_SKILL_DIR}/../../lib/prepare-environment.sh" run --root "{worktree_path}" --command "{commands.prepare}" --reuse-from "{featureWorktreeRoot}"
Preparation failure is infrastructure failure; do not edit around it.

Step 2 - {readFirst clause} Read the assigned files: {task.files}.
{specPath clause}

Step 3 - Implement the task in the worktree at {worktree_path}.
Task subject: {task.subject}
Read this first — it is your requirements, with the exact values to use verbatim:
  {brief path from dispatch-files.sh}
Write your full report (status, commits, test command, output, concerns) to:
  {report path from dispatch-files.sh}
Return only JSON plus a one-line test summary. Exact values live in the brief; do not
ask the lead to paste them.
Global constraints (from PLAN.md "## Global constraints", verbatim; every one binds):
{global constraints lines, or "- none"}
Interfaces (from the task block; contracts your neighbors consume/produce):
{task Interfaces lines, or "- none"}
Acceptance criteria are in the brief.
{prior-findings clause on rework attempts; on resume/oneshot rework, read the report file first}

Touch ONLY the files listed ({task.files}). Do NOT edit unrelated files.

Step 4 - Run the task's feature-specific verify command inside the worktree:
  {task.verifyCommand}
The integration helper reruns this focused command after any required rebase. This is
the only command EXECUTE runs.

Step 5 - Stage and commit inside the worktree branch:
  git -C "{worktree_path}" add <files>
  git -C "{worktree_path}" commit -m "feat: NO_JIRA {task.subject}"
Do NOT push. Do NOT run git outside the task worktree.

Return JSON: { taskId: "{taskId}", branch: "task/{taskId}-{slug}", committed: <true|false>, sha: "<sha or empty>", notes: "<notes>" }
```

## Reviewer Agent prompt

Include `skills/shared/review-prompts/no-prejudge.md` (do not paste). A scoped
re-review after a fix round uses `skills/shared/review-prompts/re-review.md`
with FIX_BASE = the HEAD the previous review saw.

```
You are a spec-compliance reviewer for task {taskId} (attempt {n}).

NO NESTED SUBAGENTS. Do this review yourself. Never spawn a helper or a second reviewer.

Read the task brief: {brief path}
Read the implementer's report: {report path}
Read the review package once (commit list, stat, diff -U10). Do not re-run git for this
range if the file exists:
  {package path from: bash lib/dispatch-files.sh package --repo ... --base {taskBaseSha} --head {implHead}}
If the package is missing, fetch `git diff --stat {taskBaseSha}..{implHead}` and
`git diff -U10 {taskBaseSha}..{implHead}` yourself. Never use HEAD~1 as BASE.

{specPath clause}

Determine whether the implementation satisfies all acceptance criteria and matches the spec.
Do not re-run tests the implementer already ran on the same code; the report carries that
evidence. If the evidence is illegible, say so — do not re-run the suite.

Over-engineering pass (ponytail): scan the diff for
complexity it does not need. Flag each as a rework finding — delete: dead/speculative code;
stdlib: hand-rolled thing the standard library already ships; yagni: abstraction with one
implementation or config nobody sets; shrink: same logic in fewer lines. The
ponytail minimum (a single smoke/assert check, or an accepted `simplicity:`-marked shortcut)
is the floor of this pass, not a finding.

A requirement that lives in unchanged code or spans tasks is not a fail: put it in
unverified[] with why the diff cannot show it. The lead must resolve each item.

Return one of:
  - verdict "pass"   if everything is satisfied AND unverified[] is empty
  - verdict "rework" with specific findings if fixable issues exist (incl. over-engineering)
  - verdict "block"  if the implementation is fundamentally wrong or unrecoverable

Return JSON: { verdict: "pass"|"rework"|"block", findings: ["<finding 1>", ...], unverified: [{"requirement":"...","why":"..."}] }
```

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

Each implementer `Agent` call in workspace mode receives `repo` (the repo name),
`abs_repo` (`{feature.workspace.root}/{repo.path}`, absolute), and `branch`
(`feat/{slug}`, the in-place branch on that repo). The prompt instructs the implementer:

```
You are an implementer agent for task {taskId} in repo '{repo}'.

[implementer contract stanza — insert the block above, verbatim]

Repo: {repo}
Repo path: {abs_repo}   (absolute; all git and file operations target this directory)
Branch: feat/{slug}     (already checked out in this repo; do NOT create a worktree)

Step 1 - Read the assigned files. Files are workspace-relative ({repo}/{path}); resolve
         them as absolute paths under {abs_repo}.
{readFirst clause}
{specPath clause}

Step 2 - Implement the task directly in the repo at {abs_repo}.
Task subject: {task.subject}
Read this first — it is your requirements, with the exact values to use verbatim:
  {brief path from dispatch-files.sh}
Write your full report to:
  {report path from dispatch-files.sh}
Global constraints (from PLAN.md "## Global constraints", verbatim; every one binds):
{global constraints lines, or "- none"}
Interfaces (from the task block; contracts your neighbors consume/produce):
{task Interfaces lines, or "- none"}
Acceptance criteria are in the brief.
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
workspace tasks, and no post-wave suite gate runs here either (wave-loop step 7).

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
