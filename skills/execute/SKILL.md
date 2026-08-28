---
name: execute
description: EXECUTE phase - dispatches the task DAG up the capability-aware concurrency ladder (subagent waves, agent team, workflow DAG) by width thresholds in tier-matrix. Cycle-internal - invoked by /loop-spec:cycle; not for ad-hoc invocation (start there).
allowed-tools: Bash Read Write Edit Glob Grep Skill Agent AskUserQuestion TeamCreate TeamDelete SendMessage TaskCreate TaskUpdate TaskList TaskGet Workflow ToolSearch
---

# EXECUTE Phase

Invoked when `feature.json.currentPhase == "execute"`. Dispatch is chosen by a
**concurrency ladder** keyed on the task DAG width `W` (Step 3): rung 1/2 subagent waves
(`skills/shared/execute-subagent.md`), rung 3 agent team (TeamCreate self-claim, Steps
4-10), rung 4 Workflow DAG (`lib/workflows/execute-dag.js`, opt-in only). Width
thresholds and the rung rule live in `skills/shared/tier-matrix.md`. All three paths
return the same `{merged, blocked, escalation}` result shape.

## Inputs

- `feature_path`: `.loop-spec/features/{slug}/feature.json`
- `plan_path`: `docs/loop-spec/features/{slug}/PLAN.md`
- `branch`: `feature.json.branch` (e.g., `feat/{slug}`)

## Procedure

### Step 1 - Branch check

loop-spec is schema-7 only. A feature is either workspace mode (`workspace` block
non-null) or single-repo mode (`workspace == null`). Single-repo mode has two explicit
execution roots: the default feature worktree (`executionRootMode == "worktree"`,
`worktreePath` set), or the clean in-place feature branch selected by
`LOOP_SPEC_WORKTREES=0` (`executionRootMode == "in-place"`, `worktreePath == null`).
The latter is the supported single-instance/cloud path, not a legacy fallback.

**Workspace mode (`feature.workspace` non-null):** Each participating repo must be on
`feat/{slug}`. Run the Step 1 branch-check snippet in
`${CLAUDE_SKILL_DIR}/references/workspace-mode.md` verbatim before any other work; if
any repo fails, abort with its message and do not proceed.

**Single-repo worktree mode (`worktreePath` present):** The feature worktree was created at cycle start and the session was switched into it via `EnterWorktree`. The branch `feat/{slug}` is already checked out there. Assert this is the case; do not create the branch in-place:

```bash
current=$(git branch --show-current)
if [[ "$current" != "{feature.json.branch}" ]]; then
  echo "ERROR: expected branch {feature.json.branch} but current branch is '$current'." >&2
  echo "The cycle resume did not EnterWorktree the feature worktree. Aborting." >&2
  exit 2
fi
```

**Single-repo in-place mode (`executionRootMode == "in-place"`):** Cycle startup
already required a clean checkout and created `feat/{slug}` directly in that checkout.
Assert the same branch, but never call `EnterWorktree` and never create a feature or
task worktree:

```bash
current=$(git branch --show-current)
if [[ "$current" != "{feature.json.branch}" ]]; then
  echo "ERROR: in-place execution expected branch {feature.json.branch} but current branch is '$current'." >&2
  echo "Relaunch from the recorded featureRoot; do not create a worktree to compensate." >&2
  exit 2
fi
```

`baseSha` and `baseBranch` were already written by cycle Step 5 (`baseBranch` is the real base, e.g. `main`, used by DELIVER as the PR `--base`). Do not overwrite them here. The per-task ff-merge target is the literal feature branch `feat/{slug}`, never `baseBranch`.

### Step 2 - Pre-task file-conflict detection

Run on **every EXECUTE entry**: both the first entry from PLAN and any re-entry
triggered by VERIFY routing back after a code-review HARD-GATE failure (which may
add remediation tasks). Apply sidecar/PLAN.md parse, `task-progress.sh` seed and
mark-done, synthetic `blockedBy`, the exclusion list, `plan-conflicts.sh` table,
`execute-stop.sh` classify, and `task-batch.sh` collapse verbatim from
`${CLAUDE_SKILL_DIR}/references/conflicts.md`.

