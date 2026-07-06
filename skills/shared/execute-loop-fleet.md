# EXECUTE loop-fleet rung (reference)

The loop-fleet rung runs EXECUTE's task DAG as a fleet of bounded headless loops
via the bundled loop-runner skill (`skills/loop-runner/`), instead of an agent
team. It is the only EXECUTE path with a mechanical spec-adherence guarantee:
every iteration of every worker re-runs the task's `verifyCommand`, and the
feature's SPEC.md/PLAN.md are integrity-protected (hash-locked) so no worker can
edit the requirements to match its work. It requires no agent-teams support and
no `Workflow` tool — only the `claude` CLI on PATH and git.

## When this rung is selected (see execute/SKILL.md Step 3b)

1. `LOOP_SPEC_EXECUTE_LOOPS=1` and `claude` CLI present — explicit opt-in, any W.
2. Agent teams unavailable (`runtime.json.teamsAvailable == false`) and `claude`
   CLI present — automatic fallback that keeps EXECUTE fully functional without
   `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`.

`LOOP_SPEC_EXECUTE_LOOPS=0` disables the rung entirely (kill switch; the ladder
then behaves exactly as before this rung existed).

## Procedure

All paths below are run from the feature worktree root (`feat/{slug}` checked
out). `LOOP_DIR="${CLAUDE_SKILL_DIR}/../loop-runner/scripts"` from a phase skill,
or `skills/loop-runner/scripts` from the repo.

### 1. Convert tasks[] to a loop plan

Serialize the Step 2a/2b `tasks[]` array (explicit + synthetic `blockedBy`
edges already unioned) and convert:

```bash
fdir=".loop-spec/features/{slug}"
printf '%s' "$tasks_json" | bash "${CLAUDE_SKILL_DIR}/../../lib/plan-to-loop.sh" \
  --slug "{slug}" \
  --spec "docs/loop-spec/features/{slug}/SPEC.md" \
  --plan "docs/loop-spec/features/{slug}/PLAN.md" \
  --max-iterations "${LOOP_SPEC_LOOP_MAX_ITERATIONS:-10}" \
  > "$fdir/loop-plan.json"
```

The converter exits 1 if any task lacks a `verifyCommand` — fix the plan, do not
invent one. SPEC.md, PLAN.md, and any per-task `specPath` are force-protected in
every task.

### 2. Validate and announce

```bash
python3 "$LOOP_DIR/supervisor.py" --plan "$fdir/loop-plan.json" --dry-run
```

Print the schedule. Commit any uncommitted work first: the supervisor requires a
clean tree (worktrees branch from HEAD; uncommitted work would be invisible to
every worker).

### 3. Run the fleet

```bash
parallel=$(( W < maxParallelImplementers ? W : maxParallelImplementers ))
python3 "$LOOP_DIR/supervisor.py" \
  --plan "$fdir/loop-plan.json" \
  --parallel "$parallel" \
  --model "{feature.models.implementer}" \
  --retries "2"
rc=$?
```

The supervisor walks the DAG, runs each task's loop in an isolated worktree on
branch `loop/<id>`, merges completed branches into `feat/{slug}` (the current
branch) so dependents build on them, retries stalls/thrash once with the stall
context appended, never retries timeout halts, and kills the fleet on a
verifier-integrity violation.

This call is long-running and unattended; the lead does nothing while it runs.

### 4. Consume the result (never scrape stdout)

Read `.loop/fleet-result.json` and map onto the EXECUTE result contract:

```bash
fleet=".loop/fleet-result.json"
merged=$(jq -c '.completed' "$fleet")
fatal=$(jq -r '.fleet_fatal' "$fleet")
```

- `merged` = `.completed` (task ids already merged into `feat/{slug}`).
- `blocked` = each id in `.failed` with `reason` mapped from its
  `tasks[id].halt_reason`:
  - `max_iterations`, `no_progress`, `verifier_thrash`, `agent_error` → `retry-exhausted`
  - `timeout` → `retry-exhausted` (raise `LOOP_SPEC_LOOP_MAX_ITERATIONS` or the
    timeout and re-enter EXECUTE to resume — loop state is durable, completed
    iterations are not re-run)
  - ids in `.skipped` → `reason: "dep-failed"` (upstream task failed)
- `escalation`:
  - `.fleet_fatal == true` with any `halt_reason == "verifier_integrity"` →
    `{reason: "verifier-integrity"}`. Inspect the diff with suspicion before
    resuming; a worker touched the spec, the plan, or the verify targets.
  - `.fleet_fatal == true` otherwise (merge conflict) → `{reason: "rebase-conflict"}`.
    Two tasks the plan called independent touched the same code; add the missing
    `blockedBy` edge in PLAN.md or resolve by hand.
  - else `null`.

Consume `{merged, blocked, escalation}` exactly as the workflow path does
(execute/SKILL.md Step 3b-exit): escalation non-null or blocked non-empty pauses
EXECUTE and returns control to the user; clean proceeds to Phase exit.

### 5. Diagnostics on failure

Read `halt_reason`, not vibes:

| halt_reason | Meaning | Action |
|---|---|---|
| `no_progress` | task under-specified or too big | split it in PLAN.md, re-enter |
| `verifier_thrash` | pass→fail flapping | inspect `.loop/<id>/iter-*.raw.json` |
| `max_iterations` / `timeout` | too few rounds or thrashing | read iteration logs, raise caps, re-enter (resumes) |
| `verifier_integrity` | worker touched the exam | inspect diff with suspicion |
| `agent_error` | claude CLI failure | check `.loop/<id>.supervisor.log` |

Per-task state lives under `<worktree>/.loop/<id>/`: every iteration's raw
output, every verifier run in full, and the worker-maintained PROGRESS.md.

### Resume semantics

Re-entering EXECUTE re-runs the converter and supervisor. Loop state is durable:
already-completed tasks are merged (their `loop/<id>` branches are no-ops), and a
halted task resumes from its saved state when re-run with a higher iteration cap.
