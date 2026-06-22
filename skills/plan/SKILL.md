---
name: plan
description: PLAN phase - creates a plan team with planner, advocate, and challenger; planner produces PATTERNS.md then PLAN.md; runs critique debate via SendMessage; writes PLAN.md and updates feature.json.
allowed-tools: Bash Read Write Edit Glob Grep Skill Agent AskUserQuestion TeamCreate TeamDelete SendMessage TaskCreate TaskUpdate TaskList TaskGet
---

# PLAN Phase

You are the PLAN phase orchestrator. Invoked by `loop-spec:cycle` when `feature.json.currentPhase == "plan"`.

> **No-teams fallback:** if `.loop-spec/runtime.json.teamsAvailable == false`, do NOT
> call `TeamCreate`/`TeamDelete`/`SendMessage` (they throw). Run planner, advocate, and
> challenger as one-shot `Agent` calls with the same agent types, models, and prompt
> templates, per `skills/shared/no-teams-fallback.md`. Critique rounds become sequential
> challenger → advocate Agent calls with prior round summaries (from `gate-logs/`)
> inlined. All artifacts, gates, and retry budgets are unchanged.

## Inputs (from cycle skill via feature.json)

- `slug`, `tier`, `execStyle`
- `feature_dir`: `.loop-spec/features/{slug}/`
- `feature_json_path`: `.loop-spec/features/{slug}/feature.json`
- `spec_path`: from `feature.json.artifacts.spec`
- `plan_path`: `docs/loop-spec/features/{slug}/PLAN.md` (equals `feature.json.artifacts.plan`); bound here so the Step 5.5 decision-coverage call has a real path
- Required: `docs/loop-spec/codebase/*.md` (cycle skill guarantees these exist before PLAN starts)

**ITERATE re-entry:** if `feature.json.iterate.feedback` is non-null, this is a re-plan triggered by the ITERATE convergence loop (the judge classified a `plan`-type gap). Read that feedback first and target the named gap — revise or add only the tasks needed to close it (fix the weakest point first); do NOT re-author the whole plan from scratch. Preserve the `## User decisions (already made)` record. Clear `iterate.feedback` is the orchestrator's job after the phase routes, not yours.

## Procedure

### Step 0 - PATTERNS.md cache check and GSD ingestion

Before spawning the team, check in order:

**0a - Existing PATTERNS.md (any source):**

```bash
patterns_target="docs/loop-spec/features/${slug}/PATTERNS.md"
if [[ -f "$patterns_target" ]]; then
  echo "CACHED"
fi
```

If the file exists: update `feature.json` via `lib/feature-write.sh`:
- `artifacts.patterns = "docs/loop-spec/features/${slug}/PATTERNS.md"`
- `artifacts.patternsSource = "pattern-mapper"`

Then proceed to Step 1 (TeamCreate). Planner will detect PATTERNS.md exists and skip its Step 0 production. This applies on any resume or re-trigger where PATTERNS.md was already produced.

**0b - GSD ingestion (if no cached file):**

```bash
target="docs/loop-spec/features/${slug}/PATTERNS.md"
result="$(bash "${CLAUDE_SKILL_DIR}/../../lib/gsd-ingest.sh" patterns "$slug" "$target")"
echo "$result"
```

The script prints `INGESTED <source-path>` on success or `NONE` if no GSD PATTERNS.md matched the slug.

If `INGESTED`: update `feature.json` via `lib/feature-write.sh`:
- `artifacts.patterns = "docs/loop-spec/features/${slug}/PATTERNS.md"`
- `artifacts.patternsSource = "gsd-ingest"`

Then proceed to Step 1 (TeamCreate). Planner will detect PATTERNS.md exists and skip its Step 0 production.

If `NONE`: continue to Step 1.

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

#### Warm up the reviewers while the planner authors (skip on quick tier)

If `tier != "quick"` (the Step 3 critique gate will run), send advocate-1 and challenger-1 a warm-up brief so they load context concurrently with plan authoring instead of starting round 1 cold:

