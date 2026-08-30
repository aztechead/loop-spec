---
name: discuss
description: DISCUSS phase - conversational requirements gathering that refines SPEC.md, then a challenger-only critique (skipped when the spec is already gated). Cycle-internal - invoked by /loop-spec:cycle; not for ad-hoc invocation (start there).
allowed-tools: Bash Read Write Edit Glob Grep Skill Agent AskUserQuestion TeamCreate TeamDelete SendMessage TaskCreate TaskUpdate TaskList TaskGet ToolSearch
---

# DISCUSS Phase

You are the DISCUSS phase orchestrator. Invoked by `loop-spec:cycle` after style + slug are chosen.

> **Team modes:** dispatch follows `.loop-spec/runtime.json.teamsMode`. `explicit`: as
> written below. `implicit` (no `TeamCreate`/`TeamDelete` — they throw): probe
> `lib/implicit-team-model.sh spawn-kind --teams-mode implicit --selector <feature.models.role>`
> per teammate and dispatch per `skills/shared/implicit-team-mode.md` (DISCUSS/PLAN note).
> `teamsAvailable == false`: every teammate below becomes a one-shot `Agent` call per
> `skills/shared/no-teams-fallback.md` (DISCUSS/PLAN critique-gate note). All artifacts
> and gates are unchanged in every mode. Every Agent or SendMessage whose result this
> step still needs: issue the call, then stop. Never AskUserQuestion as a wait
> (`skills/shared/harness-call-contracts.md`). Grill `AskUserQuestion` rounds are real
> questions; a running subagent is not.

## Inputs (from cycle skill via feature.json)

- `slug`, `execStyle`, `feature_title`
- `feature_dir`: `.loop-spec/features/{slug}/`
- `feature_json_path`: `.loop-spec/features/{slug}/feature.json`
- `bootstrapPendingDomains`: list of codebase domain names fired as background mappers in cycle Step 5.5b (may be empty if codebase docs already existed or were GSD-ingested)

## Autonomous fast path (`feature.json.autonomous == true`)

When the run is autonomous, the SPEC phase already ran the self-answered interview
(`skills/spec/SKILL.md`, Autonomous mode): the lead formulated the questions, answered them,
recorded every assumption, and wrote SPEC.md. Re-running a clarifying loop against itself and
dispatching a second spec-writer to transcribe the same conversation is pure overhead, so DISCUSS
collapses to lead-authored refinement + the critique gate (itself skippable when
the spec is already gated — same probe as the non-autonomous path):

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
   phase's teammate is `challenger-1` only; `spec-writer-1` is never spawned.
3. **Run the critique gate (Step 4) and adjudication (Step 5) as written**, with one
   substitution: fix-list revisions are applied by the LEAD editing SPEC.md directly (it
   authored the spec; a transcription teammate is a cold-start for nothing), then the
   delta re-verify runs as written. Note `lead-authored` once in the transcript. Step 4
   may skip the critic when the probe answers `gate=skip`.
4. **Grounding gate (Step 5.75):** FLAG lines are fixed by the lead directly (cite ledger
   entries or rewrite as ASSUMPTION per `skills/shared/grounding-protocol.md`), then the
   lint re-runs.
5. Every remaining step (bootstrap wait, commit, teardown, routing) runs unchanged.

Non-autonomous styles (`auto` / `step` / `interactive`) are untouched by this fast path — a human conversation adds real information, so the full Step 1 grill and the spec-writer revision flow stay as written. `execStyle: auto` is not autonomous mode.

## Procedure

### Step 1 - Conversational clarifying loop

**This is the in-phase grill.** A human is attached unless `feature.json.autonomous == true` or `LOOP_SPEC_NON_INTERACTIVE=1`. `execStyle: auto` is not autonomous: it means the cycle does not pause between phases. It still runs this loop. SPEC already pinned requirements; this loop pins design and approach. Do not skip it because SPEC interviewed, because the ambiguity gate passed, or because you could assume an answer.

**Autonomous fast path:** if `feature.json.autonomous == true`, skip this step's conversational loop — the lead performs the collapsed obligations per the **Autonomous fast path** section above, then continues at Step 1.75.

