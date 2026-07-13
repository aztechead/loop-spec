# Operating Parameters (single-tier)

Single-tier operation (v2.5.0 hard cutover): the quick/balanced/quality axis is gone.
Gate behavior, severity thresholds, and fan-out width are FIXED. Trivially-scoped work
is handled structurally — by the measured plan (the fast-path
below) and the DAG-width ladder — never by an intent tier inferred from the prompt.
Model selection is fixed and lives in `skills/shared/model-matrix.md`.

## Gate behavior (fixed)

| Gate | Behavior |
|---|---|
| Spec critique | ALWAYS runs — the cheap gate that catches building the wrong thing entirely. Single-critic by default; escalates to the paired debate per the **critique gate ladder** (below) |
| Plan critique | Runs unless the **structural fast-path** holds (below). Single-critic by default; same escalation ladder |
| Spec-compliance gate | runs |
| Acceptance gate | runs |
| Test-tamper scan | runs (fail-fast) |
| Code-review HARD-GATE severity | Critical + Important blocked; Minor → `lib/backlog.sh` (never silently dropped) |
| Decision-coverage + criteria-coverage gates | BLOCK (re-dispatch planner), never advisory |

## Structural fast-path (replaces the old `quick` tier)

Decided AFTER planning, from measured scope — not before, from prompt vibes. The PLAN
critique debate is skipped iff ALL hold:

1. The plan has **<= `fastPathMaxTasks` (default 2)** tasks, AND
2. the union of task `files[]` touches **<= `fastPathMaxFiles` (default 3)** files, AND
3. neither SPEC.md nor PLAN.md matches the security-signal pattern:
   `auth|authenticat|authoriz|permission|credential|secret|token|crypt|payment|billing|PII|migrat|delet`

The two bounds are read through the repo tuning overlay (below); with no tuning
they ARE 2 and 3.

When skipped, log one line: `plan critique skipped (structural fast-path: {N} tasks, {M} files, no security signal)`.
Everything else (spec critique, compliance, acceptance, code review, tamper scan) still runs.

## Critique gate ladder (skip → single-critic → escalated debate)

Both critique gates (DISCUSS spec-critique, PLAN plan-critique) climb the same ladder —
the lightest mode that preserves strictness wins:

1. **Skip** — PLAN only, via the structural fast-path above. The spec critique never skips.
2. **Single-critic (the default)** — one challenger (opus) reviews the artifact solo and
   reports `[major]`/`[minor]`-tagged findings straight to the lead
   (`skills/shared/team-prompts/critic.md`). No advocate is dispatched; the lead
   adjudicates. Strictness is preserved by construction: the lead may accept any finding
   into the fix-list, but may NOT unilaterally dismiss a `[major]` finding — disputing one
   escalates to the debate instead. A solo gate can only bias stricter, never looser.
3. **Escalated debate** — the full advocate + challenger paired protocol
   (`maxCritiqueRounds = 2`), exactly as each phase skill writes it. Escalation triggers:
   - **Security signal**: the artifact (SPEC.md or PLAN.md) matches the security-signal
     pattern from the structural fast-path — start in debate mode directly.
   - **Contested major**: the lead disputes a `[major]` finding from the solo critic.
   - **Deadlock**: the same finding survives two consecutive delta re-verify rounds
     (author and critic are stuck; the debate is the tiebreak).

**Delta re-verify (revisions, both modes):** after the author applies a fix-list, the gate
does NOT re-run its full protocol. The lead sends the critic ONE message — the applied
fix-list plus a unified diff of the artifact — and the critic confirms each item is
addressed and checks the changed sections only (`DELTA-VERIFIED` / `DELTA-FINDINGS`).
Retries stay unbounded (full bore); only the per-revision cost collapses from a fresh
2-round debate to a single scoped turn.

## Team coordination params (fixed)