```
SendMessage({
  to: "advocate-1",
  body: "Warm-up only: read SPEC.md at {spec_path} and the codebase maps at docs/loop-spec/codebase/*.md now to load context. Do NOT read PLAN.md or PATTERNS.md yet -- they are still being authored and may not exist. Prepare your review checklist from the spec and maps, then go idle and wait for the lead's round-1 prompt with PLAN.md ready."
})
SendMessage({
  to: "challenger-1",
  body: "Warm-up only: read SPEC.md at {spec_path} and the codebase maps at docs/loop-spec/codebase/*.md now to load context. Do NOT read PLAN.md or PATTERNS.md yet -- they are still being authored and may not exist. Prepare your critique checklist from the spec and maps, then go idle and wait for the lead's round-1 prompt."
})
```

If `tier == "quick"`: send no warm-up (the critique gate is skipped, so the reviewers are never used).

### Plan authoring (workflow path or fallback)

Read `.loop-spec/runtime.json`. If `workflowsAvailable=true` AND
`feature.tier == "quality"`, dispatch:

```text
Workflow({
  scriptPath: "${CLAUDE_SKILL_DIR}/../../lib/workflows/plan-multi-angle.js",
  args: {
    tier: feature.tier,
    specPath: feature.artifacts.spec,
    patternsPath: feature.artifacts.patterns,
  }
})
```

Result: `{plan: <markdown>, angles: [...], winner}`. Skill writes `plan` to
`docs/loop-spec/features/{slug}/PLAN.md` and logs `angles` to
`.loop-spec/features/{slug}/gate-logs/plan-multi-angle.json`.

If `workflowsAvailable=false` OR tier != "quality", fall through to the
existing single-planner Agent dispatch below.

### Step 2 - Spawn planner-1

Model: `feature.models.planner` (resolved once at cycle Step 5; do not re-derive from model-matrix).

```
SendMessage({
  to: "planner-1",
  body: """
    You are planner-1 in team loop-spec-plan-{slug}.

    slug: {slug}
    spec_path: {spec_path}
    patterns_path: docs/loop-spec/features/{slug}/PATTERNS.md
    codebase_mapping_paths: {paths to docs/loop-spec/codebase/*.md}
    tier: {tier}

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
      SendMessage({to: "lead", body: "PATTERNS.md and PLAN.md written\n\n<tasks JSON>"})
    then go idle.
  """
})
```

Wait for `TeammateIdle` from `planner-1`. If `planner-1` goes idle without producing both `PATTERNS.md` and `PLAN.md`:
- Send `SendMessage({to: "planner-1", body: "Check docs/loop-spec/features/{slug}/PATTERNS.md and docs/loop-spec/features/{slug}/PLAN.md -- one or both are missing. Produce any missing files now and include tasks[] JSON in your completion message."})` once.
- If still idle without output on second idle, escalate to user via `AskUserQuestion`.

On `PATTERNS.md and PLAN.md written` message received: update `feature.json` via `lib/feature-write.sh`:
- `artifacts.patterns = "docs/loop-spec/features/${slug}/PATTERNS.md"`
- `artifacts.patternsSource = "pattern-mapper"`

Parse the `tasks[]` JSON from the message body. Store for use in Steps 3 and 4.

Proceed to Step 3.

### Step 3 - Critique gate (SKIP if tier == quick)

If `tier == "quick"`: skip directly to Step 4.

Read `maxCritiqueRounds` from `skills/shared/tier-matrix.md` for the current tier (quality: 3, balanced: 2, quick: 1).

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

#### Spawn advocate-1

Model: `feature.models.advocate`.