**ITERATE re-entry (autonomous refinement mode):** if `feature.json.iterate.feedback` is non-null, DISCUSS was re-entered by the ITERATE convergence loop to close a `spec`-type goal gap. Read that feedback first and target only the named scope gap, then refine SPEC.md toward the **original goal** (`feature.json.feature_title`) — do not restart the whole interview, and do not redefine the goal.
- In `auto` / `review-only` styles (and under `LOOP_SPEC_NON_INTERACTIVE=1`): run this refinement **without `AskUserQuestion`** — synthesize the SPEC change from `iterate.feedback` + the codebase, note any assumption in SPEC.md, and proceed. The loop must not block on a human here; the next VERIFY→ITERATE pass re-judges against the immutable original goal.
- In `step` / `interactive` styles: run the clarifying loop to refine the scope gap with the user.

**Unresolved SPEC dimensions (consume them — SPEC wrote them for THIS step):** read the `ambiguity_scores` YAML frontmatter of the SPEC draft (`docs/loop-spec/features/{slug}/SPEC.md`). If `gate_passed: false`, the `unresolved_dimensions[]` list names requirement dimensions the SPEC phase could NOT pin down (user override at round 6, or thin non-interactive input). These are open asks — left unconsumed they survive every downstream gate and ship unmet. For EACH listed dimension:

- **`auto` / `step` / `interactive`:** ask ONE targeted `AskUserQuestion` for that dimension first, before any other clarifying question.
- **`review-only` / non-interactive / autonomous:** do not block; resolve it as an explicit assumption grounded in the code graph, and record it in the transcript as `ASSUMPTION ({dimension}): ...`. (If the assumption also lands in a `## Grounding` section, it must carry the full bullet grammar — `- ASSUMPTION ({dimension}): <claim> | verify: <command>` — per `skills/shared/grounding-protocol.md`; the lint accepts the parenthetical qualifier.)

Either way, the spec-writer brief (Step 3) must require: every resolved dimension becomes a concrete requirement (or explicit assumption) WITH a testable acceptance criterion under `### Good Enough`, and the updated SPEC.md frontmatter drops it from `unresolved_dimensions` (empty list + `gate_passed: true` once all are resolved). An unresolved dimension may never be silently carried past DISCUSS.

Run a one-question-at-a-time loop to understand the feature. The loop is required, not optional.

**Ground in the code first (required).** Before and during the loop, read what the feature will actually touch: search the area, read the entry points in full, and follow callers and imports far enough to name the integration points and the boundaries the change crosses. Let that drive the design questions — surface the real integration points and ripple paths as the options in your `AskUserQuestion` choices, instead of generic alternatives. Fan the scanning out to subagents that return `file:line` evidence rather than pulling a large tree through your own context. Dispatch them, then stop: never AskUserQuestion as a wait. In workspace mode, scan each participating repository separately and keep the repository name on every finding. Every claim carried into the critique cites `file:line`. (In greenfield features before code exists — `feature.json.greenfield` — ground in SPEC.md's Foundations requirements and the chosen stack's conventions instead.)

**Probe external reality before asserting it (required).** Before treating any factual premise about an external system (dataset, API, service, infra) as fact in questions, `AskUserQuestion` options, or the spec-writer brief, run the cheapest READ-ONLY probe and record the result:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/evidence.sh" add \
  "docs/loop-spec/features/{slug}/EVIDENCE.md" \
  "<claim>" "<command>" "<output>"