| Param | Value |
|---|---|
| discuss.maxCritiqueRounds | 2 (escalated debate only) |
| plan.maxCritiqueRounds | 2 (escalated debate only) |
| execute.maxParallelImplementers | 3 |
| execute.maxRetriesPerTask | 2 |

## Repo tuning overlay (`.loop-spec/tuning.json`, ROADMAP-3.0 B2)

"Fixed" means fixed by default, not unadjustable: `lib/tuning.sh` may overlay a
CLOSED set of parameter adjustments per repo, from deterministic triggers over
the committed metrics contract (`lib/status.sh metrics`) — the model can never
author an adjustment, deltas are one bounded step, loosening reverts on the
first contrary signal, and `LOOP_SPEC_TUNING=0` disables the overlay entirely.
Phase skills read the effective value at use time:

```bash
TUNE="${CLAUDE_SKILL_DIR}/../../lib/tuning.sh"
FP_TASKS="$(bash "$TUNE" get fastPathMaxTasks 2)"       # PLAN fast-path bound (loosen)
FP_FILES="$(bash "$TUNE" get fastPathMaxFiles 3)"       # PLAN fast-path bound (loosen)
DISCUSS_ROUNDS="$(bash "$TUNE" get discussMaxCritiqueRounds 2)"  # tighten only
PLAN_ROUNDS="$(bash "$TUNE" get planMaxCritiqueRounds 2)"        # tighten only
EXEC_RETRIES="$(bash "$TUNE" get executeMaxRetriesPerTask 2)"    # tighten only
bash "$TUNE" has-check suite-regression   # VERIFY: regression scan mandatory?
```

Anything not listed in `lib/tuning.sh`'s template set stays literally fixed.

## Iteration limit (fixed; mirrors `lib/feature-init.sh`)

Full-bore operation: gate retries are unbounded (every attempt still lands in
`gateHistory`). The ONE bound the cycle respects:

| Limit | Value |
|---|---|
| iterate.maxIterations | 10 |

## EXECUTE concurrency ladder

The EXECUTE phase chooses its dispatch mechanism by the structural width `W` of
the task DAG (peak antichain across a topological wave simulation, computed by
`lib/dag-width.sh` over the union of explicit + synthetic `blockedBy` edges).
The ladder follows the Anthropic tool idiom: the lightest mechanism that fits the
available concurrency wins, and the heaviest (Workflow) requires explicit opt-in.

| W (DAG width) | Mechanism | Why |
|---|---|---|
| any W, `LOOP_SPEC_EXECUTE_LOOPS=1` + agent CLI | **loop fleet** | explicit opt-in: bounded headless loops, per-iteration verify, SPEC/PLAN hash-locked (`skills/shared/execute-loop-fleet.md`) |
| any W, no subagent harness (pi) | **inline** (rung 0) | no `Agent` tool exists; the lead executes tasks itself (`skills/shared/execute-inline.md`); at `t_team <= W` with the agent CLI on PATH the loop fleet takes it instead |
| `W == 1` | **subagent, sequential** | no concurrency to exploit; one `Agent` per task, lead merges inline |
| `2 <= W < t_team` | **subagent, batched** | modest fan-out; a wave of parallel `Agent` calls, no persistent team |
| `t_team <= W < t_wf` | **agent team** | high concurrency with rework/idle-wake coordination pays for the team |
| `t_team <= W`, teams unavailable + agent CLI | **loop fleet** | automatic replacement for the team rung when agent teams are unavailable |
| `W >= t_wf` **and** opted in **and** available | **workflow** | undeniable fan-out ROI; deterministic DAG via `execute-dag.js` |

Thresholds (fixed): `t_team = 3`, `t_wf = 6`. The "agent CLI" is the running
harness's own headless binary (`claude`, `pi`, or `opencode`), resolved by
`lib/harness.sh cli`; the fleet always spawns the harness it is running under.
Under opencode the subagent rungs stay live — its `task` tool shares the `Agent`
call shape (`skills/shared/opencode-harness.md`); the team and workflow rungs
remain Claude Code-only.

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
