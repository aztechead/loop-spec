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
pb="$(bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-driver.sh" phase-begin spec --feature-dir "$feature_dir")"
# .entry.fields (the feature.json keys this phase consumes)  .entry.read[] (each file to read)
# .entry.flags[] (a missing ingress; relay and return)  .mode.path=ingest|self-answer|synthesize|interview
# .mode.oracle=supervisor|self  .mode.reason  .mode.greenfield=true|false
```

`path` below is `.mode.path`; the `phase-entry.sh` and `phase-mode.sh` lines it folds
are the same probes, read once.

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

Read `skills/shared/approach-selection.md`: separate the outcome and binding
constraints from a suggested method before the interview or draft. Preserve that
distinction in every path below, including synthesis and ingest.

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
and for every runtime or library the ask names by version, ask the plugin's own tool
before anything else: `bash "${CLAUDE_SKILL_DIR}/../../lib/docs-probe.sh" latest <name>`
(`--ecosystem runtime` for a language) is the version, and
`bash "${CLAUDE_SKILL_DIR}/../../lib/docs-probe.sh" docs <name> --topic <what the feature needs>`
is how its current release does it; `unverified` means record an `ASSUMPTION`, then
try any web search or URL-fetch tool the session provides. `evidence.sh add` the
finding with the probe's `source=` URL as the command (the dependency-idiom rule,
`skills/shared/grounding-protocol.md` "Current documentation"). A local catalog
(`uv python list`, `pyenv install --list`) is never the version source, and an installer
whose catalog lacks the version the probe named gets upgraded before anything is
installed (its own current version is one more probe call), never worked around with an
older build or a pre-release: a run took a stale catalog's release candidate as the
current Python and paid twenty commands for a crash the final release did not have; the
next run knew the final version, kept the stale installer, and pinned the release
candidate in SPEC anyway. The idiom in today's docs outranks the idiom in
model memory.

Name the footprint: the repository-relative files the change will touch, from the scout's
evidence (the file that holds the bug, the module that gains the flag, its test). It goes
into the frontmatter as `footprint:` and `lib/graph/probes/oneshot.sh` reads it: at most
three files, no unresolved dimension, and no security signal in SPEC.md or those files
routes the run through ONESHOT (implement, one review, verify, deliver) instead of
DISCUSS through ITERATE. Write the footprint you can defend from `file:line` evidence,
never a shorter one to earn the route; a fourth file found during ONESHOT escalates the
run to the full path at the cost of the pass already spent. Greenfield names the files
it will create. A footprint file's existing test module is named either way: in the
footprint when it changes, in Implementation notes as unchanged when it does not
(`lib/oneshot-spec-lint.sh` flags a test module the spec never names).

Score the four dimensions from what you know now and display the scoring block.

## 1a. The oneshot candidate

The scout's record is the footprint. As you read, cite each file the change will touch
with the line that shows why, and mark a file the change must not touch (a test the
task protects, a generated file) as read-only:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/footprint.sh" cite "$feature_dir" <path>:<line> "<why>"
bash "${CLAUDE_SKILL_DIR}/../../lib/footprint.sh" cite "$feature_dir" <path>:<line> --read-only "<why>"
```

One call then decides the route from that record (`lib/graph/probes/oneshot.sh
--candidate`: at most three files, none read-only, no security signal) and, on the
short route, writes the spec skeleton where the exit gate reads it:

```bash
sk="$(bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-driver.sh" spec skeleton --feature-dir "$feature_dir")"
```

`.route` is `full`: continue at step 2 as written (`.reason` says why). `.route` is
`oneshot`: the rest of this phase is the list below; steps 2 and 3 apply only where it
says so. The route lengthens only (a fourth file escalates in ONESHOT).

- The scout is done. No `doc-deps.sh`, no `docs-probe.sh`, no pattern fan-out. A claim
  about an external system still gets its read-only probe first
  (`skills/shared/grounding-protocol.md#Probe-before-assert rule`).
