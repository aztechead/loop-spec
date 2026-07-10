---
name: plan
description: PLAN phase - creates a plan team; planner produces PATTERNS.md (unless prefetched) then PLAN.md; runs the single-critic critique gate (escalating to an advocate/challenger debate when contested or security-signaled); writes PLAN.md and updates feature.json. Cycle-internal - invoked by /loop-spec:cycle against the active feature's state; not for ad-hoc invocation on a bare user request (start via /loop-spec:cycle).
allowed-tools: Bash Read Write Edit Glob Grep Skill Agent AskUserQuestion TeamCreate TeamDelete SendMessage TaskCreate TaskUpdate TaskList TaskGet ToolSearch Workflow
---

# PLAN Phase

You are the PLAN phase orchestrator. Invoked by `loop-spec:cycle` when `feature.json.currentPhase == "plan"`.

> **No-teams fallback:** if `.loop-spec/runtime.json.teamsAvailable == false`, do NOT
> call `TeamCreate`/`TeamDelete`/`SendMessage` (they throw). Run planner, challenger (and
> advocate, on escalation) as one-shot `Agent` calls with the same agent types, models, and
> prompt templates, per `skills/shared/no-teams-fallback.md`. The single-critic pass and
> each delta re-verify become one-shot challenger Agent calls (fix-list + diff inlined);
> an escalated debate becomes sequential challenger → advocate Agent calls with prior
> round summaries (from `gate-logs/`) inlined. All artifacts and gates are unchanged.

> **Implicit-team harness:** if `.loop-spec/runtime.json.teamsMode == "implicit"` (CC >= 2.1.178),
> do NOT call `TeamCreate`/`TeamDelete` (they were removed and throw). The team already exists:
> spawn planner, advocate, and challenger with `Agent({name, description, subagent_type, model, prompt})`,
> folding each one's first work prompt into the spawn, then run the critique debate with
> `SendMessage` as written. Per `skills/shared/implicit-team-mode.md`. `SendMessage` and the
> shared task list are unchanged.

## Inputs (from cycle skill via feature.json)

- `slug`, `execStyle`
- `feature_dir`: `.loop-spec/features/{slug}/`
- `feature_json_path`: `.loop-spec/features/{slug}/feature.json`
- `spec_path`: from `feature.json.artifacts.spec`
- `plan_path`: `docs/loop-spec/features/{slug}/PLAN.md` (equals `feature.json.artifacts.plan`); bound here so the Step 5.5 decision-coverage call has a real path
- Required: `docs/loop-spec/codebase/*.md` (cycle skill guarantees these exist before PLAN starts)

**ITERATE re-entry:** if `feature.json.iterate.feedback` is non-null, this is a re-plan triggered by the ITERATE convergence loop (the judge classified a `plan`-type gap). Read that feedback first and target the named gap — revise or add only the tasks needed to close it (fix the weakest point first); do NOT re-author the whole plan from scratch. Preserve the `## User decisions (already made)` record. Clear `iterate.feedback` is the orchestrator's job after the phase routes, not yours.

## Procedure

### Step 0 - PATTERNS.md cache check and GSD ingestion

Before spawning the team: join the DISCUSS background prefetch if one is in flight (`artifacts.patternsPrefetch == "in-flight"`, bounded 120s wait); then if `docs/loop-spec/features/{slug}/PATTERNS.md` already exists, record it in `feature.json.artifacts` and skip production; else attempt GSD `.planning/codebase/` ingestion; else the planner produces PATTERNS.md at its own Step 0. Exact prefetch-join/cache/ingest procedure and artifact bookkeeping verbatim in `${CLAUDE_SKILL_DIR}/references/patterns-bootstrap.md`.

**Greenfield plans (`feature.json.greenfield == true`).** There are no codebase analogs: PATTERNS.md records the chosen stack's canonical conventions (project layout, test placement, naming) from SPEC.md's Foundations requirements instead of mined analogs, marked `Source: stack conventions (greenfield)`. The task DAG MUST lead with **task-001 = scaffold**: initialize the project structure, dependency manifest, test harness, and a passing walking-skeleton test; its `verifyCommand` is the stack's canonical test command from SPEC.md, and EVERY other task is `blockedBy: ["task-001"]` (directly or transitively). No task may assume tooling that task-001 does not create. After task-001 merges, EXECUTE backfills `feature.commands.*` (see `skills/execute/SKILL.md`) so later tasks and VERIFY run real commands.

