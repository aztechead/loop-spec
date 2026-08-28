---
name: plan
description: PLAN phase - the planner produces PATTERNS.md then PLAN.md, then the critique gate; updates feature.json. Cycle-internal - invoked by /loop-spec:cycle; not for ad-hoc invocation (start there).
allowed-tools: Bash Read Write Edit Glob Grep Skill Agent AskUserQuestion TeamCreate TeamDelete SendMessage TaskCreate TaskUpdate TaskList TaskGet ToolSearch Workflow
---

# PLAN Phase

You are the PLAN phase orchestrator. Invoked by `loop-spec:cycle` when `feature.json.currentPhase == "plan"`.

> **Team modes:** dispatch follows `.loop-spec/runtime.json.teamsMode`. `explicit`: as
> written below. `implicit` (no `TeamCreate`/`TeamDelete` — they throw): probe
> `lib/implicit-team-model.sh spawn-kind --teams-mode implicit --selector <feature.models.role>`
> per teammate and dispatch per `skills/shared/implicit-team-mode.md` (DISCUSS/PLAN note).
> `teamsAvailable == false`: every teammate below becomes a one-shot `Agent` call per
> `skills/shared/no-teams-fallback.md` (DISCUSS/PLAN critique-gate note). All artifacts
> and gates are unchanged in every mode. Every Agent or SendMessage whose result this
> step still needs: issue the call, then stop. Never AskUserQuestion as a wait
> (`skills/shared/harness-call-contracts.md`).

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

Before spawning the team: join the DISCUSS background prefetch if one is in flight (`artifacts.patternsPrefetch == "in-flight"`, check once, no sleep); then if `docs/loop-spec/features/{slug}/PATTERNS.md` already exists, record it in `feature.json.artifacts` and skip production; else attempt GSD `.planning/codebase/` ingestion; else the planner produces PATTERNS.md at its own Step 0. Exact prefetch-join/cache/ingest procedure and artifact bookkeeping verbatim in `${CLAUDE_SKILL_DIR}/references/patterns-bootstrap.md`.

**Greenfield plans (`feature.json.greenfield == true`).** There are no codebase analogs: PATTERNS.md records the chosen stack's canonical conventions (project layout, test placement, naming) from SPEC.md's Foundations requirements instead of mined analogs, marked `Source: stack conventions (greenfield)`. The task DAG MUST lead with **task-001 = scaffold**: initialize the project structure, dependency manifest, test harness, and a passing walking-skeleton test; its `verifyCommand` is the stack's canonical test command from SPEC.md, and EVERY other task is `blockedBy: ["task-001"]` (directly or transitively). No task may assume tooling that task-001 does not create. After task-001 merges, EXECUTE backfills `feature.commands.*` (see `skills/execute/SKILL.md`) so later tasks and VERIFY run real commands.

### Step 1 - TeamCreate the plan team

```
TeamCreate({
  name: "loop-spec-plan-{slug}",
  teammates: [
    { name: "planner-1",    subagent_type: "loop-spec:planner" },
    { name: "advocate-1",   subagent_type: "loop-spec:advocate" },
    { name: "challenger-1", subagent_type: "loop-spec:challenger" }
  ]
})
```

Each teammate object MUST include `subagent_type` (binds to the role definition
in `agents/*.md`). Add `model` only when the matching
`feature.models.<role>` value is an Agent alias; omit it for `inherit`.

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

**Dispatch telemetry (`skills/shared/dispatch-events.md`):** emit one `dispatch` event per teammate actually launched in this phase (planner, pattern-mapper, challenger; advocate only when the gate escalates) — `bash "${CLAUDE_SKILL_DIR}/../../lib/events.sh" emit ".loop-spec/features/${slug}" dispatch --phase "plan" --data '{"role":"<role>","model":"<resolved selector>","rung":"team"}' || true`. One event per LAUNCH; `SendMessage` rework rounds and delta re-verifies do not re-emit.

### Step 2 - Spawn planner-1

