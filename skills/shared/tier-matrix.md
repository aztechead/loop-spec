# Operating parameters (single-tier)

There is no quality tier: gate behavior, severity thresholds, and fan-out width are
fixed, and trivially-scoped work is lightened structurally, by the measured plan and the
DAG width, never by an intent inferred from the prompt. Role defaults and override
precedence are `model-matrix.md`.

## Gates (fixed)

| Gate | Behavior |
|---|---|
| Spec critique | Challenger-only. `lib/phase-mode.sh discuss` skips it when `lib/graph/probes/discuss-critique.sh` answers skip (already-gated SPEC or maintenance, no security signal); ITERATE re-entry always runs. |
| Plan critique | Challenger-only. `lib/phase-mode.sh plan` skips it on the structural fast-path, the maintenance profile, or a compact gate plan, never on a security signal. |
| Spec-compliance, acceptance, test-tamper, placeholder | run (tamper and placeholder fail fast) |
| Code-review HARD-GATE | Critical and Important block; Minor goes to `lib/backlog.sh`, never dropped |
| Decision-coverage, criteria-coverage, feasibility, grounding | BLOCK (`lib/phase-exit.sh plan`), never advisory |

**Structural fast-path** (decided after planning, from measured scope): the plan
critique is skipped only when the plan has at most `fastPathMaxTasks` (2) tasks, the
union of task `files[]` is at most `fastPathMaxFiles` (3) files, AND
`lib/security-signal.sh first SPEC.md PLAN.md` finds nothing (a bare `auth` must be a
whole word). Both bounds read through the tuning overlay.

**Maintenance profile** (decided before any phase by `lib/cycle-profile.sh select` from
a validated low-risk classification, or an explicit `profile:` / `LOOP_SPEC_CYCLE_PROFILE`
override; persisted as `feature.json.executionProfile`): SPEC synthesizes instead of
interviewing (the ambiguity gate still scores and falls back to the interview when a
dimension misses its minimum); the graph short path (`lib/graph/probes/short-path.sh`)
routes around `discuss`, the spec critique, and the `verify.code-review` agent when no
security signal appears in the written artifacts. Same graph, same ledger, same terminal
result; the signal is re-read from the artifacts that exist now, so a change that turns
out to touch a security surface lengthens its own path. Every other VERIFY gate runs on
both paths.

**Critique ladder**: skip (above) or a single critic. There is no advocate and no debate.
The lead may accept any finding and may never drop a `[major]`; a solo gate biases only
stricter. A revision gets a delta re-verify (fix-list plus diff), never a full re-run. Delta
rounds are bounded by the loop ceiling `graph/critique.graph.json` declares;
`lib/graph/gate.sh next` reads it and closes the gate with `cap-reached` when it is
spent or one finding survives two consecutive delta rounds
(`critique-gate-protocol.md`). `LOOP_SPEC_CRITIQUE_ROUNDS` outranks the graph.

## Parameters (fixed; `.loop-spec/tuning.json` may overlay a closed set)

| Param | Value |
|---|---|
| execute.maxParallelImplementers | 3 |
| execute.maxRetriesPerTask | 6 |
| iterate.maxIterations | 10 |
| critique delta rounds | the `critique.adjudicate` -> `critique.challenge` loop ceiling in `graph/critique.graph.json` (`LOOP_SPEC_CRITIQUE_ROUNDS` overrides; `0` = unbounded) |
| fastPathMaxTasks / fastPathMaxFiles | 2 / 3 |
| DISCUSS `auto` rounds | 5 (`step`/`interactive`: unlimited) |
| Workflow fan-out (refuteVoters, planAngles, dimensionReviewers) | 3 / 3 / 3, completenessCritic on |

`lib/tuning.sh` overlays from deterministic triggers over `lib/status.sh metrics`: the
model never authors an adjustment, deltas are one bounded step, loosening reverts on the
first contrary signal, and `LOOP_SPEC_TUNING=0` disables it. Phase skills read the
effective value at use time (`bash "$TUNE" get fastPathMaxTasks 2`,
`get executeMaxRetriesPerTask 6`, `has-check suite-regression`).

## EXECUTE concurrency ladder

`W` is the DAG's peak antichain width (`lib/dag-width.sh` over explicit plus synthetic
`blockedBy` edges), measured uncapped; `maxParallelImplementers` caps each wave.
`lib/execute-rung.sh select` answers:

| W | Mechanism |
|---|---|
| any, `LOOP_SPEC_EXECUTE_LOOPS=1` + agent CLI + persistent runtime | loop fleet (`execute-loop-fleet.md`) |
| any, no subagent tool | inline (`execute-rungs.md`); the fleet takes it at `W >= t_team` when available |
| `W == 1` | subagent, sequential (`execute-subagent.md`) |
| `2 <= W < t_team` | subagent, batched wave |
| `t_team <= W < t_wf` | agent team (`execute-rungs.md`); teams unavailable → loop fleet when supported, else batched subagents |
| `W >= t_wf`, opted in (`LOOP_SPEC_EXECUTE_WORKFLOW=1`) and available | Workflow DAG; never selected silently |

`t_team = 3`, `t_wf = 6`. The agent CLI is the running harness's own headless binary
(`lib/harness.sh cli`). The subagent rungs stay live under opencode (`task`,
`opencode-harness.md`) and Codex (`spawn_agent`, `codex-harness.md`); the team and
Workflow rungs are Claude Code only. A dependency cycle (`dag-width.sh` exit 3) is a
deadlock escalation, not a width.
