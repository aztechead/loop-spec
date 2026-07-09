---
name: discuss
description: DISCUSS phase - conversational requirements gathering, refines SPEC.md, and runs the single-critic critique gate (escalating to an advocate/challenger debate when contested or security-signaled). Autonomous runs collapse to lead-authored refinement + the critique gate. Cycle-internal - invoked by /loop-spec:cycle against the active feature's state; not for ad-hoc invocation on a bare user request (start via /loop-spec:cycle).
allowed-tools: Bash Read Write Edit Glob Grep Skill Agent AskUserQuestion TeamCreate TeamDelete SendMessage TaskCreate TaskUpdate TaskList TaskGet ToolSearch
---

# DISCUSS Phase

You are the DISCUSS phase orchestrator. Invoked by `loop-spec:cycle` after style + slug are chosen.

> **No-teams fallback:** if `.loop-spec/runtime.json.teamsAvailable == false`, do NOT
> call `TeamCreate`/`TeamDelete`/`SendMessage` (they throw). Run every teammate below as
> a one-shot `Agent` call with the same agent type, model, and prompt template, per
> `skills/shared/no-teams-fallback.md`. The single-critic pass and each delta re-verify
> become one-shot challenger Agent calls (fix-list + diff inlined); an escalated debate
> becomes sequential challenger → advocate Agent calls with prior round summaries (from
> `gate-logs/`) inlined. All artifacts and gates are unchanged.

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

## Autonomous fast path (`feature.json.autonomous == true`)

When the run is autonomous, the SPEC phase already ran the self-answered interview
(`skills/spec/SKILL.md`, Autonomous mode): the lead formulated the questions, answered them,
recorded every assumption, and wrote SPEC.md. Re-running a clarifying loop against itself and
paying an opus spec-writer to transcribe the same conversation is pure overhead, so DISCUSS
collapses to lead-authored refinement + the critique gate:

1. **Skip Step 1's conversational loop.** The lead handles Step 1's obligations directly:
   - **Unresolved dimensions:** for each entry in SPEC.md's `unresolved_dimensions[]`,
     resolve it as a graph-grounded assumption, record it to disk (`bash
     "${CLAUDE_SKILL_DIR}/../../lib/decisions.sh" add "{feature_dir}" discuss
     "<dimension>" "<resolution>" "<why>"`), and EDIT SPEC.md directly: the resolved
     dimension becomes a concrete requirement (or explicit ASSUMPTION) with a testable
     `### Good Enough` criterion, and the frontmatter drops it from
     `unresolved_dimensions` (`gate_passed: true` once the list is empty).
   - **The corner question** (required once per design shape, exactly as Step 1 defines
     it): self-answer it grounded in the graph, record the decision, and fold any
     resulting boundary into SPEC.md's `## Boundaries (what NOT to do)`.
   - **External probes:** run any still-missing read-only probes per Step 1's
     probe-before-assert rule (`evidence.sh` ledger) — self-run, never blocking.
   - **ITERATE re-entry** (`iterate.feedback` non-null): the lead applies the scope-gap
     refinement to SPEC.md directly (this was already the question-free path).
   - Write a short `.loop-spec/features/{slug}/discuss-transcript.md` noting the collapse
     and every resolution made.
2. **Skip Step 3 (spec-writer) entirely.** SPEC.md from the SPEC phase IS the draft. The
   phase's teammates are `challenger-1` only, plus `advocate-1` when the gate escalates;
   `spec-writer-1` is never spawned.
3. **Run the critique gate (Step 4) and adjudication (Step 5) as written**, with one
   substitution: fix-list revisions are applied by the LEAD editing SPEC.md directly (it
   authored the spec; a transcription teammate is a cold-start for nothing), then the
   delta re-verify runs as written. Note `lead-authored` once in the transcript.
4. **Grounding gate (Step 5.75):** FLAG lines are fixed by the lead directly (cite ledger
   entries or rewrite as ASSUMPTION per `skills/shared/grounding-protocol.md`), then the
   lint re-runs.
