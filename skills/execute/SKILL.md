---
name: execute
description: EXECUTE phase - deterministic capability-aware dispatch by DAG width W. Rung 1/2 subagent (lead-driven Agent waves), rung 3 agent team (self-claim), rung 4 workflow DAG (execute-dag.js, opt-in only). Loop-fleet is available only when its persistent runtime capability is present. Fixed width thresholds in tier-matrix. Cycle-internal - invoked by /loop-spec:cycle against the active feature's state; not for ad-hoc invocation on a bare user request (start via /loop-spec:cycle).
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

**Workspace mode (`feature.workspace` non-null):** Each participating repo must be on `feat/{slug}`. Assert this before any other work:

```bash
workspace_root="$(jq -r '.workspace.root' .loop-spec/features/{slug}/feature.json)"
feature_slug="{feature.json.slug}"
jq -c '.workspace.repos[]' .loop-spec/features/{slug}/feature.json | while IFS= read -r repo_entry; do
  rname="$(echo "$repo_entry" | jq -r '.name')"
  rpath="$(echo "$repo_entry" | jq -r '.path')"
  abs_repo="${workspace_root}/${rpath}"
  current="$(git -C "$abs_repo" branch --show-current)"
  if [[ "$current" != "feat/${feature_slug}" ]]; then
    echo "ERROR: workspace repo '$rname' ($abs_repo): expected branch feat/${feature_slug} but current branch is '$current'." >&2
    echo "Ensure every participating repo is on feat/${feature_slug} before running EXECUTE." >&2
    exit 2
  fi
done
```

If any repo fails the check, abort with the message above. Do not proceed.

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

Run on **every EXECUTE entry**: both the first entry from PLAN and any re-entry triggered by VERIFY routing back after a code-review HARD-GATE failure (which may add remediation tasks).

**Workspace mode note:** Conflict detection logic is unchanged. In workspace mode, task `files[]` are workspace-relative paths of the form `<repo>/<path>` (e.g., `frontend/src/app.ts`). Because each task targets exactly one repo, file paths from different repos are disjoint by their repo prefix -- cross-repo overlaps are naturally impossible. The synthetic `blockedBy` edge logic of Step 2b still applies within a single repo's tasks.

#### Step 2a - Read planned tasks (sidecar first, PLAN.md fallback)

PLAN Step 6 persists the gate-validated `tasks[]` as machine-readable JSON at
`feature.json.artifacts.tasks` (`.loop-spec/features/{slug}/tasks.json`). Prefer it — it is
the exact structure the PLAN gates validated, so nothing needs to be re-derived from
markdown prose:

```bash
tasks_sidecar="$(jq -r '.artifacts.tasks // ""' .loop-spec/features/{slug}/feature.json)"
if [[ -n "$tasks_sidecar" && -f "$tasks_sidecar" ]] \
   && bash "${CLAUDE_SKILL_DIR}/../../lib/artifact-lint.sh" tasks "$tasks_sidecar"; then
  echo "[EXECUTE] task source: sidecar ($tasks_sidecar)"
else
  echo "[EXECUTE] task source: PLAN.md parse (sidecar missing or failed artifact-lint)"
fi
```

When the sidecar is readable, seed `mergedSet` from already-published ids so a resumed
cycle does not re-dispatch completed work. A missing or empty `status` is pending.

```bash
mergedSet=()
if [[ -n "$tasks_sidecar" && -f "$tasks_sidecar" ]]; then
  while IFS= read -r id; do
    [[ -n "$id" ]] && mergedSet+=("$id")
  done < <(bash "${CLAUDE_SKILL_DIR}/../../lib/task-progress.sh" done "$tasks_sidecar")
fi
```

After any successful publication onto `feat/{slug}`, persist that fact:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/task-progress.sh" mark-done \
  ".loop-spec/features/{slug}/tasks.json" "{taskId}"