### Step 1 - TeamCreate the plan team

```
TeamCreate({
  name: "loop-spec-plan-{slug}",
  teammates: [
    { name: "planner-1",    subagent_type: "loop-spec:planner",    model: feature.models.planner },
    { name: "advocate-1",   subagent_type: "loop-spec:advocate",   model: feature.models.advocate },
    { name: "challenger-1", subagent_type: "loop-spec:challenger", model: feature.models.challenger }
  ]
})
```

Each teammate object MUST include `subagent_type` (binds to the role definition in `agents/*.md`) and `model` (read literally from `feature.models.<role>`; see `skills/shared/model-matrix.md`).

Update `feature.json` via `lib/feature-write.sh`:
- `currentTeamName = "loop-spec-plan-{slug}"`
- `currentTeammates = ["planner-1", "advocate-1", "challenger-1"]`

#### Warm up the critic while the planner authors

Send challenger-1 a warm-up brief so it loads context concurrently with plan authoring instead of starting its findings pass cold (if the structural fast-path later skips the critique, the warm-up cost is one idle context load — acceptable). Do NOT warm up advocate-1: the gate is single-critic by default and the advocate runs only on escalation (`skills/shared/tier-matrix.md`, critique gate ladder) — an eager advocate warm-up is a wasted dispatch on the common path.

```
SendMessage({
  to: "challenger-1",
  message: "Warm-up only: read SPEC.md at {spec_path} and the codebase maps at docs/loop-spec/codebase/*.md now to load context. Do NOT read PLAN.md or PATTERNS.md yet -- they are still being authored and may not exist. Prepare your critique checklist from the spec and maps, then go idle and wait for the lead's findings-pass prompt."
})
```

### Plan authoring (workflow path or fallback)

Read `.loop-spec/runtime.json`. If `workflowsAvailable=true` AND
`LOOP_SPEC_PLAN_MULTI_ANGLE=1` (explicit opt-in; single-tier operation has no quality tier to key on), dispatch:

```text
Workflow({
  scriptPath: "${CLAUDE_SKILL_DIR}/../../lib/workflows/plan-multi-angle.js",
  args: {
    specPath: feature.artifacts.spec,
    patternsPath: feature.artifacts.patterns,
  }
})
```

Result: `{plan: <markdown>, angles: [...], winner}`. Skill writes `plan` to
`docs/loop-spec/features/{slug}/PLAN.md` and logs `angles` to
`.loop-spec/features/{slug}/gate-logs/plan-multi-angle.json`.

If `workflowsAvailable=false` OR the opt-in is unset, fall through to the
existing single-planner Agent dispatch below.

**Dispatch telemetry (`skills/shared/dispatch-events.md`):** emit one `dispatch` event per teammate actually launched in this phase (planner, pattern-mapper, challenger; advocate only when the gate escalates) — `bash "${CLAUDE_SKILL_DIR}/../../lib/events.sh" emit ".loop-spec/features/${slug}" dispatch --phase "plan" --data '{"role":"<role>","model":"<resolved alias>","rung":"team"}' || true`. One event per LAUNCH; `SendMessage` rework rounds and delta re-verifies do not re-emit.

### Step 2 - Spawn planner-1

Model: `feature.models.planner` (resolved once at cycle Step 5; do not re-derive from model-matrix).

