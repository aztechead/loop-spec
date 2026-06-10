---
name: execute
description: EXECUTE phase - concurrency ladder picks dispatch by DAG width W. Rung 1/2 subagent (lead-driven Agent waves), rung 3 agent team (TeamCreate self-claim), rung 4 workflow DAG (execute-dag.js, opt-in only). Loop-fleet rung (bundled loop-runner, headless bounded loops with verifier integrity) replaces the team rung on opt-in or when agent teams are unavailable. Width thresholds in tier-matrix.
allowed-tools: Bash Read Write Edit Glob Grep Skill Agent AskUserQuestion TeamCreate TeamDelete SendMessage TaskCreate TaskUpdate TaskList TaskGet Workflow
---

# EXECUTE Phase

Invoked when `feature.json.currentPhase == "execute"`. Dispatch is chosen by a
**concurrency ladder** keyed on the task DAG width `W` (Step 3): rung 1/2 subagent waves
(`skills/shared/execute-subagent.md`), rung 3 agent team (TeamCreate self-claim, Steps
4-10), rung 4 Workflow DAG (`lib/workflows/execute-dag.js`, opt-in only). Width
thresholds and the rung rule live in `skills/shared/tier-matrix.md`. All three paths
return the same `{merged, blocked, escalation, tier}` result shape.

## Inputs

- `feature_path`: `.loop-spec/features/{slug}/feature.json`
- `plan_path`: `docs/loop-spec/features/{slug}/PLAN.md`
- `branch`: `feature.json.branch` (e.g., `feat/{slug}`)

## Procedure

### Step 1 - Branch check

The behavior differs based on whether `feature.json` has a `worktreePath` field (schema 6) or not (legacy schema <= 5).

**Schema 6 (worktreePath present):** The feature worktree was created at cycle start and the session was switched into it via `EnterWorktree`. The branch `feat/{slug}` is already checked out there. Assert this is the case; do not create the branch in-place:

```bash
current=$(git branch --show-current)
if [[ "$current" != "{feature.json.branch}" ]]; then
  echo "ERROR: expected branch {feature.json.branch} but current branch is '$current'." >&2
  echo "The cycle resume did not EnterWorktree the feature worktree. Aborting." >&2
  exit 2
fi
```

`baseSha` and `baseBranch` were already written by cycle Step 5 (`baseBranch` is the real base, e.g. `main`, used by VERIFY as the PR `--base`). Do not overwrite them here. The per-task ff-merge target is the literal feature branch `feat/{slug}`, never `baseBranch`.

**Legacy (no worktreePath, schema <= 5):** Create the branch from the detected base if not already on it:

```bash
current=$(git branch --show-current)
if [[ "$current" != "{feature.json.branch}" ]]; then
  base=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
  if [[ -z "$base" ]]; then
    for candidate in main master develop trunk; do
      if git show-ref --verify --quiet "refs/heads/$candidate"; then
        base="$candidate"; break
      fi
    done
  fi
  [[ -z "$base" ]] && { echo "ERROR: cannot determine base branch"; exit 2; }
  git checkout -b {feature.json.branch} "$base"
fi
```

Record `feature.json.baseSha = $(git rev-parse HEAD)` if not set; atomic write via `lib/feature-write.sh`. Also record `feature.json.baseBranch = "$base"` for later merge target.

### Step 2 - Pre-task file-conflict detection

Run on **every EXECUTE entry**: both the first entry from PLAN and any re-entry triggered by VERIFY routing back after a code-review HARD-GATE failure (which may add remediation tasks).

#### Step 2a - Read planned tasks from PLAN.md