```

A mark-done failure (sidecar missing, unknown id) is a warning, not an integration
failure — the commit is already on the branch. If every planned id is already in
`mergedSet` and `pendingRemediationTasks` is empty, skip to Phase exit (VERIFY).

When using the sidecar, cross-check its task ids against the `### task-` headings in
PLAN.md: an id set mismatch means PLAN.md was revised after the sidecar was written —
log one line naming the mismatched ids and fall back to the PLAN.md parse below
(PLAN.md is the reviewed artifact; it wins).

**Fallback — parse PLAN.md directly** (sidecar missing, stale, or flagged; also the path
for features planned before the sidecar existed): parse every task block from
`docs/loop-spec/features/{slug}/PLAN.md`. Each task block must contain:
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

**Normalize every remediation task to full shape BEFORE it joins the task set** — producers
(resume redirection, ITERATE execute-gaps, VERIFY test-regression) write full-shape tasks,
but a partial one from an older feature.json or a missed field must not reach Step 4, where
the task guard hook DENYs it (`blockedBy`, `files`, `verifyCommand`, `acceptanceCriteria`
required). Synthesize the missing fields: `blockedBy` → `[]`, `files` → `[]`,
`acceptanceCriteria` → `[subject]`, `verifyCommand` → `feature.commands.test` (a remediation
task with NO verify command at all is malformed — drop it with a one-line warning rather than
registering an unverifiable task).

Include these tasks in the full task set before computing conflict edges. After tasks are registered (TaskCreate or workflow dispatch), clear the array:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" set "$feature_dir" pendingRemediationTasks "[]"
```

#### Step 2b - Compute synthetic blockedBy edges

For each pair of tasks `(A, B)` where both are still pending (missing `status`
counts as pending; skip any id already in `mergedSet`) and `id(A) < id(B)`:

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

#### Step 2d - Conflict table and rulings

Emit a machine-readable conflict table before Task 1. The table is the probe;
a ruling after it is still a model judgment.

```bash
mkdir -p ".loop-spec/features/{slug}/dispatch"
if [[ -n "$tasks_sidecar" && -f "$tasks_sidecar" ]]; then
  bash "${CLAUDE_SKILL_DIR}/../../lib/plan-conflicts.sh" table "$tasks_sidecar" \
    > ".loop-spec/features/{slug}/dispatch/conflict-table.json"
fi
```

Read `rows`. Zero is a clean scan (the table still exists). For each pair or
interface row, classify the conflict text:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/execute-stop.sh" classify "<overlap or interface summary>"
```

`stop=true` pauses EXECUTE (cycle-resume-escalation contract). `stop=false
reason=ruling` records the ruling and continues. Substitute the conflict as the
question, the call you made as the answer, and why you made it as the rationale:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/decisions.sh" add "$fdir" execute \
  "task-003 and task-007 both write lib/foo.sh" \
  "task-007 rebases onto task-003; no plan change" \
  "the overlap is one function and the order is already in blockedBy" \
  ruling
```

Autonomous mode never waits on a reversible question. Pass `--plan-broken` only
when the operator has declared the plan itself broken.

#### Step 2e - Same-shape collapse

Collapse same-shape members before any rung forms a wave. Fail-closed: no
`batchGroup` hint, a `blockedBy` edge out of the group, mismatched
`verifyCommand`, or overlapping files keeps one-task-one-dispatch.

```bash
if [[ -n "$tasks_sidecar" && -f "$tasks_sidecar" ]]; then
  bash "${CLAUDE_SKILL_DIR}/../../lib/task-batch.sh" collapse "$tasks_sidecar" \
    > ".loop-spec/features/{slug}/dispatch/tasks-collapsed.json"