```
SendMessage({
  to: "planner-1",
  message: """
    You are planner-1 in team loop-spec-plan-{slug}.

    slug: {slug}
    spec_path: {spec_path}
    patterns_path: docs/loop-spec/features/{slug}/PATTERNS.md
    codebase_mapping_paths: {paths to docs/loop-spec/codebase/*.md}
    evidence_path: docs/loop-spec/features/{slug}/EVIDENCE.md

    Every fact asserted about an external system in PLAN.md must cite an `EVID-NNN` entry from the evidence_path ledger or be written as an explicit `ASSUMPTION: <claim> | verify: <command>` per `skills/shared/grounding-protocol.md`.

    FIRST: If docs/loop-spec/features/{slug}/PATTERNS.md does not exist, produce it now.
    Analyze the codebase for concept analogs per the spec, following the pattern-mapper role
    definition at agents/pattern-mapper.md. Write to
    docs/loop-spec/features/{slug}/PATTERNS.md.

    THEN: Read PATTERNS.md; cite concept analogs in each task's Steps so implementers know
    which existing code to mirror. Produce PLAN.md at docs/loop-spec/features/{slug}/PLAN.md
    per your role definition. Return tasks[] as structured JSON in your completion message.
    Do NOT compute or return waves[] -- EXECUTE Step 2b derives synthetic blockedBy edges
    from file overlap, so wave assignment is no longer your responsibility.

    PRE-SUBMIT SELF-CHECK (you are graded on these by automated gates after you return; a
    failure here forces a re-dispatch round, so verify before sending):
      1. Every task's verify command passes `bash -n -c "$cmd"` (no empty or malformed commands).
      2. The blockedBy graph is acyclic.
      3. Every task has at least one acceptance criterion in the REQUIRED CONCRETE FORM from
         your role definition (an exact value, regex, exit code, file path, or grep/jq check).
      4. Each task's files[] is scoped to what that task actually edits; declare a logical
         blockedBy edge wherever two tasks would otherwise need the same file (EXECUTE derives
         file-overlap edges automatically, so you only declare the logical ones).
      5. For each entry in the SPEC <decisions> block, reproduce the decision text verbatim
         (the part after the "- "/"Decision: " prefix) somewhere in PLAN.md -- a "## Decisions"
         or "## Assumptions" section is fine -- so the automated decision-coverage check
         (fixed-string grep) matches.

    When done, send:
      SendMessage({to: "lead", message: "PATTERNS.md and PLAN.md written\n\n<tasks JSON>"})
    then go idle.
  """
})
```

Wait for `TeammateIdle` from `planner-1`. If `planner-1` goes idle without producing both `PATTERNS.md` and `PLAN.md`:
- Send `SendMessage({to: "planner-1", message: "Check docs/loop-spec/features/{slug}/PATTERNS.md and docs/loop-spec/features/{slug}/PLAN.md -- one or both are missing. Produce any missing files now and include tasks[] JSON in your completion message."})` once.
- If still idle without output on second idle, escalate to user via `AskUserQuestion`. Autonomous mode (`feature.json.autonomous`): re-dispatch the teammate fresh ONCE; if that also produces nothing, the lead authors PATTERNS.md + PLAN.md itself from the same brief and continues, noting `lead-authored` in `warnings[]` — never wait on a human, and never treat the warning as the handler (`skills/shared/autonomous-mode.md`, continuation ladder).

