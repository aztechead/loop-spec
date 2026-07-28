# EXECUTE loop-fleet rung (reference)

The loop-fleet rung runs EXECUTE's task DAG as a fleet of bounded headless loops
via the bundled loop-runner skill (`skills/loop-runner/`), instead of an agent
team. It is the only EXECUTE path with a mechanical spec-adherence guarantee:
every iteration of every worker re-runs the task's `verifyCommand`, and the
feature's SPEC.md/PLAN.md are integrity-protected (hash-locked) so no worker can
edit the requirements to match its work. It requires no agent-teams support and
no `Workflow` tool, but it does require the **agent CLI** on PATH, git, and a
persistent harness runtime that can keep one synchronous long-running tool call alive.
The agent CLI is the
running harness's own headless binary (`claude`, `pi`, or `opencode`), resolved
by `bash "${CLAUDE_SKILL_DIR}/../../lib/harness.sh" cli`; under pi every
`supervisor.py` / `loop.py` invocation below additionally carries
`--agent-cli pi --claude-bin pi` (see `skills/shared/pi-harness.md`), and under
opencode `--agent-cli opencode --claude-bin opencode`
(see `skills/shared/opencode-harness.md`).

## When this rung is selected (see execute/SKILL.md Step 3b)

1. `LOOP_SPEC_EXECUTE_LOOPS=1` and the agent CLI present — explicit opt-in, any W.
2. Agent teams unavailable (`runtime.json.teamsAvailable == false`), the agent
   CLI present, and `harness.sh loop-runtime == true` — automatic fallback.

`LOOP_SPEC_EXECUTE_LOOPS=0` disables the rung entirely (kill switch; the ladder
then behaves exactly as before this rung existed).

`LOOP_SPEC_NON_INTERACTIVE=1` or `LOOP_SPEC_EXECUTION_PROFILE=headless` makes the
runtime probe false, so one-shot `claude -p`, cron, CI, and SDK jobs use subagent
waves at any width. `LOOP_SPEC_LOOP_RUNTIME=1` is the explicit integrator assertion
that a headless wrapper can keep the foreground call alive. Never background the
supervisor and never use `ScheduleWakeup`; a forced loop without this capability is
a loud EXECUTE error rather than a silent exit.

Under Claude Code no operator env is needed for the common case: the harness stamps
`CLAUDE_CODE_ENTRYPOINT`, and the values `sdk-cli` (`claude -p`), `sdk-py` (Python
Agent SDK) and `sdk-ts` (TypeScript SDK) are proven one-shot invocations. The probe
reads that stamp and reports `headless/<stamp>`. A stamped headless entrypoint
outranks `LOOP_SPEC_EXECUTION_PROFILE=interactive` — a stale inherited export cannot
claim a runtime the job demonstrably does not have — but never outranks
`LOOP_SPEC_LOOP_RUNTIME`. See `docs/loop-spec/claude-invocation-contract.md`.

An unset profile on an unrecognized entrypoint is deliberately `unproven-runtime`
and also falls back. Persistent interactive operators may set
`LOOP_SPEC_EXECUTION_PROFILE=interactive`; this is an explicit capability assertion,
not an LLM-authored judgment.

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
  --feature-dir "$fdir" \
  --prepare-command "$(jq -r '.commands.prepare // ""' "$fdir/feature.json")" \
  --parallel "$parallel" \
  --model "{feature.models.implementer}" \
  --retries "2"