fi
```

Use the collapsed array as the dispatch task list. A collapsed group keeps the
first member's id, unions `files[]`, and carries `memberIds[]`. Reviewers assert
every listed file appears in the diff.

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

**Dispatch telemetry (`skills/shared/dispatch-events.md`):** whichever rung is selected, emit one `dispatch` event per implementer/reviewer/worker launched — `bash "${CLAUDE_SKILL_DIR}/../../lib/events.sh" emit ".loop-spec/features/${slug}" dispatch --phase "execute" --data '{"role":"<role>","model":"<resolved selector>","rung":"<team|subagent|loop-fleet|workflow>"}' || true`. Loop-fleet: one event per compiled task at fleet launch; worker iterations are not separate dispatches. `SendMessage` rework does not re-emit.

Build the `tasks[]` array from Step 2a/2b first: each element is `{id, subject, files, blockedBy (union of explicit + synthetic edges), specPath, acceptanceCriteria, readFirst, brief, verifyCommand}`. (`verifyCommand` is carried through so the subagent rung can re-run each task's behavioral check against the integrated branch post-merge — see `skills/shared/execute-subagent.md` step 6/7.)

**Workspace mode gate (evaluated BEFORE `featureWorktreeRoot` is resolved):**

When `feature.workspace` is non-null, hard-pin the rung here and skip the `featureWorktreeRoot` line and the Step 3a/3b ladder entirely. The workspace root may not be a git repo; running `git rev-parse --show-toplevel` at a non-repo root would abort under set -e semantics.

```bash
workspace_block="$(jq -r '.workspace // "null"' .loop-spec/features/{slug}/feature.json)"
if [[ "$workspace_block" != "null" ]]; then
  # Workspace mode: rung is always subagent. No ladder evaluation.
  if [[ "${LOOP_SPEC_EXECUTE_LOOPS:-}" == "1" ]]; then
    echo "[EXECUTE] ERROR: LOOP_SPEC_EXECUTE_LOOPS=1 is not supported in workspace mode." >&2
    echo "  The loop-fleet rung is single-repo only. Unset LOOP_SPEC_EXECUTE_LOOPS or" >&2
    echo "  run EXECUTE without it. Aborting -- resolve this before proceeding." >&2
    exit 2
  fi
  repo_count="$(echo "$workspace_block" | jq '.repos | length')"
  rung="subagent"
  echo "[EXECUTE] workspace mode -> rung capped at subagent (repos: ${repo_count})"
  skillDir="${CLAUDE_SKILL_DIR}"
  # Skip to subagent dispatch; featureWorktreeRoot is not set (not needed in workspace mode).
  # Follow skills/shared/execute-subagent.md "Workspace mode" section.
else
```

Close the else block after the ladder resolves:

```bash
  # --- single-repo path below ---
  featureWorktreeRoot=$(git rev-parse --show-toplevel)
  skillDir="${CLAUDE_SKILL_DIR}"
  # One resolution for every task worktree of this feature, passed to whichever rung
  # runs (Workflow DAG arg, team-prompt {worktreeBase}, subagent worktree_path).
  taskWorktreeBase="$(bash "${CLAUDE_SKILL_DIR}/../../lib/worktree-base.sh" \
    resolve "$featureWorktreeRoot" task "{slug}" | jq -r '.path')"