On `PATTERNS.md and PLAN.md written` message received: update `feature.json` via `lib/feature-write.sh` — nested `set` takes the dot path directly, value JSON-quoted, never raw jq (`skills/shared/feature-state-schema.md` "Writing rules"):

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" set "$fdir" artifacts.patterns '"docs/loop-spec/features/'"${slug}"'/PATTERNS.md"'
bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" set "$fdir" artifacts.patternsSource '"pattern-mapper"'
```

Parse the `tasks[]` JSON from the message body. Store for use in Steps 3 and 4.

Proceed to Step 3.

### Step 3 - Critique gate (structural fast-path may skip; single-critic default)

**Structural fast-path (replaces the old quick tier — measured scope, decided AFTER planning):** resolve the two bounds through the repo tuning overlay first (`FP_TASKS="$(bash "${CLAUDE_SKILL_DIR}/../../lib/tuning.sh" get fastPathMaxTasks 2)"`, `FP_FILES="$(bash "${CLAUDE_SKILL_DIR}/../../lib/tuning.sh" get fastPathMaxFiles 3)"` — defaults 2/3 unless `lib/tuning.sh` widened them for this repo; `skills/shared/tier-matrix.md` "Repo tuning overlay"). Skip this critique gate iff ALL hold: the plan has <= {FP_TASKS} tasks, AND the union of task `files[]` touches <= {FP_FILES} files, AND neither SPEC.md nor PLAN.md matches the security-signal pattern `auth|authenticat|authoriz|permission|credential|secret|token|crypt|payment|billing|PII|migrat|delet` (case-insensitive grep). When skipped, log one line: `plan critique skipped (structural fast-path: {N} tasks, {M} files, no security signal)` and go to Step 4b (feasibility still runs).

When not skipped, the gate runs per the **critique gate ladder** (`skills/shared/tier-matrix.md`): single-critic by default, escalating to the paired debate only when triggered.

Update `feature.json` via `lib/feature-write.sh`:
```json
{
  "currentGate": {
    "phase": "plan",
    "gate": "plan-critique",
    "round": 0,
    "advocateName": "advocate-1",
    "challengerName": "challenger-1",
    "startedAt": "<ISO-8601 now>"
  }
}
```

Create the gate-logs directory:
```bash
mkdir -p .loop-spec/features/{slug}/gate-logs/
```

#### Mode selection (security signal)

The fast-path check above already grepped SPEC.md and PLAN.md for the security-signal pattern. If it matched (which is why the fast-path did not fire on an otherwise small plan, or on any larger plan): `gate_mode="debate"` — start directly in the **Escalated debate** below. Otherwise `gate_mode="single-critic"`.

#### Single-critic pass (default)

Model: `feature.models.challenger`. Send `challenger-1` the solo-critic brief:

```
SendMessage({
  to: "challenger-1",
  message: """
    [Populate from skills/shared/team-prompts/critic.md with these substitutions:
      {slug} = slug
      {N} = 1
      {phase} = plan
      {artifact} = PLAN.md
    ]

    Run your findings pass on PLAN.md now and report to lead.
  """
})
```

Wait for `TeammateIdle` from `challenger-1` and read its `FINDINGS:` / `NO-FINDINGS:` message. Write it to the gate-log:

```
Write .loop-spec/features/{slug}/gate-logs/plan-critique-round-1.md
Contents:
  # plan-critique Round 1 (single-critic)

  ## challenger-1
  <the FINDINGS/NO-FINDINGS message body>
```

Emit the round's telemetry event (non-fatal):
```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/events.sh" emit ".loop-spec/features/${slug}" gate_round \
  --phase "plan" --data '{"gate":"plan-critique","round":1,"mode":"single-critic"}' || true