```

Facts about external systems presented in questions or `AskUserQuestion` options must carry their `EVID-NNN` citation or be phrased as explicit assumptions (e.g. "assuming X — probe: `<cmd>` — is this right?"). Autonomous and non-interactive styles self-run probes and never block on a user question; if a probe is impossible, record `ASSUMPTION: <claim> | verify: <command>` per `skills/shared/grounding-protocol.md` and proceed.

**Ask the corner question (required, once per design shape).** Before the design settles, ask: "what is the most likely next change to this feature — a new param, a new case, a new caller, a scale step — and does the proposed shape absorb it as a local diff?" Ground the candidate next-changes in the graph (ripple paths, god nodes). If the likely change would ripple broadly, surface the boundary that fixes it as an option (`auto` / `step` / `interactive`: an `AskUserQuestion` choice; autonomous / `review-only` / non-interactive: resolve as a recorded assumption). This asks for a seam — a clean boundary, an injected dependency — never for built-out speculation; canonical reference `skills/shared/design-for-change.md`.

- **`auto`:** MUST grill. Cap at 5 Q rounds, then proceed. A passed SPEC gate does not skip the design loop. Ask the corner question and at least two design-shape questions even when `unresolved_dimensions` is empty.
- **`step` / `interactive`:** MUST grill. Full conversation in the main thread, no cap on rounds. Same minimum as `auto`, then keep going until design and approach are locked.
- **`review-only`:** skip the conversational loop (the human contact is the critique-gate pause). Still consume unresolved dimensions as assumptions.
- **Present design/approach decisions as structured `AskUserQuestion` multiple-choice with explicit tradeoffs, not prose.** Whenever a question has discernible options (library choice, scope cut, data shape, integration point), surface them as numbered options so the user can steer with one click. Reserve free-text questions for genuinely open prompts. This applies to every `AskUserQuestion` escalation in this phase (Step 5 reconciliation included).

Save the transcript to `.loop-spec/features/{slug}/discuss-transcript.md` for spec-writer to read.

### Step 1.5 - Codebase bootstrap join point (MOVED to Step 5.8)

Do NOT wait for the cycle Step 5.5b background mappers here — the spec critique needs
only SPEC.md and the code graph. The join runs at **Step 5.8**, after the critique gate,
where the poll is usually a no-op.

### Step 1.75 - Prefetch PATTERNS.md (background, best-effort)

PLAN Step 0 consumes `docs/loop-spec/features/{slug}/PATTERNS.md` when it already exists — so start the analog mining NOW, overlapped with this phase's critique work, instead of paying for it serially inside PLAN. Its input (SPEC.md) is already written by the SPEC phase.

Skip this step entirely (the planner produces PATTERNS.md at PLAN time, as before) when ANY of:

- `feature.json.greenfield == true` — greenfield PATTERNS is stack conventions, authored by the planner;
- `feature.workspace` is non-null — workspace analog mining is planner-scoped (per-repo graphs);
- `docs/loop-spec/features/{slug}/PATTERNS.md` already exists (resume / ITERATE re-entry);
- GSD ingestion supplies it: run `bash "${CLAUDE_SKILL_DIR}/../../lib/gsd-ingest.sh" patterns "{slug}" "docs/loop-spec/features/{slug}/PATTERNS.md"` — on `INGESTED`, set `artifacts.patterns` + `artifacts.patternsSource = "gsd-ingest"` via `lib/feature-write.sh` and skip;
- `feature.json.bootstrapPendingDomains` is non-empty — the codebase maps the mapper grounds in do not exist yet (first-run projects keep the PLAN-time path).

Otherwise fire ONE background `Agent` call and do NOT wait for it (same one-shot background dispatch pattern as cycle Step 5.5b; background subagents do not inherit the worktree cwd, so resolve `WT_ROOT="$(git rev-parse --show-toplevel)"` and pass absolute paths):

Build the call without a `model` key. If `feature.models.patternMapper` is one of
the four Agent aliases, add that key with the alias; when it is `inherit`, leave
the key absent.

When `LOOP_SPEC_MAX_PARALLEL_SUBAGENTS` is set, do not background this optional
prefetch across the critique dispatch. Run and await it now within the cap, or skip
the prefetch and let PLAN produce PATTERNS.md at its normal Step 0.

```
Agent({
  subagent_type: "loop-spec:pattern-mapper",
  description: "Prefetch PATTERNS.md: {slug}",
  prompt: """
    slug: {slug}
    spec_path: {WT_ROOT}/docs/loop-spec/features/{slug}/SPEC.md
    codebase_mapping_paths: {WT_ROOT}/docs/loop-spec/codebase/*.md

    Produce {WT_ROOT}/docs/loop-spec/features/{slug}/PATTERNS.md per your role
    definition (agents/pattern-mapper.md). Use absolute paths throughout. Do NOT commit.

    Existence guard: if PATTERNS.md already exists at the moment you are about to
    write, STOP without writing — a planner produced it first and its version wins.

    When done, reply: "DONE: patterns"
  """
})
```

Then record the in-flight marker via `lib/feature-write.sh` (`artifacts.patternsPrefetch = "in-flight"`) and emit the dispatch event: `bash "${CLAUDE_SKILL_DIR}/../../lib/events.sh" emit ".loop-spec/features/${slug}" dispatch --phase "discuss" --data '{"role":"pattern-mapper","model":"<resolved selector>","rung":"background"}' || true`.

SPEC.md may still be revised by the critique gate after this fires — acceptable: PATTERNS.md maps concept analogs, which are robust to spec wording changes. If the gate changes the spec's SCOPE materially, PLAN's planner amends PATTERNS.md (its brief already covers producing or extending it).

### Step 2 - TeamCreate the discuss team

The roster is `challenger-1` only. Add `spec-writer-1` only when
`docs/loop-spec/features/{slug}/SPEC.md` is missing (resume / intake edge). Never
spawn `advocate-1`. Autonomous fast path: `challenger-1` only; continue at Step 4.

```
TeamCreate({
  name: "loop-spec-discuss-{slug}",
  teammates: [
    { name: "challenger-1", subagent_type: "loop-spec:challenger" }
  ]
})
```

Each teammate object MUST include `subagent_type` (binds the teammate to its role
definition in `agents/*.md`). Add `model` only when the matching
`feature.models.<role>` value is an Agent alias; omit it for `inherit`. Spawning
by name alone -- e.g., `teammates: ["challenger-1"]` -- leaves the harness
with no role binding and is incorrect.

Update `feature.json` via `lib/feature-write.sh`:
- `currentTeamName = "loop-spec-discuss-{slug}"`
- `currentTeammates = ["challenger-1"]` (plus `spec-writer-1` only when spawned)

### Step 3 - Revise SPEC.md (spec-writer only if the file is missing)

**If `docs/loop-spec/features/{slug}/SPEC.md` exists:** the lead Edits it in place from
the transcript (resolved dimensions, design decisions, boundaries). Do not spawn
`spec-writer-1` and do not re-author from scratch. Preserve `ambiguity_scores`
verbatim except dropping resolved `unresolved_dimensions`. Then proceed to Step 4.

**If SPEC.md is missing** (resume / intake edge): spawn `spec-writer-1` (model:
`feature.models.specWriter`) and send:

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

    Read the transcript. Write SPEC.md at the output path. Every fact asserted about an external system must cite an `EVID-NNN` entry from the evidence_path ledger or be written as an explicit `ASSUMPTION: <claim> | verify: <command>` per `skills/shared/grounding-protocol.md`.

    When done, send:
      SendMessage({to: "lead", message: "SPEC.md written"})
    then go idle.
  """
})
```

Stop after SendMessage. The harness resumes this turn on `TeammateIdle` from `spec-writer-1`. Never AskUserQuestion as a wait. If spec-writer-1 goes idle without producing `SPEC.md`:
- Send `SendMessage({to: "spec-writer-1", message: "SPEC.md not found at docs/loop-spec/features/{slug}/SPEC.md. Write it now and send lead the SPEC.md written message."})` once.
- If still idle without output on second idle, AskUserQuestion is a real stuck-teammate question (retry / lead-author / abort), never a wait. Autonomous mode (`feature.json.autonomous`): re-dispatch the teammate fresh ONCE; if that also produces nothing, the lead authors SPEC.md itself from the same brief and continues, noting `lead-authored` in the transcript and `warnings[]` — never wait on a human, and never treat the warning as the handler (`skills/shared/autonomous-mode.md`, continuation ladder).

On `SPEC.md written` message received: proceed to Step 4.

### Step 4 - Critique gate (challenger-only; probe may skip)

The skip is declared on the cycle graph, not here: `graph/cycle.graph.json` routes
`discuss.critique.gate` through `lib/graph/probes/discuss-critique.sh`, and
`graph/critique.graph.json` is the challenger-only protocol when the gate runs.
Obey the probe:

```bash
probe_line="$(bash "${CLAUDE_SKILL_DIR}/../../lib/graph/probes/discuss-critique.sh" \
  --feature-dir ".loop-spec/features/{slug}")"
echo "$probe_line"
```

If `gate=skip`: log one line — `discuss critique skipped (<reason>)` — and continue
at Step 5.75. Typical reasons: `spec already gated: gate_passed, no unresolved
dimensions, no security signal`, `maintenance profile, no security signal`, and a
persisted `compact gatePlan specCritique: <classifier reason>`. The compact route is
resolved before this legacy probe by `graph/cycle.graph.json`; its reason remains durable
in `feature.json.gatePlan` (see `skills/shared/compact-profile.md`). A
security signal and an ITERATE re-entry never skip (the probe fails closed to
`gate=run`). Format + grounding lints at Step 5.75 still run.

If `gate=run`: run the protocol per `skills/shared/critique-gate-protocol.md` (gate
open, single-critic pass, adjudication, fix loop, gateHistory, currentGate reset):

- `phase=discuss`, `gate=spec-critique`, `artifact=SPEC.md`,
  `artifact_path=docs/loop-spec/features/{slug}/SPEC.md`
- `author=` the LEAD (Edit SPEC.md) unless `spec-writer-1` was spawned in Step 3
- `next_step=Step 5.75`
- Model: `feature.models.challenger` (activated for DISCUSS immediately before
  entry; do not re-derive from model-matrix). Never spawn `advocate-1`.

**Dispatch telemetry (`skills/shared/dispatch-events.md`):** emit one `dispatch` event per teammate actually launched in this phase (challenger; spec-writer only when spawned) — `bash "${CLAUDE_SKILL_DIR}/../../lib/events.sh" emit ".loop-spec/features/${slug}" dispatch --phase "discuss" --data '{"role":"<role>","model":"<resolved selector>","rung":"team"}' || true`. One event per LAUNCH; `SendMessage` rework rounds and delta re-verifies do not re-emit.

**Round telemetry:** where the protocol says "emit the phase's `gate_round` event", run
(non-fatal; `"mode":"single-critic"` on the solo pass, `"mode":"delta"` on delta
re-verifies):

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/events.sh" emit ".loop-spec/features/${slug}" gate_round \
  --phase "discuss" --data '{"gate":"spec-critique","round":<N>,"mode":"single-critic"}' || true
```

### Step 5 - Adjudicate findings and synthesize fix-list

Adjudicate per the protocol's table (`skills/shared/critique-gate-protocol.md`,
"Adjudication") and run its fix loop (gateHistory fail entry BEFORE re-dispatch, snapshot,
author re-dispatch, delta re-verify, deadlock-kept, pass entry + `currentGate`
reset). DISCUSS supplies these phase actions and deltas:

- **`{user_intent_action}`** (finding depends on user intent, autonomous mode): adopt the
  more reversible reading and record it to disk — `bash
  "${CLAUDE_SKILL_DIR}/../../lib/decisions.sh" add "{feature_dir}" discuss "<dimension>"
  "<reading adopted>" "more reversible"` (`skills/shared/autonomous-mode.md`).
- **`{ungrounded_action}`** (`UNGROUNDED:` finding): append the probe result via `bash
  "${CLAUDE_SKILL_DIR}/../../lib/evidence.sh" add
  "docs/loop-spec/features/{slug}/EVIDENCE.md" "<claim>" "<command>" "<output>"`, then add
  a fix-list item carrying the `EVID-NNN` + output excerpt so the revision cites it.
- **Author re-dispatch:** the LEAD applies the fix-list to SPEC.md directly (Edit
  tool). If `spec-writer-1` was spawned because SPEC.md was missing, re-dispatch it
  instead: it reads the current SPEC.md, applies every fix-list item in place, sends
  `SPEC.md written` to lead, goes idle.
- **Snapshot also hashes** (before the fix-list dispatch, alongside the protocol's `cp`):

  ```bash
  spec_hash_before="$(git hash-object docs/loop-spec/features/{slug}/SPEC.md 2>/dev/null || echo none)"
  ```

- **No-op-revision shortcut (skip the redundant re-critique).** When the revision lands,
  recompute `spec_hash_after` the same way. If `spec_hash_after == spec_hash_before` (no
  substantive change), do NOT delta re-verify: record the gate as converged with
  `notes: "spec-writer made no change to SPEC.md; re-critique skipped"` in the
  `gateHistory` pass entry, reset `currentGate`, and proceed to Step 5.75.

On gate pass, proceed to Step 5.75.

### Step 5.75 - Format + grounding gates (deterministic, ALWAYS run)

Structural format first — PLAN, VERIFY, and the iterate judge parse SPEC.md by its
template headings (`### Good Enough` checkboxes especially: criteria-coverage silently
skips when the heading drifts, and every criterion then ships unverified):

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/artifact-lint.sh" spec "docs/loop-spec/features/{slug}/SPEC.md"
format_exit=$?
```

Then the grounding gate:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/grounding-lint.sh" "docs/loop-spec/features/{slug}/SPEC.md"
grounding_exit=$?
```

Exit 1 from either BLOCKS: re-dispatch spec-writer-1 via `SendMessage` with the FLAG lines (format flags: fix the structure per `skills/shared/artifact-templates/SPEC.md.template`; grounding flags: cite ledger entries or rewrite as ASSUMPTION per `skills/shared/grounding-protocol.md`); autonomous fast path: the lead applies the FLAG fixes directly. Retries are unbounded — repeat until both lints pass. On revision received, re-run ONLY these lints — lint-only failures do NOT re-run the critique gate. Both exit 0: proceed to Step 6.

### Step 5.8 - Join codebase bootstrap (if pending)

If `feature.json.bootstrapPendingDomains` is non-empty (set during cycle Step 5.5b when background mappers were fired) — PLAN requires all 5 domain docs, so join the background work now (it has had the whole phase to run concurrently with the critique gate):

1. Check once whether all 5 domain docs exist. Do not sleep. A `sleep` loop freezes the session between DISCUSS and PLAN (`skills/shared/harness-call-contracts.md`).
   ```bash
   all_present=true
   for d in TECH ARCH QUALITY CONCERNS DOMAIN; do
     [[ -f "docs/loop-spec/codebase/${d}.md" ]] || { all_present=false; break; }
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

3. If any are missing: print which domains are still missing, then fall back to synchronous invocation immediately:
   ```
   Skill(loop-spec:map-codebase) args: --domain {csv-of-still-missing-lowercased}
   ```
   Never AskUserQuestion as a wait. Never `sleep` to join.

If `feature.json.bootstrapPendingDomains` is empty (codebase docs already existed or GSD-ingested): skip this step.

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

### Step 7 - TeamDelete and clear team state

```
TeamDelete({name: "loop-spec-discuss-{slug}"})
```

Update `feature.json` via `lib/feature-write.sh`:
- `currentTeamName = null`
- `currentTeammates = []`

### Step 8 - Phase routing

Always return to the cycle orchestrator; never invoke a successor phase directly.
DISCUSS declares no successor — `graph/cycle.graph.json` does, and the engine
(`lib/graph/run.sh`, cycle Step 6) selects the next node. Cycle owns the phase
boundary: continuous mode enters the engine-selected node immediately, while
`phaseHandoff == true` writes the paused result and ends the main-agent invocation.
For `step` / `interactive`, include
`DISCUSS complete. SPEC at docs/loop-spec/features/{slug}/SPEC.md.` in the returned
phase summary.

Return.

## Non-interactive mode

Skip Step 1 only when one of these is actually true:

- `feature.json.autonomous == true`, or
- `LOOP_SPEC_NON_INTERACTIVE=1`, or
- the caller passed a pre-written transcript path and that file exists.

`execStyle == "auto"` is none of those. Auto with a human still grills. When a transcript file exists, read it and proceed to Step 2 (TeamCreate); do not skip the grill because the style is `auto` and the file is missing.

## Resume

If invoked with `currentPhase == "discuss"` already in `feature.json`:

1. Read `feature.json` to determine subphase state:
   - `artifacts.spec` is null: transcript may exist; check `.loop-spec/features/{slug}/discuss-transcript.md`.
   - `artifacts.spec` is set: SPEC.md was written; check `currentGate.round`.
   - `currentGate.round > 0`: critique was in progress; load prior round summaries from `gate-logs/spec-critique-round-*.md`.

2. Live-team probe:
   - If `currentTeamName != null`: call `TaskList({team: currentTeamName})`.
     - Error (team gone): clear `currentTeamName`, recreate team via `TeamCreate`, replay from the detected subphase.
     - Success (team live): print orphan-cleanup message with explicit team name; require manual `TeamDelete` before resume.
   - If `currentTeamName == null`: recreate team via `TeamCreate` and replay from subphase.

3. On resume with a prior gate in progress: resume per
   `skills/shared/critique-gate-protocol.md` "Resume".

4. Do not re-ask conversation questions the user already answered (transcript is persisted to disk).