rc=$?
```

Add `--max-budget-usd "$LOOP_SPEC_LOOP_MAX_BUDGET_USD"` when that variable is set:
it caps each task's cumulative spend (halting `budget_exhausted`) and caps every
tick at the task's remaining budget. Unset means unbounded — iteration and
wall-clock caps do not bound cost.

Under pi, append `--agent-cli pi --claude-bin pi` and pass a **pi model id** (or
omit `--model` to use the session default) — the `feature.models.*` aliases are
Claude Code aliases and mean nothing to pi (`skills/shared/pi-harness.md`,
"Model routing"). Under opencode, append `--agent-cli opencode --claude-bin
opencode` and pass an **opencode model id** (`provider/model`) or omit `--model`
(`skills/shared/opencode-harness.md`, "Model routing").

The supervisor walks the DAG, runs each task's loop in an isolated worktree on
branch `loop/<id>`, merges completed branches into `feat/{slug}` (the current
branch) so dependents build on them, retries stalls/thrash once with the stall
context appended, never retries timeout halts, and kills the fleet on a
verifier-integrity violation.
Before each merge, the supervisor rebases and verifies the immutable candidate through
`integrate-task.sh`, combining the task command with `feature-validation.sh compare` from
that task worktree. Only a candidate with no new exact-base failures can merge.

This call is long-running and unattended; run it in the foreground. The supervisor
prints and flushes `FLEET_START` before environment preparation, bounds every worker
subprocess by the task timeout plus shutdown grace, and writes an initial
`.loop/fleet-result.json` before dispatch. If the call returns without a terminal fleet
result, escalate with `loop-fleet supervisor made no progress` and do not advance.

**Dispatch telemetry (`skills/shared/dispatch-events.md`):** before launching the supervisor, emit one `dispatch` event per compiled task — `bash "${CLAUDE_SKILL_DIR}/../../lib/events.sh" emit "$fdir" dispatch --phase "execute" --data '{"role":"implementer","model":"<feature.models.implementer>","rung":"loop-fleet"}' || true`. Worker iterations are not separate dispatches.

### 4. Consume the result (never scrape stdout)

Read `.loop/fleet-result.json` and map onto the EXECUTE result contract:

```bash
fleet=".loop/fleet-result.json"
if [[ "$rc" -ne 0 && "$rc" -ne 1 ]]; then
  echo "EXECUTE: loop-fleet supervisor failed before a consumable result (rc=$rc)" >&2
  exit 2
fi
fleet_status=$(jq -r '.status // "missing"' "$fleet" 2>/dev/null || echo missing)
if [[ "$fleet_status" != "complete" && "$fleet_status" != "incomplete" ]]; then
  echo "EXECUTE: loop-fleet supervisor made no progress; terminal result missing (status=$fleet_status, rc=$rc)" >&2
  exit 2
fi
merged=$(jq -c '.completed' "$fleet")
fatal=$(jq -r '.fleet_fatal' "$fleet")
```

- `merged` = `.completed` (task ids already merged into `feat/{slug}`).
- `.status == "running"`, a missing result, or malformed JSON is a supervisor
  escalation regardless of process exit code; never interpret empty arrays as success.
- `blocked` = each id in `.failed` with `reason` mapped from its
  `tasks[id].halt_reason`:
  - `max_iterations`, `no_progress`, `verifier_thrash`, `agent_error` → `retry-exhausted`
  - `environment_error`, `supervisor_error`, `supervisor_timeout`,
    `integration_error`, `fleet_aborted` → `retry-exhausted` with the recorded error detail
  - `timeout`, `budget_exhausted` → `retry-exhausted` (raise
    `LOOP_SPEC_LOOP_MAX_ITERATIONS`, the timeout, or `--max-budget-usd` and
    re-enter EXECUTE to resume — loop state is durable, completed iterations are
    not re-run)
  - ids in `.skipped` → `reason: "dep-failed"` (upstream task failed)
- `escalation`:
  - `.fleet_fatal == true` with any `halt_reason == "verifier_integrity"` →
    `{reason: "verifier-integrity"}`. Inspect the diff with suspicion before
    resuming; a worker touched the spec, the plan, or the verify targets.
  - `.fleet_fatal == true` with any `halt_reason == "supervisor_error"` →
    `{reason: "supervisor-error"}` with the recorded detail.
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
| `budget_exhausted` | task reached its `--max-budget-usd` cap | work so far is committed; raise the cap and re-enter (resumes) |
| `agent_error` | claude CLI failure | check `.loop/<id>.supervisor.log` |
| `environment_error` | target environment preparation failed | fix the declared prepare command |
| `supervisor_error` / `supervisor_timeout` | fleet infrastructure failed or exceeded its bound | inspect the flushed fleet output and task supervisor log |
| `integration_error` | exact-candidate rebase/verification failed | inspect helper detail; add a missing dependency edge for conflicts |

Per-task state lives under `<worktree>/.loop/<id>/`: every iteration's raw
output, every verifier run in full, and the worker-maintained PROGRESS.md.

### Resume semantics

Re-entering EXECUTE re-runs the converter and supervisor. Loop state is durable:
already-completed tasks are merged (their `loop/<id>` branches are no-ops), and a
halted task resumes from its saved state when re-run with a higher iteration cap.