fi
```

In workspace mode the `featureWorktreeRoot` variable is NOT set. The subagent path uses per-repo absolute paths from `feature.workspace.repos[]` instead. See `skills/shared/execute-subagent.md` "Workspace mode" section for the workspace-aware wave loop.

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
bundled loop-runner skill — no agent teams, no Workflow tool, mechanical
verifier enforcement per iteration, SPEC.md/PLAN.md integrity-protected.
`LOOP_SPEC_EXECUTE_LOOPS=1` forces it at any width; `LOOP_SPEC_EXECUTE_LOOPS=0`
disables it (kill switch). Selection additionally requires the persistent runtime
capability from `lib/harness.sh loop-runtime`. `LOOP_SPEC_NON_INTERACTIVE=1` and
`LOOP_SPEC_EXECUTION_PROFILE=headless` disable that capability unless the operator
explicitly guarantees it with `LOOP_SPEC_LOOP_RUNTIME=1`. When both teams and loops
are unavailable, the subagent rung handles any width in bounded waves. An unmarked
invocation also fails safe; set `LOOP_SPEC_EXECUTION_PROFILE=interactive` to enable
automatic loop selection in a persistent session.

Announce the choice on one line, then dispatch the matching path below:

```
echo "[EXECUTE] DAG width W=$W -> rung: $rung ($rung_reason)"
```

- `rung == "inline"`: follow **`skills/shared/execute-inline.md`** (no one-shot dispatch tool — the lead performs each task itself on `feat/{slug}`). Same `{merged, blocked, escalation}` shape; consume it per Step 3b-exit, then go to **Phase exit**. Skip Steps 4-10.
- `rung == "subagent"`: follow **`skills/shared/execute-subagent.md`** (lead-driven waves of one-shot `Agent` calls + inline ff-merge). It returns the same `{merged, blocked, escalation}` shape; consume it exactly as the workflow path does (Step 3b-exit below), then go to **Phase exit**. Skip Steps 4-10.
- `rung == "loop"`: follow **`skills/shared/execute-loop-fleet.md`** (plan-to-loop conversion + loop-runner supervisor fleet). It returns the same `{merged, blocked, escalation}` shape; consume it exactly as the workflow path does (Step 3b-exit below), then go to **Phase exit**. Skip Steps 4-10.
- `rung == "team"`: fall through to **Steps 4-10** (the TeamCreate self-claim team).
- `rung == "workflow"`: follow the **Rung 4 - workflow path** section immediately below.
- `rung == "foreign"`: follow the **Rung 5 - foreign claimants** section immediately below.

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

Resume note: pass `doneTaskIds` from `task-progress.sh done` (Step 2a). The DAG
seeds `mergedSet` from those ids and dispatches only remaining work. After each
successful publication the merge agent persists `status=done` on the sidecar. Do
not rebuild remaining work from git history.

Dispatch:

```
Workflow({
  scriptPath: "${CLAUDE_SKILL_DIR}/../../lib/workflows/execute-dag.js",
  args: {
    slug: feature.slug,
    featureWorktreeRoot: featureWorktreeRoot,
    featureBranch: "feat/{slug}",
    models: {
      implementer: feature.models.implementer,
      specComplianceReviewer: feature.models.specComplianceReviewer
    },
    maxParallelImplementers: maxParallelImplementers,
    maxRetriesPerTask: maxRetriesPerTask,
    reviewersEnabled: true,
    commands: feature.commands,
    skillDir: skillDir,
    // bash "${CLAUDE_SKILL_DIR}/../../lib/worktree-base.sh" resolve "$featureWorktreeRoot" task "{slug}" | jq -r '.path'
    taskWorktreeBase: taskWorktreeBase,
    tasks: <tasks[] array from Step 2a/2b>,
    doneTaskIds: <mergedSet from Step 2a — ids already status=done>
  }
})
```

Clear `activeWorkflow` after the call:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" set "$fdir" activeWorkflow null
```

Consume the FROZEN return `{merged, blocked, escalation}`:

- **escalation non-null or blocked non-empty:** Pause EXECUTE. Print escalation reason and any blocked task ids with their reasons. Return control to the user (cycle-resume-escalation contract). Do not proceed to VERIFY. Reasons come from a fixed vocabulary (display only; do not pattern-match): `blocked[].reason` is one of `spec-compliance-block`, `retry-exhausted`, `commit-missing`, `zero-commit`; `escalation.reason` is `deadlock` or `rebase-conflict`.
- **clean (escalation null, blocked empty):** All tasks merged onto `feat/{slug}`. Skip Steps 4-10 (harness TaskList/TeamCreate are NOT used in this path). Proceed directly to the **Phase exit** section at the end of this skill.

Update `feature.json` after clean completion:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" set "$fdir" mergeQueue "[]"
bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" set "$fdir" currentTeammates "[]"
```

Then proceed to the **Phase exit** section.

---

#### Rung 5 - foreign claimants (opt-in)

Reached when Step 3b selects `rung == "foreign"` (`LOOP_SPEC_FOREIGN_CLAIMANTS=1` and a
handoff port adapter is reachable — `lib/execute-rung.sh`, `skills/shared/handoff-port.md`).
Each task in `tasks[]` from Step 3 becomes one claimable bundle instead of a `Task`/`Agent`
dispatch. The graph node dispatched is still `execute.worker` (`graph/cycle.graph.json`) —
width selects the rung, it never substitutes a different node or a different contract.

Offer every remaining task as a bundle and put it on the port (skip ids already in `mergedSet`):

```bash
fdir=".loop-spec/features/{slug}"
for task in <tasks[] array from Step 2a/2b>; do
  bash "${CLAUDE_SKILL_DIR}/../../lib/graph/handoff.sh" export \
    --feature-dir "$fdir" --node execute.worker --task "$task.id" \
    --verify "$task.verifyCommand" --brief "$task.brief" --files "$task.files" \
    --out "$WORK/bundle-$task.id.json"
  id="$(bash "${CLAUDE_SKILL_DIR}/../../lib/graph/port.sh" put "$WORK/bundle-$task.id.json" \
    | sed -n 's/^id=//p')"
  # record id alongside task.id, e.g. via feature.json.artifacts or an in-memory map