### Step 2.5 - Greenfield command backfill

Only when `feature.json.greenfield == true` and `feature.commands.test` is empty: the plan
leads with a scaffold task (task-001 — `skills/plan/SKILL.md`, "Greenfield plans"). Immediately
after task-001 merges into `feat/{slug}` (whatever the rung), re-run detection against the now
real project and persist it:

```bash
cmd_test="$(bash "${CLAUDE_SKILL_DIR}/../../lib/detect-test-cmd.sh" . 2>/dev/null || true)"
prepare_json="$(bash "${CLAUDE_SKILL_DIR}/../../lib/prepare-environment.sh" run --root .)"
cmd_prepare="$(jq -r '.command // ""' <<<"$prepare_json")"
```

Cross-check against the canonical commands SPEC.md's Foundations requirements name (they
should agree; if they differ, prefer what actually runs and append a one-line note to
`warnings[]`), then write `commands.prepare` / `commands.test` / `commands.lint` / `commands.typecheck` into
feature.json via `lib/feature-write.sh`. Every later task's verify and VERIFY's acceptance
gate depend on this backfill — an empty test command in a greenfield feature past task-001
is a bug, not a degraded mode. The invariant is ENFORCED,
not just stated: after the write (and again before dispatching any post-task-001 task), run

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/greenfield-bootstrap.sh" backfill-check "$feature_dir"
```

exit 3 means the backfill is missing — fix it before dispatching anything else (re-run
detection, or take the command from SPEC.md's Foundations requirements).

`verificationBaseline` is `null` for every feature unless `LOOP_SPEC_STARTUP_BASELINE=1`
captured one at startup, and greenfield never captures one — no untouched project suite
existed before scaffold creation. `feature-validation.sh` therefore uses strict mode by
default and requires every configured repository-wide command to pass.

### Step 3 - Dispatch (concurrency ladder)

EXECUTE picks its dispatch mechanism by the structural **width** of the task DAG, not
by tool availability alone. The ladder (`skills/shared/tier-matrix.md` -> "EXECUTE
concurrency ladder") follows the Anthropic tool idiom: the lightest mechanism that fits
the available concurrency wins, and the heaviest (Workflow) fires only on explicit
opt-in.

Whichever rung is selected, every code-producing dispatch carries the design gate from
`skills/shared/implementer-contract.md` (can it be more modular? more extensible? is this
the least amount of code that makes it happen? does this hold at production scale?) — the
rung templates and compilers embed it; the inline rung binds it by cite.

**Dispatch telemetry (`skills/shared/dispatch-events.md`):** whichever rung is selected, emit one `dispatch` event per implementer/reviewer/worker launched — `bash "${CLAUDE_SKILL_DIR}/../../lib/events.sh" emit ".loop-spec/features/${slug}" dispatch --phase "execute" --data '{"role":"<role>","model":"<resolved selector>","rung":"<team|subagent|loop-fleet|workflow>"}' || true`. Loop-fleet: one event per compiled task at fleet launch; worker iterations are not separate dispatches. `SendMessage` rework does not re-emit.

Build the `tasks[]` array from Step 2a/2b first: each element is `{id, subject, files, blockedBy (union of explicit + synthetic edges), specPath, acceptanceCriteria, readFirst, brief, verifyCommand}`. (`verifyCommand` is carried through so the subagent rung can re-run each task's behavioral check against the integrated branch post-merge — see `skills/shared/execute-subagent.md` step 6/7.)

**Workspace mode gate (evaluated BEFORE `featureWorktreeRoot` is resolved):** when
`feature.workspace` is non-null the rung is hard-pinned to `subagent` and the Step
3a/3b ladder is skipped entirely. Run the Step 3 rung-gate snippet in
`${CLAUDE_SKILL_DIR}/references/workspace-mode.md` verbatim — it rejects
`LOOP_SPEC_EXECUTE_LOOPS=1`, pins the rung, and resolves `featureWorktreeRoot` /
`taskWorktreeBase` only on its single-repo branch. The workspace wave loop is
`skills/shared/execute-subagent.md` "Workspace mode".

Fixed operating params (`skills/shared/tier-matrix.md`):

| maxParallelImplementers | maxRetriesPerTask | reviewersEnabled | t_team | t_wf |
|---|---|---|---|---|
| 3 | 6 | true | 3 | 6 |

For constrained containers, `LOOP_SPEC_MAX_PARALLEL_IMPLEMENTERS` may lower the
implementer cap without changing DAG semantics. It must be a positive integer and is
clamped to the tier maximum. `LOOP_SPEC_WORKTREES=0` is stronger than that cap: it
forces `maxParallelImplementers=1` and disables task worktrees. When the harness has
an Agent tool, EXECUTE still uses sequential one-shot implementer/reviewer subagents
to bound the lead's context; only a harness without subagents falls back to inline
lead execution. On the headless subagent rung, wave width > 1 additionally requires
lead-created task worktrees (`subagentIsolation=lead-worktree` from
`lib/execute-rung.sh`); a failed `git worktree add` serializes that wave. Do not
raise the cap until that isolation holds.

The retry cap in the table is the default. Read the overlay at dispatch and pass
that same number into Workflow `maxRetriesPerTask`, team `{maxRetriesPerTask}`,
and `fix-loop.sh action` — otherwise `raise-gate-rounds-execute` (6→7) never
moves the breaker (`skills/shared/tier-matrix.md` "Repo tuning overlay").

```bash
maxParallelImplementers=3
if [[ -n "${LOOP_SPEC_MAX_PARALLEL_IMPLEMENTERS:-}" ]]; then
  [[ "$LOOP_SPEC_MAX_PARALLEL_IMPLEMENTERS" =~ ^[1-9][0-9]*$ ]] || {
    echo "EXECUTE: LOOP_SPEC_MAX_PARALLEL_IMPLEMENTERS must be a positive integer" >&2
    exit 2
  }
  (( LOOP_SPEC_MAX_PARALLEL_IMPLEMENTERS < maxParallelImplementers )) \
    && maxParallelImplementers="$LOOP_SPEC_MAX_PARALLEL_IMPLEMENTERS"