Parse every task block from `docs/loop-spec/features/{slug}/PLAN.md`. Each task block must contain:
- `id` (e.g., `task-001`)
- `files[]` — list of files the task modifies
- `blockedBy[]` — explicit dependency edges declared in PLAN.md (may be empty)
- `verifyCommand` — shell command to assert correctness
- `acceptanceCriteria[]` — list of acceptance criteria strings
- `readFirst[]` — concrete files the implementer must read before starting (from the planner's `read_first` list; may be empty)
- `specPath` — per-task spec file path when the planner wrote one for a complex task, else `null`
- `brief` — short description of the task for agent prompts

On re-entry from VERIFY, the lead also reads any remediation tasks injected by the verifier or code-reviewer. These are persisted at `feature.json.pendingRemediationTasks[]` (VERIFY appends to this array via `lib/feature-write.sh append` before its `TeamDelete`, so the tasks survive the verify team's teardown). Read them with:

```bash
remediation_tasks=$(jq -r '.pendingRemediationTasks // []' .loop-spec/features/{slug}/feature.json)
```

Include these tasks in the full task set before computing conflict edges. After tasks are registered (TaskCreate or workflow dispatch), clear the array:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" set "$feature_dir" pendingRemediationTasks "[]"
```

#### Step 2b - Compute synthetic blockedBy edges

For each pair of tasks `(A, B)` where both are in `pending` status and `id(A) < id(B)`:

1. Compute `overlap = A.files ∩ B.files`.
2. If `overlap` is empty: no synthetic edge.
3. If `overlap` is non-empty: check whether every file in `overlap` is matched by at least one glob in the exclusion list (see Step 2c). If any file is NOT excluded: add a synthetic `blockedBy` edge `B.blockedBy += [A.id]`.

This recompute runs fresh on every EXECUTE entry to prevent stale conflict data from earlier passes from affecting remediation tasks.

#### Step 2c - Exclusion list

The default exclusion list is **empty** — all file overlaps are flagged by default.

Projects configure exclusions via either source (both are unioned):

- `feature.json.fileConflictExcludeGlobs[]` — per-feature overrides, set directly in `feature.json`.
- `.loop-spec/file-conflict-exclude.txt` — one glob per line, repo-wide, in the gitignored state directory.

Load both sources at the start of Step 2b:

```bash
feature_globs=$(jq -r '.fileConflictExcludeGlobs // [] | .[]' .loop-spec/features/{slug}/feature.json)
repo_globs=""
if [[ -f .loop-spec/file-conflict-exclude.txt ]]; then
  repo_globs=$(grep -v '^#' .loop-spec/file-conflict-exclude.txt | grep -v '^$')
fi
all_exclude_globs=$(printf '%s\n%s' "$feature_globs" "$repo_globs" | grep -v '^$')
```

A file is excluded if it matches any glob in `all_exclude_globs` (use `fnmatch`-compatible matching).

### Step 3 - Dispatch (concurrency ladder)

EXECUTE picks its dispatch mechanism by the structural **width** of the task DAG, not
by tool availability alone. The ladder (`skills/shared/tier-matrix.md` -> "EXECUTE
concurrency ladder") follows the Anthropic tool idiom: the lightest mechanism that fits
the available concurrency wins, and the heaviest (Workflow) fires only on explicit
opt-in.

Build the `tasks[]` array from Step 2a/2b first: each element is `{id, subject, files, blockedBy (union of explicit + synthetic edges), specPath, acceptanceCriteria, readFirst, brief}`.

```bash
featureWorktreeRoot=$(git rev-parse --show-toplevel)
skillDir="${CLAUDE_SKILL_DIR}"
```

Resolve tier params from `skills/shared/tier-matrix.md` by `feature.tier`:

| Tier | maxParallelImplementers | maxRetriesPerTask | reviewersEnabled | t_team | t_wf |
|---|---|---|---|---|---|
| quality | 4 | 3 | true | 3 | 6 |
| balanced | 3 | 2 | true | 3 | 6 |
| quick | 2 | 1 | false | 4 | 8 |

#### Step 3a - Compute DAG width W and read runtime flags

`W` is the peak antichain width of the DAG, measured uncapped (independent of
`maxParallelImplementers`). Serialize the `tasks[]` array built above to JSON
(`tasks_json`); each element needs at least `id` and `blockedBy` (the union of explicit +
synthetic edges). Feed it to `lib/dag-width.sh`:

```bash
W=$(printf '%s' "$tasks_json" | bash "${CLAUDE_SKILL_DIR}/../../lib/dag-width.sh")
dag_rc=$?
if [[ "$dag_rc" -eq 3 ]]; then
  echo "EXECUTE: dependency cycle detected in task DAG; escalating (deadlock)" >&2
  # Treat as escalation {reason: "deadlock"}: pause EXECUTE, return control to user.
  exit 2
fi

workflows_available=$(jq -r '.workflowsAvailable // false' .loop-spec/runtime.json 2>/dev/null || echo false)
workflow_optin=$(jq -r '.workflowExecuteOptIn // false' .loop-spec/runtime.json 2>/dev/null || echo false)
teams_available=$(jq -r '.teamsAvailable // true' .loop-spec/runtime.json 2>/dev/null || echo true)
loops_available=false
command -v claude >/dev/null 2>&1 && loops_available=true
loops_optin="${LOOP_SPEC_EXECUTE_LOOPS:-}"
```

#### Step 3b - Select the rung

Using `t_team` and `t_wf` from the tier table above:

```text
if   loops_optin == "1" AND loops_available == true:                        rung = "loop"       # explicit opt-in, any W
elif W >= t_wf AND workflows_available == true AND workflow_optin == true:  rung = "workflow"   # rung 4
elif W >= t_team AND teams_available == true:                               rung = "team"       # rung 3
elif W >= t_team AND loops_available == true AND loops_optin != "0":        rung = "loop"       # teams unavailable -> loop fleet
else:                                                                       rung = "subagent"   # rung 1 (W==1) or 2 (2<=W<t_team)
```

The **loop** rung runs the DAG as a fleet of bounded headless loops via the
bundled loop-runner skill — no agent teams, no Workflow tool, mechanical
verifier enforcement per iteration, SPEC.md/PLAN.md integrity-protected.
`LOOP_SPEC_EXECUTE_LOOPS=1` forces it at any width; `LOOP_SPEC_EXECUTE_LOOPS=0`
disables it (kill switch). When agent teams are unavailable it replaces the team
rung automatically so EXECUTE keeps working without
`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`.

Announce the choice on one line, then dispatch the matching path below:

```
echo "[EXECUTE] DAG width W=$W tier=$tier -> rung: $rung"
```

- `rung == "subagent"`: follow **`skills/shared/execute-subagent.md`** (lead-driven waves of one-shot `Agent` calls + inline ff-merge). It returns the same `{merged, blocked, escalation, tier}` shape; consume it exactly as the workflow path does (Step 3b-exit below), then go to **Phase exit**. Skip Steps 4-10.
- `rung == "loop"`: follow **`skills/shared/execute-loop-fleet.md`** (plan-to-loop conversion + loop-runner supervisor fleet). It returns the same `{merged, blocked, escalation, tier}` shape; consume it exactly as the workflow path does (Step 3b-exit below), then go to **Phase exit**. Skip Steps 4-10.
- `rung == "team"`: fall through to **Steps 4-10** (the TeamCreate self-claim team).
- `rung == "workflow"`: follow the **Rung 4 - workflow path** section immediately below.

Consuming the subagent-path result (Step 3b-exit): identical to the workflow consume
contract -- escalation non-null or blocked non-empty pauses EXECUTE and returns control
to the user; clean proceeds to Phase exit.

#### Rung 4 - workflow path

Persist `feature.json.activeWorkflow` before calling Workflow (signature: `set <feature_dir> <dot_path> <value_json>`):

```bash
fdir=".loop-spec/features/{slug}"
bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" set "$fdir" activeWorkflow "$(jq -n \
  --arg sp "${CLAUDE_SKILL_DIR}/../../lib/workflows/execute-dag.js" \
  --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{scriptPath: $sp, startedAt: $at}')"
```

Resume note: EXECUTE re-runs from scratch on resume (it does not persist `args`). The re-run is idempotent in practice -- the implementer step skips a task worktree that already exists, and the merge agent's `git merge --ff-only` of an already-merged branch is a no-op. The DAG simply recomputes `ready`/`merged` from the live branch state.

Dispatch:

```
Workflow({
  scriptPath: "${CLAUDE_SKILL_DIR}/../../lib/workflows/execute-dag.js",
  args: {
    tier: feature.tier,
    slug: feature.slug,
    featureWorktreeRoot: featureWorktreeRoot,
    featureBranch: "feat/{slug}",
    models: {
      implementer: feature.models.implementer,
      specComplianceReviewer: feature.models.specComplianceReviewer
    },
    maxParallelImplementers: <from tier table above>,
    maxRetriesPerTask: <from tier table above>,
    reviewersEnabled: <from tier table above>,
    commands: feature.commands,
    skillDir: skillDir,
    tasks: <tasks[] array from Step 2a/2b>
  }
})
```

Clear `activeWorkflow` after the call:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" set "$fdir" activeWorkflow null
```

Consume the FROZEN return `{merged, blocked, escalation, tier}`:

- **escalation non-null or blocked non-empty:** Pause EXECUTE. Print escalation reason and any blocked task ids with their reasons. Return control to the user (cycle-resume-escalation contract). Do not proceed to VERIFY. Reasons come from a fixed vocabulary (display only; do not pattern-match): `blocked[].reason` is one of `spec-compliance-block`, `retry-exhausted`, `commit-missing`, `zero-commit`; `escalation.reason` is `deadlock` or `rebase-conflict`.
- **clean (escalation null, blocked empty):** All tasks merged onto `feat/{slug}`. Skip Steps 4-10 (harness TaskList/TeamCreate are NOT used in this path). Proceed directly to the **Phase exit** section at the end of this skill.

Update `feature.json` after clean completion:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" set "$fdir" mergeQueue "[]"
bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" set "$fdir" currentTeammates "[]"
```

Then proceed to the **Phase exit** section.

---

#### Rung 3 - agent team path (also the workflow-unavailable fallback)

Reached when Step 3b selects `rung == "team"` (`t_team <= W < t_wf`, or `W >= t_wf`
without workflow opt-in/availability). Steps 4-10 are the TeamCreate self-claim team.
Behavior is retained verbatim. The long self-claim loop and reviewer loop details are in
**`skills/shared/execute-loops.md`**.

### Step 4 - Team: TaskCreate for each planned task

After conflict edges are computed (Step 2b), validate each task's metadata orchestrator-side then call `TaskCreate`. The orchestrator owns this validation because the documented `TaskCreated` hook event has an unpublished payload schema and `PreToolUse: TaskCreate` is not a documented matcher; running the check here keeps loop-spec on documented harness behavior:

```bash
for task in $tasks; do
  metadata_json=$(jq -n \
    --argjson blockedBy "$task.blockedBy" \
    --argjson files "$task.files" \
    --arg verifyCommand "$task.verifyCommand" \
    --argjson acceptanceCriteria "$task.acceptanceCriteria" \
    --argjson readFirst "${task.readFirst:-[]}" \
    --arg specPath "${task.specPath:-}" \
    '{loopSpec: true, blockedBy: $blockedBy, files: $files, verifyCommand: $verifyCommand, acceptanceCriteria: $acceptanceCriteria, readFirst: $readFirst, specPath: (if $specPath == "" then null else $specPath end), claimedBy: null, retries: 0}')

  if ! bash "${CLAUDE_SKILL_DIR}/../../lib/validate-task-metadata.sh" "$metadata_json"; then
    echo "EXECUTE Step 4: task $task.id failed metadata validation; aborting" >&2
    exit 2
  fi
done
```

After validation passes, call `TaskCreate` once per task:

```
TaskCreate({
  subject: "{task.id}: {task.subject}",
  metadata: {
    loopSpec:          true,   // marks the task as loop-spec-owned; plugin hooks only enforce on marked tasks
    blockedBy:          [...explicit edges from PLAN.md] + [...synthetic edges from Step 2b],
    files:              [task.files],
    verifyCommand:      "task.verifyCommand",
    acceptanceCriteria: [task.acceptanceCriteria],
    readFirst:          [task.readFirst],
    specPath:           task.specPath,
    claimedBy:          null,
    retries:            0
  }
})
```

`blockedBy` in metadata is the **union** of edges declared in PLAN.md and synthetic edges from the file-conflict check. Store the returned harness task id alongside the plan task id so the lead can address tasks by harness id in subsequent `TaskUpdate` / `TaskGet` calls.

After all `TaskCreate` calls complete, update `feature.json`:

```bash
lib/feature-write.sh set currentTeamName "loop-spec-execute-{slug}"
```

### Step 5 - Fallback: TeamCreate for the EXECUTE team

Size the team from the tier matrix:

| Tier | maxParallelImplementers (M) | Reviewers (R = ceil(M/2)) |
|---|---|---|
| quality | 4 | 2 |
| balanced | 3 | 2 |
| quick | 2 | 0 |

`M = min(plannedTaskCount, tier.execute.maxParallelImplementers)`. `R = ceil(M / 2)`.

When `R == 0` (quick tier): omit all `reviewer-{N}` entries from the `TeamCreate` teammates list.

Models are read literally from `feature.json.models` (resolved once at cycle Step 5):
implementers use `feature.models.implementer` (sonnet), the spec-compliance gate uses
`feature.models.specComplianceReviewer` (opus). Every teammate object MUST carry an explicit `model:`.

```
TeamCreate({
  name: "loop-spec-execute-{slug}",
  teammates: [
    {
      name: "implementer-1",
      subagent_type: "loop-spec:implementer",
      model: feature.models.implementer,
      prompt: "<implementer.md template with {slug}, {tier}, {N}=1, {maxRetriesPerTask} substituted>"
    },
    // ... implementer-2 through implementer-M
    // R reviewers (omitted on quick tier):
    {
      name: "reviewer-1",
      subagent_type: "loop-spec:spec-compliance-reviewer",
      model: feature.models.specComplianceReviewer,
      prompt: "<reviewer spawn prompt with slug, tier, roster>"
    },
    // ... reviewer-2 through reviewer-R (if R > 1)
  ]
})
```

The implementer spawn prompt is the `skills/shared/team-prompts/implementer.md` template with all placeholders substituted. Pass the full teammate roster in the prompt so implementers and reviewers can address each other by name.

Record the full roster in `feature.json.currentTeammates`:

```bash
lib/feature-write.sh set currentTeammates '["implementer-1", ..., "implementer-{M}", "reviewer-1", ..., "reviewer-{R}"]'
```

### Step 6 - Fallback: Implementer self-claim loop and worktree creation

Each `implementer-{N}` runs the following self-claim loop autonomously (as documented in `skills/shared/team-prompts/implementer.md`). The full step-by-step implementer self-claim loop (query, filter unblocked, claim, worktree, implement, verify, commit, hand off), the reviewer self-claim loop, the race-claim serialization contract, and the rework re-entry path are documented in **`skills/shared/execute-loops.md`**.

Contract the lead depends on (the rest is teammate-internal):
- Implementers create a worktree per task at an **absolute path**: `$WT_ROOT/.loop-spec/worktrees/{slug}/task-{taskId}/` (where `WT_ROOT=$(git rev-parse --show-toplevel)` is resolved inside the feature worktree before spawning). The worktree is created on branch `task/{taskId}-{slug}`. The implementer commits there, then sets `metadata.phase = "awaiting_review"` (or goes straight to `completed` on quick tier).
- Reviewers (quality/balanced only) flip a task to `completed` on pass and `SendMessage` `REVIEW PASS: task-{taskId}` to the lead; on terminal failure they mark it `completed` with `metadata.result = "blocked"`.
- On quick tier (R = 0) there are no reviewers; implementers self-complete and message the lead directly.

### Step 7 - Fallback: Idle/wake protocol

Idle and wake are event-driven. No polling.

When `TaskList({status: "pending"})` returns no unblocked tasks and no `needs_rework` tasks are claimable, the implementer sends `SendMessage({to: "lead", body: "implementer-{N} idle: no available tasks"})`.

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

**Post-merge test gate:** quality/balanced tiers run `feature.json.commands.test` (or `lib/detect-test-cmd.sh` if unset). On failure: create a remediation task and re-enter Step 2. quick tier: skip the gate.

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

---

## Phase exit

(Reached from workflow path clean completion OR fallback Step 10 all-clear.)

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/checkpoint.sh" tag post-execute
lib/feature-write.sh append completedPhases "execute"
lib/feature-write.sh set currentPhase "verify"
lib/feature-write.sh set mergeQueue "[]"
lib/feature-write.sh set currentTeammates "[]"
```

#### Phase routing

- `execStyle == "auto"`: proceed immediately to VERIFY (invoke `skills/verify/SKILL.md`).
- `execStyle == "step"` or `execStyle == "interactive"`: return control to the user with a summary of completed tasks and the next phase (`verify`).
