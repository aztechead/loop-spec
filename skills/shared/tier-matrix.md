# Tier Policy

Controls gate behavior, severity thresholds, retry budgets, and fan-out width. Model selection is fixed and lives in `skills/shared/model-matrix.md` (no preset axis).

## Gate behavior

| Gate | quality | balanced | quick |
|---|---|---|---|
| Spec critique (advocate + challenger) | runs | runs | **SKIPPED** |
| Plan critique (advocate + challenger) | runs | runs | **SKIPPED** |
| Spec-compliance gate | runs | runs | **SKIPPED** |
| Acceptance gate | runs | runs | runs |
| Code-review HARD-GATE severity | Critical + Important blocked | Critical + Important blocked | Critical only blocked |

## Team coordination params

| Param | quality | balanced | quick |
|---|---|---|---|
| discuss.maxCritiqueRounds | 3 | 2 | 1 |
| plan.maxCritiqueRounds | 3 | 2 | 1 |
| execute.maxParallelImplementers | 4 | 3 | 2 |
| execute.maxRetriesPerTask | 3 | 2 | 1 |

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
| `t_team <= W < t_wf` | **agent team** | high concurrency with rework/idle-wake coordination pays for `TeamCreate` |
| `t_team <= W`, teams unavailable + `claude` CLI | **loop fleet** | automatic replacement for the team rung when `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` is not enabled |
| `W >= t_wf` **and** opted in **and** available | **workflow** | undeniable fan-out ROI; deterministic DAG via `execute-dag.js` |

Thresholds:

| Param | quality | balanced | quick |
|---|---|---|---|
| t_team | 3 | 3 | 4 |
| t_wf | 6 | 6 | 8 |

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

## Conversational rounds (DISCUSS  -  AUTO style)

| Tier | Round cap |
|------|-----------|
| quality | 3 |
| balanced | 2 |
| quick | 1 |

STEP / INTERACTIVE styles: unlimited on all tiers.

## Workflow params (fan-out width)

Used by skills that dispatch dynamic workflows (`Workflow({scriptPath, args})`) at
fan-out points. Passed to the script as `args.workflowParams`. See
`skills/shared/dispatch-fanout.md` for the dispatch contract. When the orchestrator
session lacks the `Workflow` tool (`runtime.json.workflowsAvailable=false`), these
params are unused and the fallback TeamCreate path runs.

| Param | quality | balanced | quick |
|---|---|---|---|
| refuteVoters | 5 | 3 | 1 |
| planAngles | 5 | 3 | 1 |
| dimensionReviewers | 4 | 3 | 1 |
| completenessCritic | true | true | false |

## Model selection

Fixed; there is no preset axis. See `skills/shared/model-matrix.md`. Tier controls
gate behavior, retries, and fan-out width only; it never affects which model a role
runs on.