fi
if [[ -n "${LOOP_SPEC_MAX_PARALLEL_SUBAGENTS:-}" ]]; then
  [[ "$LOOP_SPEC_MAX_PARALLEL_SUBAGENTS" =~ ^[1-9][0-9]*$ ]] || {
    echo "EXECUTE: LOOP_SPEC_MAX_PARALLEL_SUBAGENTS must be a positive integer" >&2
    exit 2
  }
  (( LOOP_SPEC_MAX_PARALLEL_SUBAGENTS < maxParallelImplementers )) \
    && maxParallelImplementers="$LOOP_SPEC_MAX_PARALLEL_SUBAGENTS"
fi
[[ "${LOOP_SPEC_WORKTREES:-1}" == "0" ]] && maxParallelImplementers=1
maxRetriesPerTask="$(bash "${CLAUDE_SKILL_DIR}/../../lib/tuning.sh" get executeMaxRetriesPerTask 6)"
```

#### Step 3a - Compute DAG width W and read runtime capabilities

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
teams_mode=$(jq -r '.teamsMode // "none"' .loop-spec/runtime.json 2>/dev/null || echo none)
implementer_model=$(jq -r '.models.implementer // "inherit"' ".loop-spec/features/${slug}/feature.json" 2>/dev/null || echo inherit)
```

#### Step 3b - Select the rung

Run the deterministic selector. Missing/corrupt runtime state fails safe to no teams;
the model never authors a capability boolean or reconstructs this ladder:

Only the `loop-runtime-unavailable` path (exit 1) reports itself as JSON on stdout.
Configuration rejections (invalid `LOOP_SPEC_WORKTREES`, invalid
`LOOP_SPEC_MAX_PARALLEL_SUBAGENTS`, bad width) exit 2 with a plain message on stderr,
so the relay must capture stderr too — `jq` on empty stdin prints nothing, which would
otherwise turn a precise configuration error into a blank `ERROR:` line.

