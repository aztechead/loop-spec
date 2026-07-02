---
name: discuss
description: DISCUSS phase - conversational requirements gathering, spawns a discuss team, runs advocate/challenger debate via SendMessage, writes SPEC.md.
allowed-tools: Bash Read Write Edit Glob Grep Skill Agent AskUserQuestion TeamCreate TeamDelete SendMessage TaskCreate TaskUpdate TaskList TaskGet ToolSearch
---

# DISCUSS Phase

You are the DISCUSS phase orchestrator. Invoked by `loop-spec:cycle` after style + slug are chosen.

> **No-teams fallback:** if `.loop-spec/runtime.json.teamsAvailable == false`, do NOT
> call `TeamCreate`/`TeamDelete`/`SendMessage` (they throw). Run every teammate below as
> a one-shot `Agent` call with the same agent type, model, and prompt template, per
> `skills/shared/no-teams-fallback.md`. Critique rounds become sequential challenger →
> advocate Agent calls with prior round summaries (from `gate-logs/`) inlined. All
> artifacts, gates, and retry budgets are unchanged.

> **Implicit-team harness:** if `.loop-spec/runtime.json.teamsMode == "implicit"` (CC >= 2.1.178),
> do NOT call `TeamCreate`/`TeamDelete` (they were removed and throw). The team already exists:
> spawn each teammate below with `Agent({name, description, subagent_type, model, prompt})`, folding its first
> work prompt into the spawn, then drive critique rounds with `SendMessage` as written. Per
> `skills/shared/implicit-team-mode.md`. `SendMessage` and the shared task list are unchanged.

## Inputs (from cycle skill via feature.json)

- `slug`, `execStyle`, `feature_title`
- `feature_dir`: `.loop-spec/features/{slug}/`
- `feature_json_path`: `.loop-spec/features/{slug}/feature.json`
- `bootstrapPendingDomains`: list of codebase domain names fired as background mappers in cycle Step 5.5b (may be empty if codebase docs already existed or were GSD-ingested)

## Procedure

### Step 1 - Conversational clarifying loop

**ITERATE re-entry (autonomous refinement mode):** if `feature.json.iterate.feedback` is non-null, DISCUSS was re-entered by the ITERATE convergence loop to close a `spec`-type goal gap. Read that feedback first and target only the named scope gap, then refine SPEC.md toward the **original goal** (`feature.json.feature_title`) — do not restart the whole interview, and do not redefine the goal.
- In `auto` / `review-only` styles (and under `LOOP_SPEC_NON_INTERACTIVE=1`): run this refinement **without `AskUserQuestion`** — synthesize the SPEC change from `iterate.feedback` + the codebase, note any assumption in SPEC.md, and proceed. The loop must not block on a human here; the next VERIFY→ITERATE pass re-judges against the immutable original goal.
- In `step` / `interactive` styles only: you may run the normal clarifying loop to refine the scope gap with the user.

**Unresolved SPEC dimensions (consume them — SPEC wrote them for THIS step):** read the `ambiguity_scores` YAML frontmatter of the SPEC draft (`docs/loop-spec/features/{slug}/SPEC.md`). If `gate_passed: false`, the `unresolved_dimensions[]` list names requirement dimensions the SPEC phase could NOT pin down (user override at round 6, or thin non-interactive input). These are open asks — left unconsumed they survive every downstream gate and ship unmet. For EACH listed dimension:

- **`step` / `interactive`:** ask ONE targeted `AskUserQuestion` for that dimension first, before any other clarifying question.
- **`auto` / `review-only` / non-interactive:** do not block; resolve it as an explicit assumption grounded in the code graph, and record it in the transcript as `ASSUMPTION ({dimension}): ...`.

Either way, the spec-writer brief (Step 3) must require: every resolved dimension becomes a concrete requirement (or explicit assumption) WITH a testable acceptance criterion under `### Good Enough`, and the updated SPEC.md frontmatter drops it from `unresolved_dimensions` (empty list + `gate_passed: true` once all are resolved). An unresolved dimension may never be silently carried past DISCUSS.

Run a one-question-at-a-time loop to understand the feature.

**Ground in the code graph first (required).** graphify is a hard requirement, so `graphify-out/graph.json` is present. Before and during the loop, use `graphify query "<area>"`, `graphify path "<A>" "<B>"`, `graphify explain "<entity>"`, and `graphify-out/GRAPH_REPORT.md` (god nodes + cross-module connections) to see what the feature will actually touch. Let the graph drive design/approach questions — e.g. surface the real integration points and ripple paths as the options in your `AskUserQuestion` choices, instead of generic alternatives. (Absent only under `LOOP_SPEC_REQUIRE_GRAPHIFY=0` degraded mode.)

