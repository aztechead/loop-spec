---
name: spec
description: SPEC phase - Socratic interview with quantitative ambiguity scoring; gates ambiguity <= 0.20. Cycle-internal - invoked by /loop-spec:cycle; not for ad-hoc invocation (start there).
allowed-tools: Bash Read Write Edit Glob Grep Skill Agent AskUserQuestion
---

# SPEC

You run on the main thread (a subagent cannot hold an interview). You produce
`docs/loop-spec/features/{slug}/SPEC.md` from a grounded interview, scored on four
ambiguity dimensions, and close the phase with one command. `feature_dir` is
`.loop-spec/features/{slug}` (the cycle created it; this skill never bootstraps one).
Your inputs are the entry packet and nothing else; a FLAG is a prior phase's failure, relay it:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/phase-entry.sh" spec --feature-dir "$feature_dir"
# fields=<the feature.json keys this phase consumes>  read=<each file to read>  FLAG on a missing ingress
```

```bash
mode="$(bash "${CLAUDE_SKILL_DIR}/../../lib/phase-mode.sh" spec --feature-dir "$feature_dir")"
# path=ingest|self-answer|synthesize|interview reason=... greenfield=true|false
```

## Ambiguity model

Score each dimension 0.0 (unclear) to 1.0 (clear) from the SPEC text you could write
right now, never from where the conversation seems headed:

| Dimension | Weight | Minimum | Measures |
|---|---|---|---|
| Goal clarity | 35% | 0.60 | Is the outcome specific and measurable? |
| Boundary clarity | 25% | 0.50 | What is in scope and out of scope? |
| Constraint clarity | 20% | 0.40 | Performance, compatibility, data requirements? |
| Acceptance clarity | 20% | 0.50 | How do we know it is done? |

`ambiguity = 1 - (0.35·goal + 0.25·boundary + 0.20·constraint + 0.20·acceptance)`.
The gate passes when `ambiguity <= 0.20` AND every dimension meets its minimum.
Calibration anchors and question banks: `${CLAUDE_SKILL_DIR}/references/interview-prompts.md`.

## 1. Scout

Read `feature_dir/` (prior transcript on resume) and `docs/loop-spec/features/{slug}/`.
Then read the code: search the feature
area by the user's vocabulary and the obvious symbols, read the entry points you find,
follow imports and callers far enough to name the boundaries the change crosses. Fan
scanning out to subagents that return `file:line` evidence (dispatch, then stop;
`skills/shared/dispatch.md`). Workspace mode scans each repo separately and keeps the
repo name on every finding. Greenfield has no code: ground in the goal and the chosen
stack's conventions.

Before any factual claim about an external system (dataset, API, service, infra), run
the cheapest read-only probe and record it; cite the `EVID-NNN` it prints, or write
`ASSUMPTION: <claim> | verify: <command>` when no probe is possible
(`skills/shared/grounding-protocol.md`):

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/evidence.sh" add "docs/loop-spec/features/{slug}/EVIDENCE.md" "<claim>" "<command>" "<probe output>"
```

Then name the frameworks in play:
`bash "${CLAUDE_SKILL_DIR}/../../lib/doc-deps.sh" scan <the files the scout found>` lists
the third-party dependencies those files import. For each one the feature will lean on,
look up how its current release does what the feature needs — any web search or
URL-fetch tool the session provides — and `evidence.sh add` the finding (the
dependency-idiom rule, `skills/shared/grounding-protocol.md` "Current documentation").
The idiom in today's docs outranks the idiom in model memory.

Score the four dimensions from what you know now and display the scoring block.

## 2. Interview (by `path`)

Perspectives, one per round, 2-3 questions each, structured multiple-choice with
tradeoffs whenever options are discernible: Researcher (round 1; **Foundations** when
greenfield: stack, tooling, walking skeleton, and the canonical test/lint/typecheck
commands, which land in SPEC.md as requirements), Simplifier, Boundary Keeper, Failure
Analyst, Seed Closer (rounds 5-6, lowest-scoring dimensions).