```bash
rung_rc=0
rung_err="$(mktemp)"
rung_json="$(bash "${CLAUDE_SKILL_DIR}/../../lib/execute-rung.sh" select \
  --width "$W" --teams-mode "$teams_mode" \
  --workflows-available "$workflows_available" --workflow-optin "$workflow_optin" \
  --implementer-model "$implementer_model" \
  2>"$rung_err")" || rung_rc=$?
if [[ "$rung_rc" -ne 0 ]]; then
  rung_msg="$(jq -r '.message // empty' <<<"$rung_json" 2>/dev/null || true)"
  [[ -n "$rung_msg" ]] || rung_msg="$(cat "$rung_err")"
  [[ -n "$rung_msg" ]] || rung_msg="dispatch capability probe failed"
  rm -f "$rung_err"
  echo "[EXECUTE] ERROR: $rung_msg" >&2
  exit 2
fi
rm -f "$rung_err"
rung="$(jq -r '.rung' <<<"$rung_json")"
rung_reason="$(jq -r '.reason' <<<"$rung_json")"
```

The gate is the **capability** (`subagents`), not the harness name — a future
harness with its own Agent tool keeps the full ladder without touching this file.

The **loop** rung runs the DAG as a fleet of bounded headless workers via the
bundled loop-runner skill — no agent teams, no Workflow tool, mechanical verifier
enforcement per iteration, SPEC.md/PLAN.md integrity-protected. Selection triggers,
the `LOOP_SPEC_EXECUTE_LOOPS` opt-in/kill-switch, and the full runtime-probe
narrative (headless entrypoints, profile assertions, `LOOP_SPEC_LOOP_RUNTIME`) are
`skills/shared/execute-loop-fleet.md` "When this rung is selected". When both teams
and loops are unavailable, the subagent rung handles any width in bounded waves.

Announce the choice on one line, then dispatch the matching path below:

```
echo "[EXECUTE] DAG width W=$W -> rung: $rung ($rung_reason)"
```

- `rung == "inline"`: follow **`skills/shared/execute-inline.md`** (no one-shot dispatch tool — the lead performs each task itself on `feat/{slug}`). Same `{merged, blocked, escalation}` shape; consume it per Step 3b-exit, then go to **Phase exit**. Skip Steps 4-10.
- `rung == "subagent"`: follow **`skills/shared/execute-subagent.md`** (lead-driven waves of one-shot `Agent` calls + inline ff-merge). It returns the same `{merged, blocked, escalation}` shape; consume it exactly as the workflow path does (Step 3b-exit below), then go to **Phase exit**. Skip Steps 4-10.
- `rung == "loop"`: follow **`skills/shared/execute-loop-fleet.md`** (plan-to-loop conversion + loop-runner supervisor fleet). It returns the same `{merged, blocked, escalation}` shape; consume it exactly as the workflow path does (Step 3b-exit below), then go to **Phase exit**. Skip Steps 4-10.
- `rung == "team"`: fall through to **Steps 4-10** (the TeamCreate self-claim team).
- `rung == "workflow"`: follow **`${CLAUDE_SKILL_DIR}/references/rung-workflow-foreign.md`** ("Rung 4") verbatim.
- `rung == "foreign"`: follow **`${CLAUDE_SKILL_DIR}/references/rung-workflow-foreign.md`** ("Rung 5") verbatim.

Consuming the subagent-path result (Step 3b-exit): identical to the workflow consume
contract -- escalation non-null or blocked non-empty pauses EXECUTE and returns control
to the user; clean proceeds to Phase exit.

#### Rung 3 - agent team path (also the workflow-unavailable fallback)

Reached when Step 3b selects `rung == "team"` (`t_team <= W < t_wf`, or `W >= t_wf`
without workflow opt-in/availability). Steps 4-10 are the TeamCreate self-claim team.
Behavior is retained verbatim. The long self-claim loop and reviewer loop details are in
**`skills/shared/execute-loops.md`**.