- Non-AUTO styles: full conversation in main thread, no cap on rounds
- AUTO style: cap at 5 Q rounds, then proceed regardless
- **Present design/approach decisions as structured `AskUserQuestion` multiple-choice with explicit tradeoffs, not prose.** Whenever a question has discernible options (library choice, scope cut, data shape, integration point), surface them as numbered options so the user can steer with one click. Reserve free-text questions for genuinely open prompts. This applies to every `AskUserQuestion` escalation in this phase (Step 5 reconciliation included).

Save the transcript to `.loop-spec/features/{slug}/discuss-transcript.md` for spec-writer to read.

### Step 1.5 - Wait for codebase bootstrap (if pending)

If `feature.json.bootstrapPendingDomains` is non-empty (set during cycle Step 5.5b when background mappers were fired):

1. Poll for file existence with a max wait of 600 seconds (10 minutes):
   ```bash
   max_wait=600
   elapsed=0
   interval=15
   while [[ $elapsed -lt $max_wait ]]; do
     all_present=true
     for d in TECH ARCH QUALITY CONCERNS DOMAIN; do
       [[ -f "docs/loop-spec/codebase/${d}.md" ]] || { all_present=false; break; }
     done
     $all_present && break
     sleep $interval
     elapsed=$((elapsed + interval))
   done
   ```

2. If all 5 files are present: update `feature.json` via `lib/feature-write.sh`:
   - `artifacts.codebaseSource.{domain} = "mapper"` for each domain in `bootstrapPendingDomains`
   - `bootstrapPendingDomains = []`

   Then commit all new codebase docs:
   ```bash
   git add docs/loop-spec/codebase/
   git commit -m "docs: NO_JIRA bootstrap codebase map (background)"
   ```

3. If timeout reached with missing files: print which domains are still missing, then fall back to synchronous invocation:
   ```
   Skill(loop-spec:map-codebase) args: --domain {csv-of-still-missing-lowercased}
   ```
   This ensures correctness even if background agents failed.

If `feature.json.bootstrapPendingDomains` is empty (codebase docs already existed or GSD-ingested): skip this step.

### Step 2 - TeamCreate the discuss team

Create the team with three teammates:

```
TeamCreate({
  name: "loop-spec-discuss-{slug}",
  teammates: [
    { name: "spec-writer-1", subagent_type: "loop-spec:spec-writer", model: feature.models.specWriter },
    { name: "advocate-1",    subagent_type: "loop-spec:advocate",    model: feature.models.advocate },
    { name: "challenger-1",  subagent_type: "loop-spec:challenger",  model: feature.models.challenger }
  ]
})
```

Each teammate object MUST include `subagent_type` (binds the teammate to its role definition in `agents/*.md`) and `model` (read literally from `feature.models.<role>`; see `skills/shared/model-matrix.md`). Spawning by name alone -- e.g., `teammates: ["spec-writer-1", ...]` -- leaves the harness with no role binding and is incorrect.

Update `feature.json` via `lib/feature-write.sh`:
- `currentTeamName = "loop-spec-discuss-{slug}"`
- `currentTeammates = ["spec-writer-1", "advocate-1", "challenger-1"]`

### Step 3 - Spawn spec-writer-1

Model: `feature.models.specWriter` (resolved once at cycle Step 5; do not re-derive from model-matrix).

Send spec-writer-1 its prompt via `SendMessage`:

```
SendMessage({
  to: "spec-writer-1",
  body: """
    You are spec-writer-1 in team loop-spec-discuss-{slug}.

    slug: {slug}
    feature_title: {title}
    transcript_path: .loop-spec/features/{slug}/discuss-transcript.md
    output_path: docs/loop-spec/features/{slug}/SPEC.md

    Read the transcript. Read the project context (check docs/loop-spec/codebase/ for any existing domain maps).
    Produce SPEC.md at the output path per your role definition (agents/spec-writer.md).

    If SPEC.md frontmatter contains an `ambiguity_scores` block (set by spec phase), preserve it verbatim. Do not modify or recompute the scores.

    When done, send:
      SendMessage({to: "lead", body: "SPEC.md written"})
    then go idle.
  """
})
```

