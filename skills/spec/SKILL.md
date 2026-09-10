---
name: spec
description: SPEC phase - grounded questions and decisions; gates on no unresolved intent questions. Cycle-internal - invoked by /loop-spec:cycle; not for ad-hoc invocation (start there).
allowed-tools: Bash Read Write Edit Glob Grep Skill Agent AskUserQuestion
---

# SPEC

You run on the main thread (a subagent cannot hold an interview). You produce
`docs/loop-spec/features/{slug}/SPEC.md` from repository evidence and concrete decisions, and close the phase with one command. `feature_dir` is
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

## Intent questions

An intent gap is a choice the user would notice in the result that repository evidence
cannot settle. Investigate first. Decide implementation details with a one-line reason;
collect genuine intent gaps in one list with a recommended answer and its tradeoff.
The gate is an empty `unresolved_questions` list, never a self-assessed number.
`${CLAUDE_SKILL_DIR}/references/interview-prompts.md` gives examples of questions worth asking.

## 1. Scout

`skills/spec-lite/SKILL.md` entered first and cited the files it read
(`lib/footprint.sh show`); it handed here because the record did not make a oneshot
candidate. Extend that scout, never restart it.

Read `skills/shared/approach-selection.md`: separate the outcome and binding
constraints from a suggested method before the interview or draft. Preserve that
distinction in every path below, including synthesis and ingest.

Read `feature_dir/` (decisions ledger on resume) and `docs/loop-spec/features/{slug}/`.
Then read the code: search the feature
area by the user's vocabulary and the obvious symbols, read the entry points you find,
follow imports and callers far enough to name the boundaries the change crosses. Fan
scanning out to subagents that return `file:line` evidence (dispatch, then stop;
`skills/shared/dispatch.md`). Workspace mode scans each repo separately and keeps the
repo name on every finding. Greenfield has no code: ground in the goal and the chosen
stack's conventions. Use `skills/shared/engineering-stances.md` for the build-from-scratch
stance: data model, API surface, interface, and the input whose growth sets the bound.

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
three files, no unresolved question, and no security signal in SPEC.md or those files
routes the run through ONESHOT (implement, one review, verify, deliver) instead of
DISCUSS through ITERATE. Write the footprint you can defend from `file:line` evidence,
never a shorter one to earn the route; a fourth file found during ONESHOT escalates the
run to the full path at the cost of the pass already spent. Greenfield names the files
it will create. A footprint file's existing test module is named either way: in the
footprint when it changes, in Implementation notes as unchanged when it does not
(`lib/oneshot-spec-lint.sh` flags a test module the spec never names).

## 2. Resolve questions (by `path`)

Reuse prior answers before asking. Present all remaining intent questions together at
one checkpoint after investigation. Each names the choice, recommended answer, and
observable consequence. Do not invent questions when the request and code settle them.

- **`interview`**: a human is attached, including `execStyle: auto`. Ask the consolidated
  list once through `AskUserQuestion`; record answers and rationales. Write the draft
  before requesting approval of its Goal and Boundary. An unanswered question stays in
  `unresolved_questions`; never substitute a score or silently assume the answer.
- **`self-answer`**: follow `skills/shared/autonomous-mode.md`, "The supervised path". For `oracle=supervisor`,
  send the consolidated questions (or the concrete draft approval when no gaps remain)
  through the question tool; retain supervised evidence and honor `halt`. For
  `oracle=self`, take each recommended answer, preferring existing behavior, then the
  most reversible option. Record every answer and reason using `decisions.sh add`.
  No human wait. A question that cannot be resolved within authorization leaves a
  named blocking condition and an escalated driver result.
- **`synthesize`**: derive the draft from the request, prior decisions, and scout.
  `LOOP_SPEC_ANSWER_SPEC_CONFIRM=no` publishes a paused result with reason
  `spec-confirmation-declined`; invalid values fail with exit 2. Do not ask in a
  non-interactive run. Resolve preference gaps with recorded recommendations.
- **`ingest`**: preserve the supplied requirements verbatim and normalize only format.
  Investigate gaps, then use the attended or autonomous rule above according to the
  run mode. A supplied draft is evidence, not permission to discard a requirement.

Record decisions through:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/decisions.sh" add "$feature_dir" spec "<question>" "<answer>" "<reason>"
```

Render the ledger into SPEC.md's `<decisions>` block with `decisions.sh render`.
Never AskUserQuestion as a wait for a scout or reviewer.

## 3. Write

`SPEC.md` follows `skills/shared/artifact-templates/SPEC.md.template`.
The full route begins with this frontmatter; questions are a JSON array on one line
(valid YAML), so punctuation inside a question is unambiguous:

```yaml
---
route: full
unresolved_questions: []
footprint:
  - src/slugify.py
  - tests/test_slugify.py
---
```

While waiting for an answer, use for example
`unresolved_questions: ["Should empty names be rejected or preserved?"]`.
Remove a question only after its answer and rationale are recorded. No ambiguity
scores or interview transcript. The oneshot skeleton is owned by spec-lite.

A draft written anywhere but `docs/loop-spec/features/{slug}/SPEC.md` in the checkout
that holds `feature.json` lands through `bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-driver.sh"
spec write --feature-dir "$feature_dir" --file <draft>`, which accepts no other target.

Before approval, for drafts over 60 lines, dispatch one fresh reviewer with SPEC.md,
the template, and `skills/shared/review-prompts/prose-pruning.md`. Apply supported cuts,
preserving criteria, decisions, questions, and grounding. Record dispositions in the
ledger. This pass does not invent a transcript or score.

## 4. Approval and exit

After the human approves the written Goal and Boundary, record the freeze:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-driver.sh" spec approve --feature-dir "$feature_dir" --source human
```

For unattended runs use `--source autonomous` after recording recommended decisions;
a supervisor's explicit approval uses `--source supervised`. Never label an assumed
answer human approval. The digest is immutable: later intent gaps return to the human,
and cannot be fixed by changing the approval record. Phase exit verifies the digest.


Return to the cycle; never invoke a successor phase and never run the exit yourself.
The cycle's `next --returned-from spec` runs `lib/phase-exit.sh spec`: it records the
artifact pointers, commits SPEC.md, and closes the phase, or answers `REDO` with the
`FLAG` lines when SPEC.md drifted from the template, in which case you are invoked again
to fix it in place and return. In `step`/`interactive` styles say
`SPEC complete. SPEC.md at docs/loop-spec/features/{slug}/SPEC.md.`

## Resume

Read the existing SPEC.md and decisions ledger. Reuse recorded answers and investigate
only questions still unresolved; never restart an interview or re-grade a draft.
Return an existing complete artifact through step 4.