> **Implicit-team harness (`.loop-spec/runtime.json.teamsMode == "implicit"`, CC >= 2.1.178):**
> `TeamCreate`/`TeamDelete` were removed and throw. This rung is reached only when
> `lib/implicit-team-model.sh` returned `named` for the implementer selector
> (`lib/execute-rung.sh` skips team when the selector is an alias). In **Step 5**, instead of one `TeamCreate` with a `teammates` array,
> spawn each teammate object as its own `Agent({name, description, subagent_type, prompt})` call with **no** `model` key (the
> prompts are already inline, so this is a 1:1 expansion). In **Steps 9-10**, skip `TeamDelete`
> — just clear `currentTeamName`/`currentTeammates`. `TaskCreate`/`TaskUpdate`/`TaskList` (Steps 4,
> 6-8) and all `SendMessage` routing are unchanged: the session-implicit team shares one task list.
> Per `skills/shared/implicit-team-mode.md`.

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

After validation passes, call `TaskCreate` once per task that is not already in
`mergedSet`. Already-published ids stay out of the harness task list; sidecar
`status=done` satisfies plan-adherence for those ids.

A task carrying `userGate: true` (or the `user-gate` tag) is closed through
`Skill(loop-spec:checking-gates)` when the opt-in revalidation hooks are active — the
gate's evidence contract (`AC:` / `PROVEN BY`) and the `specifying-gates` handoff live in
those two skills, not here.

Call `TaskCreate` once per remaining task:

```
TaskCreate({
  subject: "{task.id}: {task.subject}",
  description: "{task.brief — goal, files, acceptance criteria summary}",   // REQUIRED by the harness schema
  activeForm: "Working on {task.subject}",
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

Size the team from the effective params:
`M = min(plannedTaskCount, maxParallelImplementers)`, `R = ceil(M / 2)`.

Models are read literally from `feature.json.models` (activated for EXECUTE immediately before entry):
implementers use `feature.models.implementer`, and the spec-compliance gate uses
`feature.models.specComplianceReviewer`. These are the already-activated EXECUTE
values, not assumed defaults. Start each teammate object without `model`; add the
key only when its resolved value is an Agent alias, and omit it for `inherit`.

```
TeamCreate({
  name: "loop-spec-execute-{slug}",
  teammates: [
    {
      name: "implementer-1",
      subagent_type: "loop-spec:implementer",
      prompt: "<implementer.md template with {slug}, {N}=1, {maxRetriesPerTask}, {worktreeBase} substituted>"
    },
    // ... implementer-2 through implementer-M
    // R reviewers:
    {
      name: "reviewer-1",
      subagent_type: "loop-spec:spec-compliance-reviewer",
      prompt: "<reviewer spawn prompt with slug, roster>"
    },
    // ... reviewer-2 through reviewer-R (if R > 1)
  ]
})
```

The implementer spawn prompt is the `skills/shared/team-prompts/implementer.md` template with all placeholders substituted. Pass the full teammate roster in the prompt so implementers and reviewers can address each other by name.

`{worktreeBase}` is resolved ONCE by the lead before spawning and substituted into both
the implementer and reviewer prompts, so every teammate agrees on where task worktrees live:

```bash
worktreeBase="$(bash "${CLAUDE_SKILL_DIR}/../../lib/worktree-base.sh" \
  resolve "$WT_ROOT" task "{slug}" | jq -r '.path')"