Wait for `TeammateIdle` from `spec-writer-1`. If spec-writer-1 goes idle without producing `SPEC.md`:
- Send `SendMessage({to: "spec-writer-1", body: "SPEC.md not found at docs/loop-spec/features/{slug}/SPEC.md. Write it now and send lead the SPEC.md written message."})` once.
- If still idle without output on second idle, escalate to user via `AskUserQuestion`. Autonomous mode (`feature.json.autonomous`): re-dispatch the teammate fresh ONCE; if that also produces nothing, halt the phase with the evidence appended to `warnings[]` — never wait on a human (`skills/shared/autonomous-mode.md`).

On `SPEC.md written` message received: proceed to Step 4.

### Step 4 - Critique debate (ALWAYS runs)

The SPEC critique is the cheap gate that catches building the wrong thing entirely — it is never skipped (single-tier operation; the structural fast-path applies only to the PLAN critique).

`maxCritiqueRounds = 2` (fixed; `skills/shared/tier-matrix.md`).

Update `feature.json` via `lib/feature-write.sh`:
```json
{
  "currentGate": {
    "phase": "discuss",
    "gate": "spec-critique",
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

Model: `feature.models.advocate` (resolved once at cycle Step 5; do not re-derive from model-matrix).

```
SendMessage({
  to: "advocate-1",
  body: """
    [Populate from skills/shared/team-prompts/advocate.md with these substitutions:
      {slug} = slug
      {N} = 1
      {phase} = discuss
      {artifact} = SPEC.md
      {maxRounds} = maxCritiqueRounds
      {N_round} = 1
      {prior_round_summaries} = (empty on first run; load from gate-logs/ on resume)
    ]

    You will receive the first message from challenger-1. Wait for it before starting your round-1 response.
  """
})
```

#### Spawn challenger-1

Model: `feature.models.challenger` (resolved once at cycle Step 5; do not re-derive from model-matrix).

```
SendMessage({
  to: "challenger-1",
  body: """
    [Populate from skills/shared/team-prompts/challenger.md with these substitutions:
      {slug} = slug
      {N} = 1
      {phase} = discuss
      {artifact} = SPEC.md
      {maxRounds} = maxCritiqueRounds
      {N_round} = 1
      {prior_round_summaries} = (empty on first run; load from gate-logs/ on resume)
    ]

    Start round 1 now: read SPEC.md and send your critique to advocate-1 via SendMessage.
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
   Write .loop-spec/features/{slug}/gate-logs/spec-critique-round-{N}.md
   Contents:
     # spec-critique Round {N}

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
     SendMessage({to: "challenger-1", body: "Start round {N+1}. Read SPEC.md and send your round {N+1} critique to advocate-1."})
     SendMessage({to: "advocate-1", body: "Round {N+1} starting. Wait for challenger-1's critique, then respond."})
     ```

### Step 5 - Synthesize fix-list

Read all files under `.loop-spec/features/{slug}/gate-logs/` matching `spec-critique-round-*.md`.

Apply reconciliation rules:

| Situation | Action |
|-----------|--------|
| Challenger raises point advocate also flagged as risk | High-confidence. Add to fix-list. |
| Challenger raises point advocate explicitly defended | Evaluate; pick the stronger argument. Add to fix-list if challenger wins. |
| Both agree | No action. |
| Neither resolves (depends on user intent) | Escalate via `AskUserQuestion`. Autonomous mode (`feature.json.autonomous`): no escalation — adopt the more reversible reading, record it in the decisions record (`skills/shared/autonomous-mode.md`), and add it to the fix-list so the spec states it explicitly. |

Build `fix_list` (may be empty).

#### If fix_list non-empty:

Check budgets (from `feature.json`):
- If `retryBudget.perGateUsed["discuss.spec-critique"] >= retryBudget.perGate`: pause and escalate.
- If `retryBudget.perPhaseUsed.discuss >= retryBudget.perPhase.discuss`: pause and escalate.
- If `retryBudget.globalUsed >= retryBudget.global`: hard abort and escalate.

Increment counters via `lib/feature-write.sh`:
- `retryBudget.perGateUsed["discuss.spec-critique"] += 1`
- `retryBudget.perPhaseUsed.discuss += 1`
- `retryBudget.globalUsed += 1`

Append the fail entry to `feature.json.gateHistory` via `lib/feature-write.sh` BEFORE re-dispatching (the re-dispatch path returns to Step 4 and would never reach an append placed after the return):

```json
{
  "phase": "discuss",
  "gate": "spec-critique",
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

Snapshot SPEC.md before sending the fix-list (used by the no-op-revision shortcut below):

```bash
spec_hash_before="$(git hash-object docs/loop-spec/features/{slug}/SPEC.md 2>/dev/null || echo none)"
```

Re-dispatch spec-writer-1 via `SendMessage` (not a fresh Agent call):
```
SendMessage({
  to: "spec-writer-1",
  body: """
    SPEC.md needs revisions. Fix-list:
    {fix_list items, numbered}

    Read the current SPEC.md at docs/loop-spec/features/{slug}/SPEC.md.
    Apply all items on the fix-list. Write the updated SPEC.md in place.
    When done: SendMessage({to: "lead", body: "SPEC.md written"})
    then go idle.
  """
})
```

Wait for `TeammateIdle` from `spec-writer-1`. When `SPEC.md written` is received:

**No-op-revision shortcut (skip the redundant re-critique).** Re-critiquing byte-identical
text yields the same verdict, so a re-dispatch that did not actually change SPEC.md must not
trigger another full debate round (wasted opus dispatches, and a potential loop). Compare the
hash:

```bash
spec_hash_after="$(git hash-object docs/loop-spec/features/{slug}/SPEC.md 2>/dev/null || echo none)"
```

If `spec_hash_after == spec_hash_before` (the spec-writer made no substantive change — either
it judged the fix-list non-actionable or the edits were cosmetic), do NOT re-run the debate.
Record the gate as converged with `notes: "spec-writer made no change to SPEC.md; re-critique
skipped"` in the `gateHistory` pass entry, reset `currentGate` (as in the fix_list-empty
branch below), and proceed to Step 6. This collapses a re-critique round only when it would be
provably redundant; any real revision still re-runs the full debate.

Otherwise (SPEC.md changed): re-run the debate — reset `currentGate.round = 0`, then re-send spawn prompts to `advocate-1` and `challenger-1` with `{N_round} = 1` and `{prior_round_summaries} = (concatenated content of all existing gate-logs/spec-critique-round-*.md files)`. This resets their per-round context so they argue against the revised SPEC.md with awareness of prior debate. Then return to Step 4 (critique debate loop), starting with round 1.

#### If fix_list empty:

Append to `feature.json.gateHistory` via `lib/feature-write.sh`:
```json
{
  "phase": "discuss",
  "gate": "spec-critique",
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

### Step 6 - Commit SPEC.md and update feature.json

```bash
git add docs/loop-spec/features/{slug}/SPEC.md
git commit -m "spec: NO_JIRA {slug}"
```

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/checkpoint.sh" tag post-discuss
```

Update `feature.json` via `lib/feature-write.sh`:
- `artifacts.spec = "docs/loop-spec/features/{slug}/SPEC.md"`
- `completedPhases` append `"discuss"`
- `currentPhase = "plan"`

### Step 7 - TeamDelete and clear team state

```
TeamDelete({name: "loop-spec-discuss-{slug}"})
```

Update `feature.json` via `lib/feature-write.sh`:
- `currentTeamName = null`
- `currentTeammates = []`

### Step 8 - Phase routing

| execStyle | Action |
|-----------|--------|
| auto | Invoke `loop-spec:plan` immediately |
| step | Print "DISCUSS complete. SPEC at docs/loop-spec/features/{slug}/SPEC.md." Return to user. |
| interactive | Same as step. |
| review-only | Invoke `loop-spec:plan` (gate already paused for human if findings) |

Return.

## Non-interactive mode

If invoked with no pending user conversation (e.g., `execStyle == "auto"` and the caller passes a pre-written transcript path):
- Skip Step 1.
- Read the transcript from the provided path.
- Proceed directly to Step 2 (TeamCreate).

## Resume

If invoked with `currentPhase == "discuss"` already in `feature.json`:

1. Read `feature.json` to determine subphase state:
   - `artifacts.spec` is null: transcript may exist; check `.loop-spec/features/{slug}/discuss-transcript.md`.
   - `artifacts.spec` is set: SPEC.md was written; check `currentGate.round`.
   - `currentGate.round > 0`: debate was in progress; load prior round summaries from `gate-logs/spec-critique-round-*.md`.

2. Live-team probe:
   - If `currentTeamName != null`: call `TaskList({team: currentTeamName})`.
     - Error (team gone): clear `currentTeamName`, recreate team via `TeamCreate`, replay from the detected subphase.
     - Success (team live): print orphan-cleanup message with explicit team name; require manual `TeamDelete` before resume.
   - If `currentTeamName == null`: recreate team via `TeamCreate` and replay from subphase.

3. On resume with a prior debate in progress: load all existing `gate-logs/spec-critique-round-*.md` content into the spawn prompts for `advocate-1` and `challenger-1` as `{prior_round_summaries}`, then restart the debate from round `currentGate.round + 1`.

4. Do not re-ask conversation questions the user already answered (transcript is persisted to disk).