5. Every remaining step (bootstrap wait, commit, teardown, routing) runs unchanged.

Interactive/step styles are untouched by this fast path — a human conversation adds real
information, so the full Step 1 loop and the spec-writer revision flow stay as written.

## Procedure

### Step 1 - Conversational clarifying loop

**Autonomous fast path:** if `feature.json.autonomous == true`, skip this step's conversational loop — the lead performs the collapsed obligations per the **Autonomous fast path** section above, then continues at Step 1.5.

**ITERATE re-entry (autonomous refinement mode):** if `feature.json.iterate.feedback` is non-null, DISCUSS was re-entered by the ITERATE convergence loop to close a `spec`-type goal gap. Read that feedback first and target only the named scope gap, then refine SPEC.md toward the **original goal** (`feature.json.feature_title`) — do not restart the whole interview, and do not redefine the goal.
- In `auto` / `review-only` styles (and under `LOOP_SPEC_NON_INTERACTIVE=1`): run this refinement **without `AskUserQuestion`** — synthesize the SPEC change from `iterate.feedback` + the codebase, note any assumption in SPEC.md, and proceed. The loop must not block on a human here; the next VERIFY→ITERATE pass re-judges against the immutable original goal.
- In `step` / `interactive` styles only: you may run the normal clarifying loop to refine the scope gap with the user.

**Unresolved SPEC dimensions (consume them — SPEC wrote them for THIS step):** read the `ambiguity_scores` YAML frontmatter of the SPEC draft (`docs/loop-spec/features/{slug}/SPEC.md`). If `gate_passed: false`, the `unresolved_dimensions[]` list names requirement dimensions the SPEC phase could NOT pin down (user override at round 6, or thin non-interactive input). These are open asks — left unconsumed they survive every downstream gate and ship unmet. For EACH listed dimension:

- **`step` / `interactive`:** ask ONE targeted `AskUserQuestion` for that dimension first, before any other clarifying question.
- **`auto` / `review-only` / non-interactive:** do not block; resolve it as an explicit assumption grounded in the code graph, and record it in the transcript as `ASSUMPTION ({dimension}): ...`.

Either way, the spec-writer brief (Step 3) must require: every resolved dimension becomes a concrete requirement (or explicit assumption) WITH a testable acceptance criterion under `### Good Enough`, and the updated SPEC.md frontmatter drops it from `unresolved_dimensions` (empty list + `gate_passed: true` once all are resolved). An unresolved dimension may never be silently carried past DISCUSS.

Run a one-question-at-a-time loop to understand the feature.

**Ground in the code graph first (required).** graphify is a hard requirement, so `graphify-out/graph.json` is present. Before and during the loop, use `graphify query "<area>"`, `graphify path "<A>" "<B>"`, `graphify explain "<entity>"`, and `graphify-out/GRAPH_REPORT.md` (god nodes + cross-module connections) to see what the feature will actually touch. Let the graph drive design/approach questions — e.g. surface the real integration points and ripple paths as the options in your `AskUserQuestion` choices, instead of generic alternatives. (Absent under `LOOP_SPEC_REQUIRE_GRAPHIFY=0` degraded mode, and in greenfield features before code exists — `feature.json.greenfield`; there, ground in SPEC.md's Foundations requirements and the chosen stack's conventions instead.)

**Probe external reality before asserting it (required).** Before treating any factual premise about an external system (dataset, API, service, infra) as fact in questions, `AskUserQuestion` options, or the spec-writer brief, run the cheapest READ-ONLY probe and record the result:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/evidence.sh" add \
  "docs/loop-spec/features/{slug}/EVIDENCE.md" \
  "<claim>" "<command>" "<output>"