```

`{maxRetriesPerTask}` is the overlay value resolved with the operating params above.

Record the full roster in `feature.json.currentTeammates`:

```bash
lib/feature-write.sh set currentTeammates '["implementer-1", ..., "implementer-{M}", "reviewer-1", ..., "reviewer-{R}"]'
```

### Step 6 - Fallback: Implementer self-claim loop and worktree creation

Each `implementer-{N}` runs the following self-claim loop autonomously (as documented in `skills/shared/team-prompts/implementer.md`). The full step-by-step implementer self-claim loop (query, filter unblocked, claim, worktree, implement, verify, commit, hand off), the reviewer self-claim loop, the race-claim serialization contract, and the rework re-entry path are documented in **`skills/shared/execute-loops.md`**.

Contract the lead depends on (the rest is teammate-internal):
- Implementers create a worktree per task at an **absolute path**, resolved by `lib/worktree-base.sh resolve "$WT_ROOT" task "{slug}/task-{taskId}"` (where `WT_ROOT=$(git rev-parse --show-toplevel)` is resolved inside the feature worktree before spawning). That keeps the historical `$WT_ROOT/.loop-spec/worktrees/{slug}/task-{taskId}/` location when the feature root can hold the checkout, and relocates it outside the repository when a sandboxed harness denies harness-config paths in-repo or `LOOP_SPEC_WORKTREE_DIR` is set. The lead resolves the path once and passes it to the implementer; never hard-code it. The worktree is created on branch `task/{taskId}-{slug}`. The implementer commits there, then sets `metadata.phase = "awaiting_review"`.
- Reviewers flip a task to `completed` on pass and `SendMessage` `REVIEW PASS: task-{taskId}` to the lead; on terminal failure they mark it `completed` with `metadata.result = "blocked"`.

### Steps 7-10 - Fallback: idle/wake, merge queue, log emission, phase exit

The team-rung runtime protocol — Step 7 idle/wake + the lead wake-and-reconcile contract (source of truth = TaskList, never messages), Step 8 FIFO dependency-aware merge queue (persisted in `feature.json.mergeQueue`), Step 9 log emission, Step 10 phase exit condition + retry-exhausted escalation — is specified verbatim in `${CLAUDE_SKILL_DIR}/references/team-rung-protocol.md`. Read it when dispatch selects the team rung and apply it as written.

---

## Phase exit

(Reached from workflow path clean completion OR fallback Step 10 all-clear.)

### Commit strategy (optional)

Before tagging the checkpoint, read the project's commit strategy:

```bash
commit_strategy="$(bash "${CLAUDE_SKILL_DIR}/../../lib/workflow-config.sh" commit-strategy)"
```

- `per-task` (default, and the behavior when `.loop-spec/workflow.json` is absent): leave the per-task commit history on `feat/{slug}` exactly as the merge ladder produced it. No extra action.
- `at-end`: collapse the feature branch into a single commit so the plan lands as one change. With `feat/{slug}` checked out and merged:
  ```bash
  base="$(jq -r '.baseBranch' "$fdir/feature.json")"
  git reset --soft "$(git merge-base "$base" HEAD)"
  git commit -m "feat: NO_JIRA {slug}"
  ```
  In normal single-repo mode, `at-end` rewrites the final history after per-task
  worktree merges. Under `LOOP_SPEC_WORKTREES=0`, sequential implementers commit
  directly on `feat/{slug}` and the same final squash applies without task worktrees.
  Skip silently in workspace mode (in-place branches across repos make a cross-repo
  squash ambiguous; v1 keeps per-task there).

  **Caveat (per Anthropic long-running-agent guidance):** for long unsupervised / overnight runs, prefer `per-task` (the default). Anthropic recommends committing after every meaningful unit so history is recoverable and progress is not lost if the run dies partway; `at-end` trades that recoverability for a clean single commit and is best reserved for short, supervised features.

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/checkpoint.sh" tag post-execute
lib/feature-write.sh append completedPhases "execute"
lib/feature-write.sh set mergeQueue "[]"
lib/feature-write.sh set currentTeammates "[]"
```

#### Phase routing

Always return to the cycle orchestrator; never invoke a successor phase directly.
EXECUTE declares no successor — `graph/cycle.graph.json` does, and the engine
(`lib/graph/run.sh`, cycle Step 6) selects the next node. After this skill
returns, `lib/graph/probes/execute-fanout.sh` reads `mergeQueue`: an empty
queue skips `execute.worker` (the rung already finished the DAG inside this
node); a non-empty queue admits the declared fanout. An unresolved probe
takes `routeDefault` (`human.after-execute`) rather than aborting the
cycle. Cycle owns the phase
boundary: continuous mode enters the engine-selected node immediately, while
`phaseHandoff == true` writes the paused result and ends the main-agent invocation.
For `step` / `interactive`, include the completed-task summary and the
engine-selected next node in the returned phase summary.