- The driver is the only writer of the skeleton; you never open it. Fill its values
  through `cycle-driver.sh spec fill --feature-dir "$feature_dir"`, one value per
  call, and read the `flags` each answer carries (the exit gate's findings so far):
  `--intent "<the ask, one paragraph>"`; `--file <path> --note "<what changes there>"`
  once per footprint file; `--criterion "<check command> exits 0: <what it proves>"`
  once per observable outcome; `--grounding "<file:line - fact>"` per grounding row.
  Every footprint file is a promise the ONESHOT exit checks against the diff; a cited
  file the change will not touch leaves the footprint through
  `cycle-driver.sh spec footprint drop --file <path> --reason "<why>"`, never through a
  bullet, and a test module of a footprint file cannot leave it.
- No score and no transcript on this path. An intent gap is a choice the user would
  notice in the result that the code cannot settle; everything else you decide and
  record (`bash "${CLAUDE_SKILL_DIR}/../../lib/decisions.sh" add "$feature_dir" spec "<q>" "<a>" "<why>"`).
  Gaps are one list, asked once: `interview` and `ingest` in one `AskUserQuestion`
  round; `self-answer` and `synthesize` take the recommended answer into the same
  record (`skills/shared/autonomous-mode.md#The self-answer rule`). A gap left open is
  `cycle-driver.sh spec escalate --reason "<the gap>"`: the full path.
- No pruning pass: the shape is under 60 lines. Then step 4.

## 2. Interview (by `path`)

Perspectives, one per round, 2-3 questions each, structured multiple-choice with
tradeoffs whenever options are discernible: Researcher (round 1; **Foundations** when
greenfield: stack, tooling, walking skeleton, the canonical test/lint/typecheck
commands, and the build-from-scratch stance's data model, API surface, interface, and
scaling input, `skills/shared/engineering-stances.md`; all land in SPEC.md as
requirements), Simplifier, Boundary Keeper, Failure Analyst, Seed Closer (rounds 5-6,
lowest-scoring dimensions).

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
- **`self-answer`** (autonomous): the mode line carries `oracle=supervisor` or
  `oracle=self` (`lib/supervisor/oracle.sh`). `oracle=supervisor` asks each
  perspective's questions through `AskUserQuestion` (recommended option first) and
  records answers as `supervised` per `skills/shared/autonomous-mode.md`
  "The supervised path"; `phase-exit.sh` flags the phase when a named supervisor was
  never asked. What comes back empty or recommended, and everything under `oracle=self`,
  you answer yourself. Walk all perspectives in ONE pass, answering each question
  with the option you would have marked recommended: what the code
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

`SPEC.md` follows `skills/shared/artifact-templates/SPEC.md.template`, or the oneshot
shape `skills/shared/artifact-templates/SPEC-oneshot.md.template` (at most 60 lines:
the ask inside the frozen `## Intent` block, which no later phase edits, Implementation
notes, Good Enough criteria each with the command that checks it, Grounding) when the
footprint is at most three files and no dimension is unresolved.
The shape follows the facts; the route is the probe's. Both begin with:

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
footprint:
  - src/slugify.py
  - tests/test_slugify.py
---
```

`route: full` at the top level is the one other key: the writer or ONESHOT adds it to
send a run down the full path; nothing sends a full run to ONESHOT.

A draft written anywhere but `docs/loop-spec/features/{slug}/SPEC.md` in the checkout
that holds `feature.json` lands through `bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-driver.sh"
spec write --feature-dir "$feature_dir" --file <draft>`, which accepts no other target.

On the `interview` and `ingest` paths write the transcript (rounds, questions, scores;
`source: spec-draft.md` when applicable) to `feature_dir/spec-interview-transcript.md`.
The `self-answer` and `synthesize` paths write none: an autonomous run's record is the
`decisions.sh` ledger rendered into the `<decisions>` block, and a transcript of a
conversation nobody had is artifact weight the next phase pays to read.

**Pruning pass (advisory, skip under 60 lines):** dispatch ONE fresh reviewer
(a nameless Agent with no `subagent_type`, never a cycle role; `run_in_background:
false`; its tool result is the listing) carrying
`skills/shared/review-prompts/prose-pruning.md` verbatim plus SPEC.md and the template
only (never the transcript). Apply `duplicate`/`narrative` cuts; judge the rest; never
cut `### Good Enough` criteria, decisions, scores, or grounding lines; record every
disposition in the transcript when one exists, else in the `decisions.sh` ledger.

## 4. Exit

Return to the cycle; never invoke a successor phase and never run the exit yourself.
The cycle's `next --returned-from spec` runs `lib/phase-exit.sh spec`: it records the
artifact pointers, commits SPEC.md, and closes the phase, or answers `REDO` with the
`FLAG` lines when SPEC.md drifted from the template, in which case you are invoked again
to fix it in place and return. In `step`/`interactive` styles say
`SPEC complete. SPEC.md at docs/loop-spec/features/{slug}/SPEC.md.`

## Resume

`artifacts.spec` set: SPEC.md exists, return (step 4). Otherwise read the transcript
(interview paths) or the decisions ledger (autonomous paths), restore the prior round
scores, and continue from the next round; never re-ask answered questions.