- **`interview`** (a human is attached). **`execStyle: auto` still interviews.** Auto
  means the cycle does not pause after this phase, not that nobody is there. Up to 6
  rounds of `AskUserQuestion`. After each round re-score and display:
  ```
  After round N:
    Goal:       0.xx (min 0.60) pass|needs work
    Boundary:   0.xx (min 0.50) ...
    Constraint: 0.xx (min 0.40) ...
    Acceptance: 0.xx (min 0.50) ...
    Ambiguity:  0.xx (gate <= 0.20)
  ```
  On gate pass emit the "Spec gate" question from the reference (write / one more
  round / done talking). At round 6 still failing, emit the "Max rounds" question
  (write anyway with `gate_passed: false` / keep talking / abandon). Abandon writes
  nothing: report it and return.
- **`self-answer`** (autonomous): walk all perspectives in ONE pass, answering each
  question yourself with the option you would have marked recommended: what the code
  already does first, then industry practice, then the most reversible choice. Score once
  at the end (`rounds_completed: 1`), honestly. A failing gate gets one Seed Closer
  follow-up pass, then writes anyway with the failing dimensions in
  `unresolved_dimensions`. Never abandon. Record every Q, A, and rationale in one Bash
  call chaining `bash "${CLAUDE_SKILL_DIR}/../../lib/decisions.sh" add "$feature_dir" spec "<q>" "<a>" "<why>"`,
  and render the record into SPEC.md's `<decisions>` block via `decisions.sh render`.
- **`synthesize`** (non-interactive, maintenance, or a compact gate plan): no
  interview. Write the best SPEC.md from the request and the scout, score it honestly.
  `LOOP_SPEC_ANSWER_SPEC_CONFIRM=no` on a passing gate, or
  `LOOP_SPEC_ANSWER_SPEC_OVERRIDE=no` on a failing one (defaults `yes`; any other
  value exits 2), writes no file: publish a paused cycle result with reason
  `spec-confirmation-declined` / `spec-override-declined` via `lib/cycle-result.sh
  write` and return. Under the maintenance profile a dimension below its minimum falls
  back to the ordinary interview.
- **`ingest`** (`feature_dir/spec-draft.md` exists; the user pre-authored the spec):
  score the draft, normalize it into the template preserving the author's requirements
  verbatim, add only what the format requires. A dimension below its minimum gets one
  targeted question in `step`/`interactive`; elsewhere it lands in
  `unresolved_dimensions` for DISCUSS.

Every interview `AskUserQuestion` is a real question. Never AskUserQuestion as a wait
while a scout or reviewer subagent runs.

## 3. Write

`SPEC.md` follows `skills/shared/artifact-templates/SPEC.md.template` and begins with:

```yaml
---
ambiguity_scores:
  goal_clarity: 0.85
  boundary_clarity: 0.80
  constraint_clarity: 0.75
  acceptance_clarity: 0.80
  ambiguity: 0.18
  rounds_completed: 3
  gate_passed: true
  unresolved_dimensions: []
---
```

Write the transcript (rounds, questions, scores; `source: spec-draft.md` or
`synthesized` when applicable) to `feature_dir/spec-interview-transcript.md`.

**Pruning pass (advisory, skip under 60 lines):** dispatch ONE fresh reviewer carrying
`skills/shared/review-prompts/prose-pruning.md` verbatim plus SPEC.md and the template
only (never the transcript). Apply `duplicate`/`narrative` cuts; judge the rest; never
cut `### Good Enough` criteria, decisions, scores, or grounding lines; record every
disposition in the transcript.

## 4. Exit

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/phase-exit.sh" spec --feature-dir "$feature_dir"
```

A `FLAG` means SPEC.md drifted from the template: fix it in place and run the command
again until it prints `phase-exit: ok (spec)`. It records the artifact pointers,
commits SPEC.md, and closes the phase. Return to the cycle; never invoke a successor
phase. In `step`/`interactive` styles say
`SPEC complete. SPEC.md at docs/loop-spec/features/{slug}/SPEC.md.`

## Resume

`artifacts.spec` set: SPEC.md exists, run step 4. Otherwise read the transcript, restore
the prior round scores, and continue from the next round; never re-ask answered
questions.