```
SendMessage({
  to: "advocate-1",
  body: """
    [Populate from skills/shared/team-prompts/advocate.md with these substitutions:
      {slug} = slug
      {tier} = tier
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

#### Spawn challenger-1

Model: `feature.models.challenger`.

```
SendMessage({
  to: "challenger-1",
  body: """
    [Populate from skills/shared/team-prompts/challenger.md with these substitutions:
      {slug} = slug
      {tier} = tier
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

#### Debate loop

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

6. Convergence check:
   - **Mutual DONE**: both messages start with `ROUND-{N} DONE:` (not `DONE-WITH-ISSUES`). Break loop.
   - **One-sided DONE for two consecutive rounds**: one teammate sent `ROUND-{N} DONE:` in both round N and round N-1 while the other sent `DONE-WITH-ISSUES`. Break loop.
   - **Cap reached**: N == maxCritiqueRounds. Record `notes: "cap reached"` in gateHistory. Break loop.
   - Otherwise: N += 1. Send `SendMessage` to both teammates starting round N+1:
     ```
     SendMessage({to: "challenger-1", body: "Start round {N+1}. Read PLAN.md and send your round {N+1} critique to advocate-1."})
     SendMessage({to: "advocate-1", body: "Round {N+1} starting. Wait for challenger-1's critique, then respond."})
     ```

### Step 4 - Synthesize fix-list

Read all files under `.loop-spec/features/{slug}/gate-logs/` matching `plan-critique-round-*.md`.

Apply reconciliation rules:

| Situation | Action |
|-----------|--------|
| Challenger raises point advocate also flagged as risk | High-confidence. Add to fix-list. |
| Challenger raises point advocate explicitly defended | Evaluate; pick the stronger argument. Add to fix-list if challenger wins. |
| Both agree | No action. |
| Neither resolves (depends on user intent) | Escalate via `AskUserQuestion`. |

Build `fix_list` (may be empty).

#### If fix_list non-empty:

Check budgets (from `feature.json`):
- If `retryBudget.perGateUsed["plan.plan-critique"] >= retryBudget.perGate`: pause and escalate.
- If `retryBudget.perPhaseUsed.plan >= retryBudget.perPhase.plan`: pause and escalate.
- If `retryBudget.globalUsed >= retryBudget.global`: hard abort and escalate.

Increment counters via `lib/feature-write.sh`:
- `retryBudget.perGateUsed["plan.plan-critique"] += 1`
- `retryBudget.perPhaseUsed.plan += 1`
- `retryBudget.globalUsed += 1`

Append the fail entry to `feature.json.gateHistory` via `lib/feature-write.sh` BEFORE re-dispatching (the re-dispatch path returns to Step 3 and would never reach an append placed after the return):

```json
{
  "phase": "plan",
  "gate": "plan-critique",
  "attempt": <attempt number>,
  "result": "fail",
  "advocateModel": "<model>",
  "challengerModel": "<model>",
  "rounds": <N>,
  "convergence": "<mutual-done | cap-reached | one-sided>",
  "findingsAddressed": [<fix_list items>],
  "notes": null
}
```

Re-dispatch planner-1 via `SendMessage` (not a fresh Agent call):
```
SendMessage({
  to: "planner-1",
  body: """
    PLAN.md needs revisions. Fix-list:
    {fix_list items, numbered}

    Read the current PLAN.md at docs/loop-spec/features/{slug}/PLAN.md.
    Apply all items on the fix-list. Write the updated PLAN.md in place.
    When done: SendMessage({to: "lead", body: "PATTERNS.md and PLAN.md written\n\n<tasks JSON>"})
    then go idle.
  """
})
```

Wait for `TeammateIdle` from `planner-1`. When `PATTERNS.md and PLAN.md written` is received, parse the updated `tasks[]` JSON. Re-run the debate: reset `currentGate.round = 0` via `lib/feature-write.sh`, then re-send spawn prompts to `advocate-1` and `challenger-1` with `{N_round} = 1` and `{prior_round_summaries} = (concatenated content of all existing gate-logs/plan-critique-round-*.md files)`. This resets their per-round context so they argue against the revised PLAN.md with awareness of prior debate. Then return to Step 3 (critique debate loop), starting with round 1.

#### If fix_list empty:

Append to `feature.json.gateHistory` via `lib/feature-write.sh`:
```json
{
  "phase": "plan",
  "gate": "plan-critique",
  "attempt": <attempt number>,
  "result": "pass",
  "advocateModel": "<model>",
  "challengerModel": "<model>",
  "rounds": <N>,
  "convergence": "<mutual-done | cap-reached | one-sided>",
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

Build `infeasibility_list`. If non-empty: re-dispatch planner-1 via `SendMessage` with the list, increment retries via `lib/feature-write.sh` (`retryBudget.perPhaseUsed.plan += 1`, `retryBudget.globalUsed += 1`), respect caps. On plan revision received, re-run Step 4b. Repeat until feasible or budget exhausted.

### Step 5.5 - Decision coverage gate

Run the decision-coverage check after feasibility passes and before committing:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/decision-coverage.sh" "$spec_path" "$plan_path"
coverage_exit=$?
```

**Tier-conditional handling of exit code 1:**

| Tier | Exit code 1 behaviour |
|------|-----------------------|
| quality / balanced | BLOCKS. Re-dispatch planner-1 via SendMessage with the uncovered decisions in the body. Return to Step 4 (debate). |
| quick | ADVISORY. Log a warning to the console, then proceed to Step 6 (commit). |

When blocking (quality or balanced tier): increment retry counters via `lib/feature-write.sh` (`retryBudget.perPhaseUsed.plan += 1`, `retryBudget.globalUsed += 1`) and respect existing caps. Send:

```
SendMessage({
  to: "planner-1",
  body: """
    PLAN.md is missing coverage for the following decisions from the spec:
    {uncovered decisions list, one per line prefixed with "- "}

    Read the current PLAN.md at docs/loop-spec/features/{slug}/PLAN.md.
    Revise PLAN.md so each listed decision is explicitly addressed.
    When done: SendMessage({to: "lead", body: "PATTERNS.md and PLAN.md written\n\n<tasks JSON>"})
    then go idle.
  """
})
```

Wait for `TeammateIdle` from `planner-1`. When the revision is received, return to Step 4 (critique debate) with the updated plan.

Exit code 0 (all decisions covered, or no `<decisions>` block present): proceed to Step 6.

### Step 6 - Commit PLAN.md and update feature.json

```bash
git add docs/loop-spec/features/{slug}/PLAN.md
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
   - `artifacts.plan` is set and `currentGate.round > 0`: debate was in progress; load prior round summaries from `gate-logs/plan-critique-round-*.md`.
   - `artifacts.plan` is set and `currentGate.round == 0` and `currentGate.phase == null`: plan written and critique passed; run Step 4b feasibility gate.

2. Live-team probe:
   - If `currentTeamName != null`: call `TaskList({team: currentTeamName})`.
     - Error (team gone): clear `currentTeamName` in `feature.json` via `lib/feature-write.sh`, recreate team via `TeamCreate`, replay from the detected subphase.
     - Success (team live): print orphan-cleanup message with explicit team name; require manual `TeamDelete` before resume.
   - If `currentTeamName == null`: recreate team via `TeamCreate` and replay from subphase.

3. On resume with a prior debate in progress: load all existing `gate-logs/plan-critique-round-*.md` content into the spawn prompts for `advocate-1` and `challenger-1` as `{prior_round_summaries}`, then restart the debate from round `currentGate.round + 1`.

## Workspace mode -- task-format rules

When `feature.workspace` is non-null (workspace mode), the following additional rules apply to every task the planner produces. These rules are additive; all existing task-format rules remain in force.

### repo field (required in workspace mode)

Every task MUST carry a `repo` field whose value matches exactly one `workspace.repos[].name` from `feature.json`. Omitting `repo` in workspace mode is an error caught by the feasibility gate.

In the PLAN.md task-block format, `repo` appears as a dedicated line alongside `**Files:**` and `**blockedBy:**`:

```
**repo:** frontend
```

In the planner's `tasks[]` JSON shape (returned in the completion message and passed to `TaskCreate` via task `metadata`), `repo` is a top-level string key:

```json
{"id": "task-001", "subject": "...", "repo": "frontend", "files": ["frontend/src/app.ts"], ...}
```

### One task, one repo

A single task MUST target exactly one repo. Work that spans multiple repos is expressed as multiple tasks connected by explicit `blockedBy` edges. The planner must never list files from more than one repo in a single task's `files[]`.

### workspace-relative file paths

In workspace mode `files[]` entries are workspace-relative and MUST begin with the repo name as the first path component (e.g., `frontend/src/app.ts`, not `src/app.ts`). Every file in a task must resolve -- via `lib/workspace.sh resolve-repo <workspace-root> <path>` -- to the same repo named in the task's `repo` field.

### Cross-repo blockedBy edges

When a change in one repo must precede a change in another repo, express this as two tasks: the upstream task (repo A) and the downstream task (repo B) with `blockedBy: [upstream-task-id]`. This is the only mechanism for cross-repo ordering.

### Ignored by lib helpers

`lib/plan-to-loop.sh`, `lib/dag-width.sh`, and `lib/plan-adherence.sh` ignore unknown task keys, so adding `repo` to task metadata requires no changes to those scripts.