done
```

`--brief`/`--files` carry `task.brief` and `task.files` (already computed in Step 2a/2b,
`skills/plan/SKILL.md`) onto the bundle -- without them a claimant sharing no session
state with EXECUTE would have `inputs`+`verifyCommand` (what state to run against, how
to check its own output) but nothing telling it what to build or where the result
belongs (`examples/foreign-claimant/` is a reference consumer that depends on both).

`--task` makes the bundle id content-addressed from node + task + state hash
(`skills/shared/handoff-port.md`), so `task-002` and `task-003` of the same EXECUTE
never collide, and re-exporting the same task at the same feature state is idempotent.

**What this rung does not automate.** There is no supervisor loop here that blocks
EXECUTE waiting on a foreign claimant, the way the team rung's self-claim loop or the
loop-fleet's synchronous worker call does. Claiming a bundle, doing the work, and
calling `complete` happen on infrastructure this session does not control and may not
share a process with — that is the entire point of the port. Say this plainly rather
than implying a poll loop exists: after `put`-ting the outstanding bundles, EXECUTE
returns control the same way any `step`/`interactive` phase summary does (see **Phase
routing** at the end of this skill) rather than inventing a busy-wait. Driving claim →
work → `complete` on the claimant side, and re-invoking EXECUTE to check for results, is
the integrator's responsibility — a cron job, a Routine, or a human running the next
cycle turn.

**Collecting a result on re-entry.** Each time EXECUTE is (re-)entered with tasks still
assigned to this rung, check every recorded id before re-offering it:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/graph/port.sh" get "$id" > "$WORK/instance-$id.json" 2>/dev/null \
  && jq -e 'true' "$WORK/instance-$id.json" >/dev/null 2>&1
```

`get` returns the bundle, not a separate "has it completed" flag — the port contract
(`skills/shared/handoff-port.md`) exposes completion only through the reference
adapter's own instance store today (`result.json` alongside the bundle) or through
whatever equivalent an integrator's `LOOP_SPEC_PORT` adapter provides; there is no
sixth operation for it. For every id whose result is available, merge it:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/graph/handoff.sh" import \
  --feature-dir "$fdir" --bundle "$WORK/bundle-$task.id.json"
```

`import` re-derives the state hash from the live `feature.json` at `$fdir` and rejects a
bundle whose captured hash no longer matches (exit 1, left unmerged) — the same
stale-return rule `complete` enforces on the claimant side
(`skills/shared/handoff-port.md`), applied again on the merging side. A rejected import
leaves the task `pending`; re-offer it as a fresh bundle rather than merging a return
checked against state that has since moved. A merged import still needs
`task.verifyCommand` re-run against the integrated branch before the task counts as
done, exactly as the subagent rung does post-merge (`skills/shared/execute-subagent.md`
step 6/7) — a foreign claimant's return is checked against the same criteria any other
rung's return is, never a degraded variant.

Tasks with no result yet keep EXECUTE returning control on re-entry (unchanged from the
above). Once every task assigned to this rung has merged or exhausted its retry budget,
continue to **Phase exit** like any other rung.

---

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
node); a non-empty queue admits the declared fanout. Cycle owns the phase
boundary: continuous mode enters the engine-selected node immediately, while
`phaseHandoff == true` writes the paused result and ends the main-agent invocation.
For `step` / `interactive`, include the completed-task summary and the
engine-selected next node in the returned phase summary.