```

Proceed to Step 4 (the lead adjudicates the findings there).

#### Escalated debate

Runs only when a ladder trigger fires (security signal above; contested `[major]` or delta deadlock from Step 4). `maxCritiqueRounds = 2` (fixed; `skills/shared/tier-matrix.md`). When escalating from a single-critic pass, include all existing `gate-logs/plan-critique-round-*.md` content as `{prior_round_summaries}` in both spawn prompts, and note that `challenger-1` is already live — re-send it the debate brief via `SendMessage` instead of spawning fresh.

##### Spawn advocate-1

Model: `feature.models.advocate`.

```
SendMessage({
  to: "advocate-1",
  message: """
    [Populate from skills/shared/team-prompts/advocate.md with these substitutions:
      {slug} = slug
      {N} = 1
      {phase} = plan
      {artifact} = PLAN.md
      {maxRounds} = maxCritiqueRounds
      {N_round} = 1
      {prior_round_summaries} = (empty on first run; load from gate-logs/ on resume)
    ]

    You will receive the first message from challenger-1. Wait for it before starting your round-1 response.
  """
})
```

##### Spawn challenger-1

Model: `feature.models.challenger`.

```
SendMessage({
  to: "challenger-1",
  message: """
    [Populate from skills/shared/team-prompts/challenger.md with these substitutions:
      {slug} = slug
      {N} = 1
      {phase} = plan
      {artifact} = PLAN.md
      {maxRounds} = maxCritiqueRounds
      {N_round} = 1
      {prior_round_summaries} = (empty on first run; load from gate-logs/ on resume)
    ]

    Start round 1 now: read PLAN.md and send your critique to advocate-1 via SendMessage.
    After sending to advocate-1, wait for their response before sending your ROUND-1 DONE message to lead.
  """
})
```

##### Debate loop

For each round N = 1 .. maxCritiqueRounds:

1. Update `feature.json.currentGate.round = N` via `lib/feature-write.sh`.

2. Wait for `TeammateIdle` from `advocate-1` (which signals it has sent both its cross-debate message and its lead round-end message for round N).

3. Wait for `TeammateIdle` from `challenger-1` (same condition).

4. Read the two `ROUND-N DONE[...]` messages sent to `lead` (one from `advocate-1`, one from `challenger-1`).

5. Append each message to the gate-log:
   ```
   Write .loop-spec/features/{slug}/gate-logs/plan-critique-round-{N}.md
   Contents:
     # plan-critique Round {N}

     ## advocate-1
     <advocate-1's ROUND-N DONE[...] message body>

     ## challenger-1
     <challenger-1's ROUND-N DONE[...] message body>
   ```

6. Emit the round's telemetry event (non-fatal):
   ```bash
   bash "${CLAUDE_SKILL_DIR}/../../lib/events.sh" emit ".loop-spec/features/${slug}" gate_round \
     --phase "plan" --data "{\"gate\":\"plan-critique\",\"round\":{N}}" || true
   ```

7. Convergence check:
   - **Mutual DONE**: both messages start with `ROUND-{N} DONE:` (not `DONE-WITH-ISSUES`). Break loop.
   - **One-sided DONE for two consecutive rounds**: one teammate sent `ROUND-{N} DONE:` in both round N and round N-1 while the other sent `DONE-WITH-ISSUES`. Break loop.
   - **Cap reached**: N == maxCritiqueRounds. Record `notes: "cap reached"` in gateHistory. Break loop.
   - Otherwise: N += 1. Send `SendMessage` to both teammates starting round N+1:
     ```
     SendMessage({to: "challenger-1", message: "Start round {N+1}. Read PLAN.md and send your round {N+1} critique to advocate-1."})
     SendMessage({to: "advocate-1", message: "Round {N+1} starting. Wait for challenger-1's critique, then respond."})
     ```

### Step 4 - Adjudicate findings and synthesize fix-list

Read all files under `.loop-spec/features/{slug}/gate-logs/` matching `plan-critique-round-*.md`.

**Single-critic adjudication (default mode):**

| Situation | Action |
|-----------|--------|
| `[major]` finding the lead agrees with | Add to fix-list. |
| `[major]` finding the lead disputes | Do NOT drop it — ESCALATE to the full debate (Step 3, Escalated debate) with all gate-logs as prior summaries. The debate is the tiebreak; a solo gate may only bias stricter, never looser. |
| `[minor]` finding | Lead's judgment: add to fix-list or drop. Every dropped `[minor]` is logged in the gate-log with a one-line reason — never silently. |
| Finding depends on user intent | Escalate via `AskUserQuestion`. Autonomous mode (`feature.json.autonomous`): no escalation — adopt the more reversible reading, record it to disk (`bash "${CLAUDE_SKILL_DIR}/../../lib/decisions.sh" add "{feature_dir}" plan "<question>" "<reading adopted>" "more reversible"`) AND in `## User decisions (already made)` suffixed `(assumed)` (`skills/shared/autonomous-mode.md`), and add it to the fix-list. |
| Finding is an `UNGROUNDED:` line (ungrounded external claim) | Lead runs the suggested read-only probe ITSELF (teammates have no Bash), appends it via `bash "${CLAUDE_SKILL_DIR}/../../lib/evidence.sh" add "docs/loop-spec/features/{slug}/EVIDENCE.md" "<claim>" "<command>" "<output>"`, and feeds `EVID-NNN` + output excerpt into the planner re-dispatch so planner-1 cites it (or converts the claim to an ASSUMPTION if the probe is impossible). |

**Escalated-debate reconciliation (when the debate ran):**