```

Facts about external systems presented in questions or `AskUserQuestion` options must carry their `EVID-NNN` citation or be phrased as explicit assumptions (e.g. "assuming X — probe: `<cmd>` — is this right?"). Autonomous and non-interactive styles self-run probes and never block on a user question; if a probe is impossible, record `ASSUMPTION: <claim> | verify: <command>` per `skills/shared/grounding-protocol.md` and proceed.

**Ask the corner question (required, once per design shape).** Before the design settles, ask: "what is the most likely next change to this feature — a new param, a new case, a new caller, a scale step — and does the proposed shape absorb it as a local diff?" Ground the candidate next-changes in the graph (ripple paths, god nodes). If the likely change would ripple broadly, surface the boundary that fixes it as an option (interactive: an `AskUserQuestion` choice; auto: resolve as a recorded assumption). This asks for a seam — a clean boundary, an injected dependency — never for built-out speculation; canonical reference `skills/shared/design-for-change.md`.

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

**Autonomous fast path:** the roster is `challenger-1` only (spawn `advocate-1` lazily if the gate escalates); `spec-writer-1` is never part of the team. Update `currentTeammates` accordingly and continue at Step 4.

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

### Step 3 - Spawn spec-writer-1 (skipped in the autonomous fast path)

Model: `feature.models.specWriter` (resolved once at cycle Step 5; do not re-derive from model-matrix).

Send spec-writer-1 its prompt via `SendMessage`:

```
SendMessage({
  to: "spec-writer-1",
  message: """
    You are spec-writer-1 in team loop-spec-discuss-{slug}.

    slug: {slug}
    feature_title: {title}
    transcript_path: .loop-spec/features/{slug}/discuss-transcript.md
    output_path: docs/loop-spec/features/{slug}/SPEC.md
    evidence_path: docs/loop-spec/features/{slug}/EVIDENCE.md

    Read the transcript. Read the EXISTING SPEC.md at the output path — the SPEC phase already wrote it.
    REVISE SPEC.md in place with what the discussion added or changed (new requirements, resolved dimensions, boundary changes, decisions); do NOT re-author it from scratch. Keep its structure and every requirement the discussion did not touch. Read the project context (check docs/loop-spec/codebase/ for any existing domain maps) to ground the revisions. Every fact asserted about an external system must cite an `EVID-NNN` entry from the evidence_path ledger or be written as an explicit `ASSUMPTION: <claim> | verify: <command>` per `skills/shared/grounding-protocol.md`.

    SPEC.md's frontmatter `ambiguity_scores` block (set by spec phase): preserve it verbatim, EXCEPT that a dimension the transcript resolves is removed from `unresolved_dimensions` (set `gate_passed: true` once the list is empty). Do not recompute the scores.

    When done, send:
      SendMessage({to: "lead", message: "SPEC.md written"})
    then go idle.
  """
})
```

Wait for `TeammateIdle` from `spec-writer-1`. If spec-writer-1 goes idle without producing `SPEC.md`:
- Send `SendMessage({to: "spec-writer-1", message: "SPEC.md not found at docs/loop-spec/features/{slug}/SPEC.md. Write it now and send lead the SPEC.md written message."})` once.
- If still idle without output on second idle, escalate to user via `AskUserQuestion`. Autonomous mode (`feature.json.autonomous`): re-dispatch the teammate fresh ONCE; if that also produces nothing, the lead authors SPEC.md itself from the same brief and continues, noting `lead-authored` in the transcript and `warnings[]` — never wait on a human, and never treat the warning as the handler (`skills/shared/autonomous-mode.md`, continuation ladder).

On `SPEC.md written` message received: proceed to Step 4.

### Step 4 - Critique gate (ALWAYS runs; single-critic default)

The SPEC critique is the cheap gate that catches building the wrong thing entirely — it is never skipped (single-tier operation; the structural fast-path applies only to the PLAN critique). It runs per the **critique gate ladder** (`skills/shared/tier-matrix.md`): single-critic by default, escalating to the paired advocate/challenger debate only when triggered.

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

**Dispatch telemetry (`skills/shared/dispatch-events.md`):** emit one `dispatch` event per teammate actually launched in this phase (spec-writer, challenger; advocate only when the gate escalates) — `bash "${CLAUDE_SKILL_DIR}/../../lib/events.sh" emit ".loop-spec/features/${slug}" dispatch --phase "discuss" --data '{"role":"<role>","model":"<resolved alias>","rung":"team"}' || true`. One event per LAUNCH; `SendMessage` rework rounds and delta re-verifies do not re-emit.

#### Mode selection (security signal)

```bash
if grep -qiE 'auth|authenticat|authoriz|permission|credential|secret|token|crypt|payment|billing|PII|migrat|delet' "docs/loop-spec/features/{slug}/SPEC.md"; then
  gate_mode="debate"
