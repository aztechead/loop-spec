---
name: spec
description: "Write SPEC.md from repository evidence and recorded decisions. Resolve intent questions before approval. Internal phase of /loop-spec:cycle. Start there for repository work."
allowed-tools: Bash Read Write Edit Glob Grep Skill Agent AskUserQuestion
---

# SPEC

Run in the main thread so you can interview the user.
Write `docs/loop-spec/features/{slug}/SPEC.md` from repository evidence and recorded decisions.
Use the cycle's existing `.loop-spec/features/{slug}` as `feature_dir`. Never create a feature directory here.
Read only the entry packet as input. Relay any entry FLAG and return:

```bash
pb="$(bash "${LOOP_SPEC_SKILL_DIR}/../../lib/cycle-driver.sh" phase-begin spec --feature-dir "$feature_dir")"
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
`${LOOP_SPEC_SKILL_DIR}/references/interview-prompts.md` gives examples of questions worth asking.

## 1. Scout

`skills/spec-lite/SKILL.md` entered first and cited the files it read
(`lib/footprint.sh show`); it handed here because the record did not make a oneshot
candidate. Extend that scout, never restart it.

Read `skills/shared/approach-selection.md`: separate the outcome and binding
constraints from a suggested method before the interview or draft. Preserve that
distinction in every path below, including synthesis and ingest.

Read `feature_dir/` (decisions ledger on resume) and `docs/loop-spec/features/{slug}/`.
Search the feature area using the user's terms and relevant symbols.
Read the entry points. Follow imports and callers until you can name the boundaries the change crosses.
Delegate scans to subagents that return `file:line` evidence. Dispatch, then stop, following `skills/shared/dispatch.md`.

In workspace mode, scan each repository separately. Label each finding with its repository.
For greenfield work, use the goal and chosen stack's conventions as evidence.
Follow the build-from-scratch stance in `skills/shared/engineering-stances.md` for data, APIs, interfaces, and scale limits.

Before any factual claim about an external system (dataset, API, service, infra), run
the cheapest read-only probe and record it; cite the `EVID-NNN` it prints, or write
`ASSUMPTION: <claim> | verify: <command>` when no probe is possible
(`skills/shared/grounding-protocol.md`):

```bash
bash "${LOOP_SPEC_SKILL_DIR}/../../lib/evidence.sh" add "docs/loop-spec/features/{slug}/EVIDENCE.md" "<claim>" "<command>" "<probe output>"
```

Check the dependencies that the feature uses:

1. Run `bash "${LOOP_SPEC_SKILL_DIR}/../../lib/doc-deps.sh" scan <the files the scout found>` to list imported third-party dependencies.
2. For each relevant dependency, run `bash "${LOOP_SPEC_SKILL_DIR}/../../lib/docs-probe.sh" latest <name>` first.
   Include runtimes and libraries the request names by version. Use `--ecosystem runtime` for a language.
3. Run `bash "${LOOP_SPEC_SKILL_DIR}/../../lib/docs-probe.sh" docs <name> --topic <what the feature needs>` for current usage.
4. For `unverified`, record an `ASSUMPTION`, then try available web search or URL-fetch tools.
5. Record findings with `evidence.sh add`. Use the probe's `source=` URL as the command.

Follow `skills/shared/grounding-protocol.md`, "Current documentation".
Never use a local catalog such as `uv python list` or `pyenv install --list` as the version source.
If the installer lacks the verified version, probe the installer's current version and upgrade it before installing.
Do not substitute an older build or prerelease to accommodate a stale installer.
Use current documentation instead of remembered library conventions.

Write `footprint:` in the frontmatter with the repository-relative files the change will touch.
Support that list with scout `file:line` evidence. For greenfield work, list the files to create.
Never omit a file to qualify for a shorter route.

`lib/graph/probes/oneshot.sh` selects ONESHOT only when all these conditions hold:

- The footprint has at most three files.
- No intent questions remain unresolved.
- SPEC.md and the footprint files have no security signal.

ONESHOT implements, reviews once, verifies, and delivers. A fourth file requires promotion to the full route.
Name each footprint file's existing test module. Include it in the footprint if it changes, or mark it unchanged in Implementation notes.
`lib/oneshot-spec-lint.sh` flags omitted test modules.

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
bash "${LOOP_SPEC_SKILL_DIR}/../../lib/decisions.sh" add "$feature_dir" spec "<question>" "<answer>" "<reason>"
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
Record the answer and rationale before removing a question.
Do not include ambiguity scores or an interview transcript. Spec-lite owns the oneshot skeleton.

A draft written anywhere but `docs/loop-spec/features/{slug}/SPEC.md` in the checkout
that holds `feature.json` lands through `bash "${LOOP_SPEC_SKILL_DIR}/../../lib/cycle-driver.sh"
spec write --feature-dir "$feature_dir" --file <draft>`, which accepts no other target.

Before approval, for drafts over 60 lines, dispatch one fresh reviewer with SPEC.md,
the template, and `skills/shared/review-prompts/prose-pruning.md`. Apply supported cuts,
preserving criteria, decisions, questions, and grounding. Record dispositions in the
ledger. This pass does not invent a transcript or score.

## 4. Approval and exit

After the human approves the written Goal and Boundary, record the freeze:

```bash
bash "${LOOP_SPEC_SKILL_DIR}/../../lib/cycle-driver.sh" spec approve --feature-dir "$feature_dir" --source human
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