| Situation | Action |
|-----------|--------|
| Challenger raises point advocate also flagged as risk | High-confidence. Add to fix-list. |
| Challenger raises point advocate explicitly defended | Evaluate; pick the stronger argument. Add to fix-list if challenger wins. |
| Both agree | No action. |
| Neither resolves (depends on user intent) | Same user-intent row as above. |
| `UNGROUNDED:` line | Same probe row as above. |

Build `fix_list` (may be empty).

#### If fix_list non-empty:

Gate retries are unbounded (full bore): re-run the fix/debate loop until the gate passes. The only bound the cycle respects is ITERATE's round limit.

Append the fail entry to `feature.json.gateHistory` via `lib/feature-write.sh` BEFORE re-dispatching (the re-dispatch path returns to Step 3 and would never reach an append placed after the return):

```json
{
  "phase": "plan",
  "gate": "plan-critique",
  "attempt": <attempt number>,
  "result": "fail",
  "advocateModel": "<model | null when the gate never escalated>",
  "challengerModel": "<model>",
  "rounds": <N (single-critic: 1 + delta rounds)>,
  "convergence": "<single-critic | delta-verified | mutual-done | cap-reached | one-sided>",
  "findingsAddressed": [<fix_list items>],
  "notes": null
}
```

Snapshot PLAN.md before sending the fix-list (feeds the delta re-verify diff):

```bash
cp docs/loop-spec/features/{slug}/PLAN.md .loop-spec/features/{slug}/gate-logs/PLAN.pre-revision.md
```

Re-dispatch planner-1 via `SendMessage` (not a fresh Agent call):
```
SendMessage({
  to: "planner-1",
  message: """
    PLAN.md needs revisions. Fix-list:
    {fix_list items, numbered}

    Read the current PLAN.md at docs/loop-spec/features/{slug}/PLAN.md.
    Apply all items on the fix-list. Write the updated PLAN.md in place.
    When done: SendMessage({to: "lead", message: "PATTERNS.md and PLAN.md written\n\n<tasks JSON>"})
    then go idle.
  """
})
```

Wait for `TeammateIdle` from `planner-1`. When `PATTERNS.md and PLAN.md written` is received, parse the updated `tasks[]` JSON. Then run the **delta re-verify** — do NOT re-run the full gate protocol (`skills/shared/tier-matrix.md`, critique gate ladder):

```bash
diff -u .loop-spec/features/{slug}/gate-logs/PLAN.pre-revision.md \
        docs/loop-spec/features/{slug}/PLAN.md > /tmp/plan-delta.diff || true
```

```
SendMessage({
  to: "challenger-1",
  message: """
    Delta re-verify (per your solo-critic brief). The fix-list below was applied to PLAN.md.
    Confirm each item is addressed and check the CHANGED sections only for new issues.

    Fix-list applied:
    {fix_list items, numbered}

    Diff:
    {content of /tmp/plan-delta.diff}

    Reply to lead with DELTA-VERIFIED or DELTA-FINDINGS, then go idle.
  """
})
```

Wait for `TeammateIdle` from `challenger-1`, append the reply to a new `gate-logs/plan-critique-round-{next}.md` (titled `(delta re-verify)`), and emit a `gate_round` event with `"mode":"delta"`:

- **`DELTA-VERIFIED`**: the gate passes — append the `gateHistory` pass entry (convergence: `"delta-verified"`), reset `currentGate` (as in the fix_list-empty branch below), and proceed to Step 4b.
- **`DELTA-FINDINGS`**: adjudicate the tagged findings per the Step 4 rules and start a new fix round (retries are unbounded — full bore). **Deadlock escalation:** if the same finding survives two consecutive delta rounds, escalate to the full debate (Step 3, Escalated debate) with all gate-logs as prior summaries.

(When the escalated debate produced the fix-list, the delta re-verify above still applies — the debate does not re-run for a revision; only a deadlock or a new contested `[major]` re-enters it.)

#### If fix_list empty:

Append to `feature.json.gateHistory` via `lib/feature-write.sh`:
```json
{
  "phase": "plan",
  "gate": "plan-critique",
  "attempt": <attempt number>,
  "result": "pass",
  "advocateModel": "<model | null when the gate never escalated>",
  "challengerModel": "<model>",
  "rounds": <N (single-critic: 1 + delta rounds)>,
  "convergence": "<single-critic | delta-verified | mutual-done | cap-reached | one-sided>",
  "findingsAddressed": [],
  "notes": null
}
```

Reset `currentGate` to zeroed state via `lib/feature-write.sh`:
```json
{
  "currentGate": {
    "phase": null,
    "gate": null,
    "round": 0,
    "advocateName": null,
    "challengerName": null,
    "startedAt": null
  }
}
```

Proceed to Step 4b.

### Step 4b - Feasibility gate (ALWAYS runs, no agent dispatch)

Validate the plan locally using the `tasks[]` data from Step 2 (or the latest planner-1 revision):

1. **All verifyCommands syntactically runnable.** Try `bash -n -c "$cmd"` for each task. Empty or malformed -> fail.
2. **Task DAG acyclic.** Build graph from `blockedBy`; topological sort; if cycle -> fail.
3. **Each task has >= 1 acceptance criterion.** Empty array -> fail.
4. **Same-wave file disjointness.** For each wave: union of `files` across tasks must have no duplicates -> fail with conflict list.
5. **Acceptance criteria are behavioral, not bare-substring greps.** Pipe the `tasks[]` JSON
   to `lib/acceptance-lint.sh`; it flags any criterion that asserts a substring via an
   unanchored `grep` (which passes on a code comment and fails on incidental substrings):
   ```bash
   printf '%s' "$tasks_json" | bash "${CLAUDE_SKILL_DIR}/../../lib/acceptance-lint.sh"
   accept_lint_exit=$?
   ```
   - Exit 1 BLOCKS — add the flagged criteria to `infeasibility_list`
     so the planner rewrites them as behavioral checks (a named test) or anchored greps.

Build `infeasibility_list`. If non-empty: re-dispatch planner-1 via `SendMessage` with the list. On plan revision received, re-run Step 4b. Retries are unbounded — repeat until feasible.

### Step 5.5 - Decision coverage gate

Run the decision-coverage check after feasibility passes and before committing:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/decision-coverage.sh" "$spec_path" "$plan_path"
coverage_exit=$?
```

**Exit code 1 BLOCKS** (always — single-tier operation has no advisory mode): re-dispatch planner-1 via SendMessage with the uncovered decisions in the body. Coverage is a mechanical check (verbatim-string presence), so on revision received re-run ONLY this check — do NOT re-run the critique gate for a coverage-only failure (that is how a missing verbatim decision line used to cost a full redundant debate).

When blocking (retries unbounded — repeat until the gate passes), send:

```
SendMessage({
  to: "planner-1",
  message: """
    PLAN.md is missing coverage for the following decisions from the spec:
    {uncovered decisions list, one per line prefixed with "- "}

    Read the current PLAN.md at docs/loop-spec/features/{slug}/PLAN.md.
    Revise PLAN.md so each listed decision is explicitly addressed.
    When done: SendMessage({to: "lead", message: "PATTERNS.md and PLAN.md written\n\n<tasks JSON>"})
    then go idle.
  """
})
```

Wait for `TeammateIdle` from `planner-1`. When the revision is received, re-run ONLY the decision-coverage check above (coverage-only failures never re-enter the critique gate).

Exit code 0 (all decisions covered, or no `<decisions>` block present): proceed to the criteria-coverage check below.

**Criteria coverage (same gate, second artifact):** every SPEC `### Good Enough` success criterion must appear verbatim in PLAN.md — VERIFY runs only the criteria PLAN records, so a criterion dropped here is invisible to every downstream gate (VERIFY green, ITERATE floor green) and ships unmet:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/criteria-coverage.sh" "$spec_path" "$plan_path"
criteria_exit=$?
```

Handle exit code 1 exactly like decision-coverage above (BLOCK, re-dispatch planner-1 with the uncovered criteria list, and on revision re-run ONLY this check). In the re-dispatch body, instruct planner-1 to add each missing criterion verbatim to the `## Spec coverage` section mapped to the task(s) that satisfy it.

