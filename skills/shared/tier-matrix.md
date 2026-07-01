# Operating Parameters (single-tier)

Single-tier operation (v2.5.0 hard cutover): the quick/balanced/quality axis is gone.
Gate behavior, severity thresholds, retry budgets, and fan-out width are FIXED. Cost on
trivially-scoped work is controlled structurally — by the measured plan (the fast-path
below) and the DAG-width ladder — never by an intent tier inferred from the prompt.
Model selection is fixed and lives in `skills/shared/model-matrix.md`.

## Gate behavior (fixed)

| Gate | Behavior |
|---|---|
| Spec critique (advocate + challenger) | ALWAYS runs — the cheap gate that catches building the wrong thing entirely |
| Plan critique (advocate + challenger) | Runs unless the **structural fast-path** holds (below) |
| Spec-compliance gate | runs |
| Acceptance gate | runs |
| Test-tamper scan | runs (fail-fast) |
| Code-review HARD-GATE severity | Critical + Important blocked; Minor → `lib/backlog.sh` (never silently dropped) |
| Decision-coverage + criteria-coverage gates | BLOCK (re-dispatch planner), never advisory |

## Structural fast-path (replaces the old `quick` tier)

Decided AFTER planning, from measured scope — not before, from prompt vibes. The PLAN
critique debate is skipped iff ALL hold:

1. The plan has **<= 2 tasks**, AND
2. the union of task `files[]` touches **<= 3 files**, AND
3. neither SPEC.md nor PLAN.md matches the security-signal pattern:
   `auth|authenticat|authoriz|permission|credential|secret|token|crypt|payment|billing|PII|migrat|delet`

When skipped, log one line: `plan critique skipped (structural fast-path: {N} tasks, {M} files, no security signal)`.
Everything else (spec critique, compliance, acceptance, code review, tamper scan) still runs.

## Team coordination params (fixed)

| Param | Value |
|---|---|
| discuss.maxCritiqueRounds | 2 |
| plan.maxCritiqueRounds | 2 |
| execute.maxParallelImplementers | 3 |
| execute.maxRetriesPerTask | 2 |

## Retry + iteration budgets (fixed; mirrors `lib/feature-init.sh`)

| Budget | Value |
|---|---|
| retryBudget.perGate | 3 |
| retryBudget.perPhase | spec 3 / discuss 3 / plan 4 / execute — / verify 4 / iterate 10 |
| retryBudget.global | 40 |
| iterate.maxIterations | 10 |

## EXECUTE concurrency ladder

The EXECUTE phase chooses its dispatch mechanism by the structural width `W` of
the task DAG (peak antichain across a topological wave simulation, computed by
`lib/dag-width.sh` over the union of explicit + synthetic `blockedBy` edges).
The ladder follows the Anthropic tool idiom: the lightest mechanism that fits the
available concurrency wins, and the heaviest (Workflow) requires explicit opt-in.

| W (DAG width) | Mechanism | Why |
|---|---|---|
| any W, `LOOP_SPEC_EXECUTE_LOOPS=1` + `claude` CLI | **loop fleet** | explicit opt-in: bounded headless loops, per-iteration verify, SPEC/PLAN hash-locked (`skills/shared/execute-loop-fleet.md`) |
| `W == 1` | **subagent, sequential** | no concurrency to exploit; one `Agent` per task, lead merges inline |
| `2 <= W < t_team` | **subagent, batched** | modest fan-out; a wave of parallel `Agent` calls, no persistent team |
| `t_team <= W < t_wf` | **agent team** | high concurrency with rework/idle-wake coordination pays for the team |
| `t_team <= W`, teams unavailable + `claude` CLI | **loop fleet** | automatic replacement for the team rung when agent teams are unavailable |
| `W >= t_wf` **and** opted in **and** available | **workflow** | undeniable fan-out ROI; deterministic DAG via `execute-dag.js` |

Thresholds (fixed): `t_team = 3`, `t_wf = 6`.

- `W` is measured **uncapped** (independent of `maxParallelImplementers`); it
  reflects the parallelism the DAG structurally exposes. `maxParallelImplementers`
  still caps the width of each dispatched wave within the chosen mechanism.
- The **workflow** rung fires only when all three hold: `W >= t_wf`,
  `runtime.json.workflowExecuteOptIn == true` (set from `LOOP_SPEC_EXECUTE_WORKFLOW=1`
  at cycle startup), and `runtime.json.workflowsAvailable == true`. When opt-in is
  off, the ladder tops out at the agent-team rung regardless of width -- Workflow is
  never selected silently.
- A dependency cycle (`lib/dag-width.sh` exit 3) is a deadlock, not a width signal;
  EXECUTE escalates rather than picking a rung.

## Conversational rounds (DISCUSS - AUTO style)

Round cap: 5 (AUTO style). STEP / INTERACTIVE styles: unlimited.

## Workflow params (fan-out width, fixed)

Used by skills that dispatch dynamic workflows (`Workflow({scriptPath, args})`) at
fan-out points. See `skills/shared/dispatch-fanout.md` for the dispatch contract. When
the orchestrator session lacks the `Workflow` tool (`runtime.json.workflowsAvailable=false`),
these params are unused and the fallback team path runs.

| Param | Value |
|---|---|
| refuteVoters | 3 |
| planAngles | 3 |
| dimensionReviewers | 3 |
| completenessCritic | true |

## Model selection

Fixed; see `skills/shared/model-matrix.md`. Opus authors and judges (spec-writer,
planner, advocate, challenger, spec-compliance-reviewer, iterate-judge, code-reviewer);
sonnet implements, verifies mechanically, and maps.
