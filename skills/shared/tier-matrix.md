# Operating Parameters (single-tier)

Single-tier operation (v2.5.0 hard cutover): the quick/balanced/quality axis is gone.
Gate behavior, severity thresholds, and fan-out width are FIXED. Trivially-scoped work
is handled structurally — by the measured plan (the fast-path
below) and the DAG-width ladder — never by an intent tier inferred from the prompt.
Canonical role defaults and phase/role override precedence live in
`skills/shared/model-matrix.md`.

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
3. `lib/security-signal.sh first SPEC.md PLAN.md` finds no bounded security or
   destructive-change term. The helper reports the exact file, line, and matched term;
   a bare `auth` must be a complete word, so benign prose such as `authoritative` does
   not escalate.

The two bounds are read through the repo tuning overlay (below); with no tuning
they ARE 2 and 3.

When skipped, log one line: `plan critique skipped (structural fast-path: {N} tasks, {M} files, no security signal)`.
Everything else (spec critique, compliance, acceptance, code review, tamper scan) still runs.

## Maintenance profile

The structural fast-path measures the PLAN. The maintenance profile measures the TASK,
before any phase runs, and lightens the gate OVERHEAD a low-risk mechanical change does
not need — the remaining cost after the low-overhead map/artifact/state controls.

`lib/cycle-profile.sh select` is the probe. It answers `profile=maintenance` only from a
validated `lib/task-route.sh` classification that is maintenance-shaped
(`taskKind` in docs/config/maintenance), low-ambiguity, at least 0.8 confidence, within 5
reviewable files and 3 acceptance criteria, and carries NO seam, interface, security,
migration, dependency-edge, multi-repo, or destructive flag. Anything unknown reads as
risk. `LOOP_SPEC_CYCLE_PROFILE` and the inline `profile:` token are explicit operator
overrides in both directions. The answer is persisted as
`feature.json.executionProfile`, so a resume keeps the same ladder.

What it lightens:

| Phase | Standard | Maintenance |
|---|---|---|
| SPEC | Socratic interview, up to 6 rounds | Synthesize from the request + scout; the ambiguity gate still scores and still gates, falling back to the interview when a dimension misses its minimum |
| DISCUSS | Critique gate (single-critic, escalating) | Skipped when `lib/security-signal.sh` reports no match |
| PLAN | Critique gate, subject to the structural fast-path | Skipped when `lib/security-signal.sh` reports no match, regardless of the fast-path bounds |

The profile is also the graph's own path selector. `lib/graph/probes/short-path.sh`
answers `path=short` for a maintenance run with no security signal in its written
artifacts, and `graph/cycle.graph.json` routes around three nodes on that answer:
`discuss`, the spec-critique subgraph, and the `verify.code-review` agent. Same graph,
same checkpoint ledger, same terminal result — a shorter declared path, not a different
protocol, and not a `protocol-mismatch` decline. A rebase, branch sync, merge-conflict
resolution, or re-review that `/loop-spec:auto` promoted to full takes this path. The
probe re-reads the signal from the artifacts that exist now, so a change
that turns out to touch a security surface lengthens its own path mid-run.

What it never touches: the ambiguity gate, decision/criteria coverage, the feasibility
check, and every other VERIFY gate — the placeholder scan, the tamper scan, the
acceptance lint, and the no-new-failures comparison all run on both paths. Code review
is the one quality gate the short path drops, and only behind the full maintenance
classification: at most five reviewable files, low ambiguity, and no seam, interface,
security, migration, dependency-edge, multi-repo, or destructive flag. Escalation on a genuine security signal is unchanged —
the signal is checked FIRST on both critique gates, and a match escalates to the debate
on the maintenance profile exactly as it does on the standard one.

## Critique gate ladder (skip → single-critic → escalated debate)

Both critique gates (DISCUSS spec-critique, PLAN plan-critique) climb the same ladder —
the lightest mode that preserves strictness wins:

1. **Skip** — PLAN via the structural fast-path above, and either gate on the maintenance
   profile when no security signal fires. On the standard profile the spec critique never
   skips.
2. **Single-critic (the default)** — one challenger (inheriting the session model) reviews the artifact solo and
   reports `[major]`/`[minor]`-tagged findings straight to the lead
   (`skills/shared/team-prompts/critic.md`). No advocate is dispatched; the lead
   adjudicates. Strictness is preserved by construction: the lead may accept any finding
   into the fix-list, but may NOT unilaterally dismiss a `[major]` finding — disputing one
   escalates to the debate instead. A solo gate can only bias stricter, never looser.
3. **Escalated debate** — the full advocate + challenger paired protocol
   (`maxCritiqueRounds = 2`), exactly as each phase skill writes it. Escalation triggers:
   - **Security signal**: `lib/security-signal.sh` reports evidence in SPEC.md or
     PLAN.md — log that evidence and start in debate mode directly.
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
| any W, `LOOP_SPEC_EXECUTE_LOOPS=1` + agent CLI + persistent runtime | **loop fleet** | explicit opt-in: bounded headless workers, per-iteration verify, SPEC/PLAN hash-locked (`skills/shared/execute-loop-fleet.md`) |
| any W, no subagent harness | **inline** (rung 0) | no subagent tool exists; the lead executes tasks itself (`skills/shared/execute-inline.md`); at `t_team <= W` with both the agent CLI and persistent runtime the loop fleet takes it instead |
| `W == 1` | **subagent, sequential** | no concurrency to exploit; one `Agent` per task, lead merges inline |
| `2 <= W < t_team` | **subagent, batched** | modest fan-out; a wave of parallel `Agent` calls, no persistent team |
| `t_team <= W < t_wf` | **agent team** | high concurrency with rework/idle-wake coordination pays for the team |
| `t_team <= W`, teams unavailable + agent CLI + persistent runtime | **loop fleet** | automatic replacement only when a long-running synchronous tool call is supported |
| `t_team <= W`, teams and loop runtime unavailable | **subagent, batched** | safe universal fallback; waves remain bounded by `maxParallelImplementers` |
| `W >= t_wf` **and** opted in **and** available | **workflow** | undeniable fan-out ROI; deterministic DAG via `execute-dag.js` |

Thresholds (fixed): `t_team = 3`, `t_wf = 6`. The "agent CLI" is the running
harness's own headless binary (`claude`, `opencode`, or `adk`), resolved by
`lib/harness.sh cli`; the fleet always spawns the harness it is running under.
The persistent-runtime probe is separate: one-shot/headless invocations cannot keep
the supervising tool call alive and therefore fall back rather than selecting a fleet.
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

Every role inherits the session model. Optional harness-native routes are described in
`skills/shared/model-matrix.md`; tiers and GDD effort never require a model family.