Exit code 0 on the decision and criteria checks: run the grounding gate:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/grounding-lint.sh" "$plan_path"
grounding_exit=$?
```

Handle exit 1 exactly like decision-coverage above (BLOCK, re-dispatch planner-1 with the FLAG lines in the body; retries unbounded). On revision received, re-run ONLY this lint. Exit 0 on all three checks: proceed to Step 6.

### Step 6 - Commit PLAN.md and update feature.json

```bash
git add docs/loop-spec/features/{slug}/PLAN.md
[ -f "docs/loop-spec/features/{slug}/EVIDENCE.md" ] && git add "docs/loop-spec/features/{slug}/EVIDENCE.md"
git commit -m "plan: NO_JIRA {slug}"
```

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/checkpoint.sh" tag post-plan
```

Update `feature.json` via `lib/feature-write.sh`:
- `artifacts.plan = "docs/loop-spec/features/{slug}/PLAN.md"`
- `completedPhases` append `"plan"`
- `currentPhase = "execute"`

### Step 7 - TeamDelete and clear team state

```
TeamDelete({name: "loop-spec-plan-{slug}"})
```

Update `feature.json` via `lib/feature-write.sh`:
- `currentTeamName = null`
- `currentTeammates = []`

### Step 8 - Phase routing

| execStyle | Action |
|-----------|--------|
| auto | Invoke `loop-spec:execute` immediately |
| step | Print "PLAN complete. PLAN.md at docs/loop-spec/features/{slug}/PLAN.md." Return to user. |
| interactive | Same as step. |
| review-only | Invoke `loop-spec:execute` (gate already paused for human if findings) |

Return.

## Non-interactive mode

If invoked with `execStyle == "auto"` and `feature.json.artifacts.patterns` is already set, skip Step 0 entirely and begin from Step 2 (planner). Otherwise always run Step 0.

## Resume

If invoked with `currentPhase == "plan"` already in `feature.json`:

1. Read `feature.json` to determine subphase state:
   - `artifacts.patterns` is null: PATTERNS.md not yet written; begin from Step 2 (spawn planner-1, which produces PATTERNS.md first).
   - `artifacts.patterns` is set but `artifacts.plan` is null: PATTERNS.md exists; begin from Step 2 (spawn planner-1, skip PATTERNS.md production since file exists).
   - `artifacts.plan` is set and `currentGate.round > 0`: the gate was in progress. Gate-logs with only single-critic/delta rounds (no advocate entries): re-run from the single-critic findings pass with the existing gate-logs inlined as prior context. Advocate entries present (escalated debate): load prior round summaries from `gate-logs/plan-critique-round-*.md` and resume the debate.
   - `artifacts.plan` is set and `currentGate.round == 0` and `currentGate.phase == null`: plan written and critique passed; run Step 4b feasibility gate.

2. Live-team probe:
   - If `currentTeamName != null` AND `teamsMode == "explicit"`: call `TaskList({team: currentTeamName})`. (`implicit`/`none`: skip the probe — modern `TaskList` takes no parameters and teammates never survive the session; clear `currentTeamName` and respawn.)
     - Error (team gone): clear `currentTeamName` in `feature.json` via `lib/feature-write.sh`, recreate team via `TeamCreate`, replay from the detected subphase.
     - Success (team live): print orphan-cleanup message with explicit team name; require manual `TeamDelete` before resume.
   - If `currentTeamName == null`: recreate team via `TeamCreate` and replay from subphase.

3. On resume with a prior debate in progress: load all existing `gate-logs/plan-critique-round-*.md` content into the spawn prompts for `advocate-1` and `challenger-1` as `{prior_round_summaries}`, then restart the debate from round `currentGate.round + 1`.

## Workspace mode -- task-format rules

When `feature.workspace` is non-null, every task additionally carries a `repo` field (must match one `workspace.repos[].name`; feasibility gate enforces), targets exactly one repo, uses workspace-relative `<repo>/<path>` file paths, and may declare cross-repo `blockedBy` edges. Full rules verbatim in `${CLAUDE_SKILL_DIR}/references/workspace-task-format.md` — the planner brief MUST include them in workspace mode.