Model: `feature.models.planner` (activated for PLAN immediately before entry; do not re-derive from model-matrix).

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

    PRE-SUBMIT SELF-CHECK (automated gates grade the plan after you return; a failure
    forces a re-dispatch round): self-check against your role definition's "Gates you
    will be judged against", "Role boundary", REQUIRED CONCRETE FORM, modelTier,
    batchGroup, and Interfaces sections before sending. One addition not in the charter:
    "## Global constraints" lists every binding rule VERBATIM (SPEC boundaries,
    <decisions> constraints, repo rules) or the single line "- none" -- dispatch briefs
    inline it, so a paraphrase here becomes a drifted rule in every wave.

    When done, send:
      SendMessage({to: "lead", message: "PATTERNS.md and PLAN.md written\n\n<tasks JSON>"})
    then go idle.
  """
})
```

Stop after SendMessage. The harness resumes this turn on `TeammateIdle` from `planner-1`. Never AskUserQuestion as a wait. If `planner-1` goes idle without producing both `PATTERNS.md` and `PLAN.md`:
- Send `SendMessage({to: "planner-1", message: "Check docs/loop-spec/features/{slug}/PATTERNS.md and docs/loop-spec/features/{slug}/PLAN.md -- one or both are missing. Produce any missing files now and include tasks[] JSON in your completion message."})` once.
- If still idle without output on second idle, AskUserQuestion is a real stuck-teammate question (retry / lead-author / abort), never a wait. Autonomous mode (`feature.json.autonomous`): re-dispatch the teammate fresh ONCE; if that also produces nothing, the lead authors PATTERNS.md + PLAN.md itself from the same brief and continues, noting `lead-authored` in `warnings[]` — never wait on a human, and never treat the warning as the handler (`skills/shared/autonomous-mode.md`, continuation ladder).

On `PATTERNS.md and PLAN.md written` message received: update `feature.json` via `lib/feature-write.sh` — nested `set` takes the dot path directly, value JSON-quoted, never raw jq (`skills/shared/feature-state-schema.md` "Writing rules"):

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" set "$fdir" artifacts.patterns '"docs/loop-spec/features/'"${slug}"'/PATTERNS.md"'
bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" set "$fdir" artifacts.patternsSource '"pattern-mapper"'
```

Parse the `tasks[]` JSON from the message body. Store for use in Steps 3 and 4.

Proceed to Step 3.

### Step 3 - Critique gate (structural fast-path may skip; single-critic default)

**Structural fast-path (replaces the old quick tier — measured scope, decided AFTER planning):** resolve the two bounds through the repo tuning overlay first (`FP_TASKS="$(bash "${CLAUDE_SKILL_DIR}/../../lib/tuning.sh" get fastPathMaxTasks 2)"`, `FP_FILES="$(bash "${CLAUDE_SKILL_DIR}/../../lib/tuning.sh" get fastPathMaxFiles 3)"` — defaults 2/3 unless `lib/tuning.sh` widened them for this repo; `skills/shared/tier-matrix.md` "Repo tuning overlay"). Run `security_signal="$(bash "${CLAUDE_SKILL_DIR}/../../lib/security-signal.sh" first "docs/loop-spec/features/{slug}/SPEC.md" "docs/loop-spec/features/{slug}/PLAN.md")"` while preserving exit 1 as the normal no-match result and treating exit 2 as an error. Skip this critique gate iff ALL hold: the plan has <= {FP_TASKS} tasks, AND the union of task `files[]` touches <= {FP_FILES} files, AND `security_signal` is empty. When skipped, log one line: `plan critique skipped (structural fast-path: {N} tasks, {M} files, no security signal)` and go to Step 4b (feasibility still runs).

**Maintenance profile:** when `feature.json.executionProfile == "maintenance"` AND
`security_signal` is empty, skip this gate regardless of the task/file bounds above — the
classification that earned the profile already bounded the change more tightly than the
fast-path does. Log `plan critique skipped (maintenance profile, no security signal)` and
go to Step 4b (feasibility still runs). A security signal still escalates.

When not skipped, the gate runs per the **critique gate ladder** (`skills/shared/tier-matrix.md`): single-critic by default, escalating to the paired debate only when triggered.

**Run the full gate procedure per `skills/shared/critique-gate-protocol.md`** (gate open,
single-critic pass, escalated debate, adjudication, fix loop, gateHistory, currentGate
reset) with these parameters:

- `phase=plan`, `gate=plan-critique`, `artifact=PLAN.md`,
  `artifact_path=docs/loop-spec/features/{slug}/PLAN.md`
- `author=planner-1`
- `next_step=Step 4b`
- Models: `feature.models.challenger` / `feature.models.advocate` (activated for PLAN
  immediately before entry; do not re-derive from model-matrix)

**Mode selection (security signal).** The escalation trigger is declared on the critique
graph, not here: `graph/critique.graph.json` routes `critique.escalate -> critique.debate`
when `lib/security-signal.sh` reports a match. The fast-path check above already ran that
declared probe; this gate obeys it. If `security_signal` is non-empty: log
`[PLAN] critique gate escalated: security signal ($security_signal)` and start directly
in the protocol's **Escalated debate**. Otherwise run its single-critic pass. The
evidence string contains the exact file, line, and normalized term, so escalation is
auditable.

**Round telemetry:** where the protocol says "emit the phase's `gate_round` event", run
(non-fatal; `"mode":"single-critic"` on the solo pass, `"mode":"delta"` on delta
re-verifies, no mode key on debate rounds):

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/events.sh" emit ".loop-spec/features/${slug}" gate_round \
  --phase "plan" --data '{"gate":"plan-critique","round":<N>,"mode":"single-critic"}' || true
```

### Step 4 - Adjudicate findings and synthesize fix-list

Adjudicate per the protocol's two tables (`skills/shared/critique-gate-protocol.md`,
"Adjudication") and run its fix loop (gateHistory fail entry BEFORE re-dispatch, snapshot,
author re-dispatch, delta re-verify, deadlock escalation, pass entry + `currentGate`
reset). PLAN supplies these phase actions and deltas:

- **`{user_intent_action}`** (finding depends on user intent, autonomous mode): adopt the
  more reversible reading and record it to disk (`bash
  "${CLAUDE_SKILL_DIR}/../../lib/decisions.sh" add "{feature_dir}" plan "<question>"
  "<reading adopted>" "more reversible"`) AND in `## User decisions (already made)`
  suffixed `(assumed)` (`skills/shared/autonomous-mode.md`).
- **`{ungrounded_action}`** (`UNGROUNDED:` finding): append the probe result via `bash
  "${CLAUDE_SKILL_DIR}/../../lib/evidence.sh" add
  "docs/loop-spec/features/{slug}/EVIDENCE.md" "<claim>" "<command>" "<output>"`, then
  feed `EVID-NNN` + output excerpt into the planner re-dispatch so planner-1 cites it.
- **Author re-dispatch:** `planner-1` reads the current PLAN.md, applies every fix-list
  item in place, sends `PATTERNS.md and PLAN.md written\n\n<tasks JSON>` to lead, goes
  idle. **Re-parse the `tasks[]` JSON from every revision message** before the delta
  re-verify — Steps 4b/6 consume it.

On gate pass, proceed to Step 4b.

### Step 4b - Feasibility gate (ALWAYS runs, no agent dispatch)

Validate the plan locally using the `tasks[]` data from Step 2 (or the latest planner-1 revision):

0. **Artifacts structurally well-formed.** EXECUTE Step 2a parses PLAN.md task blocks by
   the template shape, and the planner reads PATTERNS.md sections — a drifted heading or a
   fence-wrapped file makes the next phase spend cycles repairing instead of executing:
   ```bash
   bash "${CLAUDE_SKILL_DIR}/../../lib/artifact-lint.sh" plan "$plan_path"
   bash "${CLAUDE_SKILL_DIR}/../../lib/artifact-lint.sh" patterns "docs/loop-spec/features/{slug}/PATTERNS.md"
   printf '%s' "$tasks_json" | bash "${CLAUDE_SKILL_DIR}/../../lib/artifact-lint.sh" tasks -
   ```
   Any exit 1 -> add the FLAG lines to `infeasibility_list` (the tasks check also catches a
   planner message whose tasks[] JSON dropped a required field before it can poison EXECUTE).
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

Stop after SendMessage. The harness resumes this turn on `TeammateIdle` from `planner-1`. Never AskUserQuestion as a wait. When the revision is received, re-run ONLY the decision-coverage check above (coverage-only failures never re-enter the critique gate).

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

Handle exit 1 exactly like decision-coverage above (BLOCK, re-dispatch planner-1 with the FLAG lines in the body; retries unbounded). On revision received, re-run ONLY this lint. Exit 0 on all three checks: proceed to Step 5.7.

### Step 5.7 - Fresh-eyes pruning pass (advisory)

The critique gate judged the plan's substance with the spec and maps in hand; nobody has
yet judged its surplus, and everyone still in this phase has heard every line justified.
Dispatch ONE context-free reviewer (a fresh subagent — never planner-1 or challenger-1)
carrying `${CLAUDE_SKILL_DIR}/../../skills/shared/review-prompts/prose-pruning.md`
verbatim, plus ONLY the final PLAN.md and
`skills/shared/artifact-templates/PLAN.md.template` — no spec, no gate-logs, no
critique history.
Dispatch the reviewer, then stop: never AskUserQuestion as a wait (`skills/shared/harness-call-contracts.md`).

Skip the dispatch when PLAN.md is under 60 lines (`wc -l`).

The lead adjudicates the returned list, then re-runs the three mechanical gates on the
pruned file before proceeding — a cut that breaks decision coverage, criteria coverage,
or grounding is reverted, not argued with:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/decision-coverage.sh" "$spec_path" "$plan_path" \
  && bash "${CLAUDE_SKILL_DIR}/../../lib/criteria-coverage.sh" "$spec_path" "$plan_path" \
  && bash "${CLAUDE_SKILL_DIR}/../../lib/grounding-lint.sh" "$plan_path"
```

Declined proposals and `out-of-scope:` lines go to `.loop-spec/BACKLOG.md`. Advisory:
nothing here blocks Step 6.

### Step 6 - Commit PLAN.md and update feature.json

First persist the final `tasks[]` as the machine-readable handoff. EXECUTE consumes this
sidecar directly instead of re-deriving structured tasks from PLAN.md prose — the JSON the
gates just validated IS the contract, so no formatting drift can cost EXECUTE a repair
round. Write it only now, after every gate has passed, so it always matches the final
PLAN.md revision:

```bash
printf '%s' "$tasks_json" | bash "${CLAUDE_SKILL_DIR}/../../lib/artifact-lint.sh" tasks - \
  && printf '%s' "$tasks_json" | jq . > ".loop-spec/features/{slug}/tasks.json"
```

(If the lint fails here, the in-memory tasks[] drifted from the gated revision — re-request
tasks[] from planner-1 and re-run Step 4b before proceeding.)

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
- `artifacts.tasks = ".loop-spec/features/{slug}/tasks.json"`
- `completedPhases` append `"plan"`

### Step 7 - TeamDelete and clear team state

```
TeamDelete({name: "loop-spec-plan-{slug}"})
```

Update `feature.json` via `lib/feature-write.sh`:
- `currentTeamName = null`
- `currentTeammates = []`

### Step 8 - Phase routing

Always return to the cycle orchestrator; never invoke a successor phase directly.
PLAN declares no successor — `graph/cycle.graph.json` does, and the engine
(`lib/graph/run.sh`, cycle Step 6) selects the next node. Cycle owns the phase
boundary: continuous mode enters the engine-selected node immediately, while
`phaseHandoff == true` writes the paused result and ends the main-agent invocation.
For `step` / `interactive`, include
`PLAN complete. PLAN.md at docs/loop-spec/features/{slug}/PLAN.md.` in the returned
phase summary.

## Non-interactive mode

If invoked with `execStyle == "auto"` and `feature.json.artifacts.patterns` is already set, skip Step 0 entirely and begin from Step 2 (planner). Otherwise always run Step 0.

## Resume

If invoked with `currentPhase == "plan"` already in `feature.json`:

1. Read `feature.json` to determine subphase state:
   - `artifacts.patterns` is null: PATTERNS.md not yet written; begin from Step 2 (spawn planner-1, which produces PATTERNS.md first).
   - `artifacts.patterns` is set but `artifacts.plan` is null: PATTERNS.md exists; begin from Step 2 (spawn planner-1, skip PATTERNS.md production since file exists).
   - `artifacts.plan` is set and `currentGate.round > 0`: the gate was in progress — resume per `skills/shared/critique-gate-protocol.md` "Resume".
   - `artifacts.plan` is set and `currentGate.round == 0` and `currentGate.phase == null`: plan written and critique passed; run Step 4b feasibility gate.

2. Live-team probe:
   - If `currentTeamName != null` AND `teamsMode == "explicit"`: call `TaskList({team: currentTeamName})`. (`implicit`/`none`: skip the probe — modern `TaskList` takes no parameters and teammates never survive the session; clear `currentTeamName` and respawn.)
     - Error (team gone): clear `currentTeamName` in `feature.json` via `lib/feature-write.sh`, recreate team via `TeamCreate`, replay from the detected subphase.
     - Success (team live): print orphan-cleanup message with explicit team name; require manual `TeamDelete` before resume.
   - If `currentTeamName == null`: recreate team via `TeamCreate` and replay from subphase.

3. On resume with a prior debate in progress: per the protocol's "Resume" section.

## Workspace mode -- task-format rules

When `feature.workspace` is non-null, every task additionally carries a `repo` field (must match one `workspace.repos[].name`; feasibility gate enforces), targets exactly one repo, uses workspace-relative `<repo>/<path>` file paths, and may declare cross-repo `blockedBy` edges. Full rules verbatim in `${CLAUDE_SKILL_DIR}/references/workspace-task-format.md` — the planner brief MUST include them in workspace mode.