else
  gate_mode="single-critic"
fi
```

A security-signaled spec starts directly in the escalated debate (skip to **Escalated debate** below). Everything else runs single-critic.

#### Single-critic pass (default)

Model: `feature.models.challenger`. Send `challenger-1` the solo-critic brief:

```
SendMessage({
  to: "challenger-1",
  message: """
    [Populate from skills/shared/team-prompts/critic.md with these substitutions:
      {slug} = slug
      {N} = 1
      {phase} = discuss
      {artifact} = SPEC.md
    ]

    Run your findings pass on SPEC.md now and report to lead.
  """
})
```

Wait for `TeammateIdle` from `challenger-1` and read its `FINDINGS:` / `NO-FINDINGS:` message. Write it to the gate-log:

```
Write .loop-spec/features/{slug}/gate-logs/spec-critique-round-1.md
Contents:
  # spec-critique Round 1 (single-critic)

  ## challenger-1
  <the FINDINGS/NO-FINDINGS message body>
```

Emit the round's telemetry event (non-fatal):
```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/events.sh" emit ".loop-spec/features/${slug}" gate_round \
  --phase "discuss" --data '{"gate":"spec-critique","round":1,"mode":"single-critic"}' || true
```

Proceed to Step 5 (the lead adjudicates the findings there).

#### Escalated debate

Runs only when a ladder trigger fires (security signal above; contested `[major]` or delta deadlock from Step 5). `maxCritiqueRounds = 2` (fixed; `skills/shared/tier-matrix.md`). When escalating from a single-critic pass, include all existing `gate-logs/spec-critique-round-*.md` content (the solo findings and any delta rounds) as `{prior_round_summaries}` in both spawn prompts.

##### Spawn advocate-1

Model: `feature.models.advocate` (resolved once at cycle Step 5; do not re-derive from model-matrix).

```
SendMessage({
  to: "advocate-1",
  message: """
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

##### Spawn challenger-1

Model: `feature.models.challenger` (resolved once at cycle Step 5; do not re-derive from model-matrix). When escalating from a single-critic pass, `challenger-1` is already live — re-send it the debate brief below via `SendMessage` instead of spawning fresh.

```
SendMessage({
  to: "challenger-1",
  message: """
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

##### Debate loop

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

6. Emit the round's telemetry event (non-fatal):
   ```bash
   bash "${CLAUDE_SKILL_DIR}/../../lib/events.sh" emit ".loop-spec/features/${slug}" gate_round \
     --phase "discuss" --data "{\"gate\":\"spec-critique\",\"round\":{N}}" || true
   ```

7. Convergence check:
   - **Mutual DONE**: both messages start with `ROUND-{N} DONE:` (not `DONE-WITH-ISSUES`). Break loop.
   - **One-sided DONE for two consecutive rounds**: one teammate sent `ROUND-{N} DONE:` in both round N and round N-1 while the other sent `DONE-WITH-ISSUES`. Break loop.
   - **Cap reached**: N == maxCritiqueRounds. Record `notes: "cap reached"` in gateHistory. Break loop.
   - Otherwise: N += 1. Send `SendMessage` to both teammates starting round N+1:
     ```
     SendMessage({to: "challenger-1", message: "Start round {N+1}. Read SPEC.md and send your round {N+1} critique to advocate-1."})
     SendMessage({to: "advocate-1", message: "Round {N+1} starting. Wait for challenger-1's critique, then respond."})
     ```

### Step 5 - Adjudicate findings and synthesize fix-list

Read all files under `.loop-spec/features/{slug}/gate-logs/` matching `spec-critique-round-*.md`.

**Single-critic adjudication (default mode):**

| Situation | Action |
|-----------|--------|
| `[major]` finding the lead agrees with | Add to fix-list. |
| `[major]` finding the lead disputes | Do NOT drop it — ESCALATE to the full debate (Step 4, Escalated debate) with all gate-logs as prior summaries. The debate is the tiebreak; a solo gate may only bias stricter, never looser. |
| `[minor]` finding | Lead's judgment: add to fix-list or drop. Every dropped `[minor]` is logged in the gate-log with a one-line reason — never silently. |
| Finding depends on user intent | Escalate via `AskUserQuestion`. Autonomous mode (`feature.json.autonomous`): no escalation — adopt the more reversible reading, record it to disk (`bash "${CLAUDE_SKILL_DIR}/../../lib/decisions.sh" add "{feature_dir}" discuss "<dimension>" "<reading adopted>" "more reversible"` — `skills/shared/autonomous-mode.md`), and add it to the fix-list so the spec states it explicitly. |
| Finding is an `UNGROUNDED:` line (ungrounded external claim) | Lead runs the suggested read-only probe ITSELF (teammates have no Bash), appends it via `bash "${CLAUDE_SKILL_DIR}/../../lib/evidence.sh" add "docs/loop-spec/features/{slug}/EVIDENCE.md" "<claim>" "<command>" "<output>"`, and adds a fix-list item carrying the `EVID-NNN` + output excerpt so the revision cites it (or converts the claim to an ASSUMPTION if the probe is impossible). |

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

Append the fail entry to `feature.json.gateHistory` via `lib/feature-write.sh` BEFORE re-dispatching (the re-dispatch path returns to Step 4 and would never reach an append placed after the return):

```json
{
  "phase": "discuss",
  "gate": "spec-critique",
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

Snapshot SPEC.md before sending the fix-list (the hash feeds the no-op-revision shortcut; the copy feeds the delta re-verify diff):

```bash
spec_hash_before="$(git hash-object docs/loop-spec/features/{slug}/SPEC.md 2>/dev/null || echo none)"
cp docs/loop-spec/features/{slug}/SPEC.md .loop-spec/features/{slug}/gate-logs/SPEC.pre-revision.md
```

**Autonomous fast path:** the LEAD applies the fix-list to SPEC.md directly (Edit tool; there is no spec-writer-1), then continues at the hash comparison below.

Otherwise re-dispatch spec-writer-1 via `SendMessage` (not a fresh Agent call):
```
SendMessage({
  to: "spec-writer-1",
  message: """
    SPEC.md needs revisions. Fix-list:
    {fix_list items, numbered}

    Read the current SPEC.md at docs/loop-spec/features/{slug}/SPEC.md.
    Apply all items on the fix-list. Write the updated SPEC.md in place.
    When done: SendMessage({to: "lead", message: "SPEC.md written"})
    then go idle.
  """
})
```

Wait for `TeammateIdle` from `spec-writer-1`. When `SPEC.md written` is received (or the lead finished its direct edit):

**No-op-revision shortcut (skip the redundant re-critique).** Re-critiquing byte-identical
text yields the same verdict, so a re-dispatch that did not actually change SPEC.md must not
trigger another full debate round (wasted opus dispatches, and a potential loop). Compare the
hash:

```bash
spec_hash_after="$(git hash-object docs/loop-spec/features/{slug}/SPEC.md 2>/dev/null || echo none)"
```

If `spec_hash_after == spec_hash_before` (the spec-writer made no substantive change — either
it judged the fix-list non-actionable or the edits were cosmetic), do NOT re-verify.
Record the gate as converged with `notes: "spec-writer made no change to SPEC.md; re-critique
skipped"` in the `gateHistory` pass entry, reset `currentGate` (as in the fix_list-empty
branch below), and proceed to Step 5.75. This collapses a re-check only when it would be
provably redundant.

Otherwise (SPEC.md changed): run the **delta re-verify** — do NOT re-run the full gate protocol (`skills/shared/tier-matrix.md`, critique gate ladder):

```bash
diff -u .loop-spec/features/{slug}/gate-logs/SPEC.pre-revision.md \
        docs/loop-spec/features/{slug}/SPEC.md > /tmp/spec-delta.diff || true
```

```
SendMessage({
  to: "challenger-1",
  message: """
    Delta re-verify (per your solo-critic brief). The fix-list below was applied to SPEC.md.
    Confirm each item is addressed and check the CHANGED sections only for new issues.

    Fix-list applied:
    {fix_list items, numbered}

    Diff:
    {content of /tmp/spec-delta.diff}

    Reply to lead with DELTA-VERIFIED or DELTA-FINDINGS, then go idle.
  """
})
```

Wait for `TeammateIdle` from `challenger-1`, append the reply to a new `gate-logs/spec-critique-round-{next}.md` (titled `(delta re-verify)`), and emit a `gate_round` event with `"mode":"delta"`:

- **`DELTA-VERIFIED`**: the gate passes — append the `gateHistory` pass entry (convergence: `"delta-verified"`), reset `currentGate`, proceed to Step 5.75.
- **`DELTA-FINDINGS`**: adjudicate the tagged findings per the Step 5 rules and start a new fix round (retries are unbounded — full bore). **Deadlock escalation:** if the same finding survives two consecutive delta rounds, the author and critic are stuck — escalate to the full debate (Step 4, Escalated debate) with all gate-logs as prior summaries.

(When the escalated debate produced the fix-list, the delta re-verify above still applies — the debate does not re-run for a revision; only a deadlock or a new contested `[major]` re-enters it.)

#### If fix_list empty:

Append to `feature.json.gateHistory` via `lib/feature-write.sh`:
```json
{
  "phase": "discuss",
  "gate": "spec-critique",
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

### Step 5.75 - Grounding gate (deterministic, ALWAYS runs)

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/grounding-lint.sh" "docs/loop-spec/features/{slug}/SPEC.md"
grounding_exit=$?
```

Exit 1 BLOCKS: re-dispatch spec-writer-1 via `SendMessage` with the FLAG lines (instruct: cite ledger entries or rewrite as ASSUMPTION per `skills/shared/grounding-protocol.md`); autonomous fast path: the lead applies the FLAG fixes directly. Retries are unbounded — repeat until the lint passes. On revision received, re-run ONLY this lint — lint-only failures do NOT re-run the critique gate. Exit 0: proceed to Step 6.

### Step 6 - Commit SPEC.md and update feature.json

```bash
git add docs/loop-spec/features/{slug}/SPEC.md
[ -f "docs/loop-spec/features/{slug}/EVIDENCE.md" ] && git add "docs/loop-spec/features/{slug}/EVIDENCE.md"
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

3. On resume with a prior gate in progress: if the gate-logs show only single-critic/delta rounds (no advocate entries), re-run the gate from the single-critic findings pass — re-send `challenger-1` the solo-critic brief with the existing gate-logs content inlined as prior context. If an escalated debate was in progress (advocate entries present), load all existing `gate-logs/spec-critique-round-*.md` content into the spawn prompts for `advocate-1` and `challenger-1` as `{prior_round_summaries}`, then restart the debate from round `currentGate.round + 1`.

4. Do not re-ask conversation questions the user already answered (transcript is persisted to disk).
