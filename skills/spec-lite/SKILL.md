---
name: spec-lite
description: "Inspect the requested change and record its footprint. Fill the driver's short spec or continue to the full SPEC instructions. Internal cycle entry for NEXT phase=spec. Start at /loop-spec:cycle."
allowed-tools: Bash Read Glob Grep Skill AskUserQuestion
---

# SPEC, the candidate path

You are the lead of SPEC. `feature_dir` is `.loop-spec/features/{slug}`. Your inputs
are the entry packet and nothing else; a FLAG is a prior phase's failure, relay it:

```bash
DRV="${LOOP_SPEC_SKILL_DIR}/../../lib/cycle-driver.sh"
pb="$(bash "$DRV" phase-begin spec --feature-dir "$feature_dir")"
# .entry.fields (slug, feature_title, execStyle, greenfield, autonomous)
# .entry.read[] (spec-draft.md, prior decisions)  .entry.flags[]
```

## 1. Scout

Search the code using the request's terms and relevant symbols.
Read entry points. Follow imports and callers until you can locate the change.
Cite each affected file with a line that shows why it must change.
These citations form the footprint. Do not write a separate footprint list.

Only files marked `protected:` in the invocation are read-only.
For other files, `--read-only` records an ordinary citation.
The footprint automatically includes each cited source file's test module:

```bash
bash "${LOOP_SPEC_SKILL_DIR}/../../lib/footprint.sh" cite "$feature_dir" <path>:<line> "<why>"
bash "${LOOP_SPEC_SKILL_DIR}/../../lib/footprint.sh" cite "$feature_dir" <path>:<line> --read-only "<why>"
```

A claim about an external system gets its read-only probe first
(`skills/shared/grounding-protocol.md#Probe-before-assert rule`).

## 2. The route, from the record

```bash
sk="$(bash "$DRV" spec skeleton --feature-dir "$feature_dir")"
```

`.route` is `full` (`.reason` says why: four files, a read-only file, a security
signal): read the snapshot path in `.fullSpec` and continue from its step 1; your cites
stand and it extends the scout. `.route` is `oneshot`: the driver wrote the skeleton
at `.spec`, and the rest of SPEC is the list below. The route lengthens only, and a
gate lengthens it: a fourth file in the diff, a reviewer BLOCK, or a held exit.

## 3. Fill the skeleton

Only the driver writes the spec. Never open it for editing.
Fill its values through `bash "$DRV" spec fill --feature-dir "$feature_dir" --json -`.
Send `{intent, notes: {path: text}, criteria: [text], grounding: [text]}` on stdin.
Alternatively, send one value per call with the flags below.
Read the returned `flags` for current exit-gate findings:

- `--intent "<the ask, one paragraph, in the requester's terms>"`
- `--file <path> --note "<what changes there, with the symbol or line>"` once per
  footprint file
- `--command "<shell>" --expect "<what exit 0 proves>"` once per observable outcome:
  the driver writes the line and runs that command at the boundary; you never compose
  the sentence (`--row GE-001` replaces a criterion)
- `--execution-inputs '<JSON>'` alongside `--command`/`--expect` under a v1 contract
  (required; refused otherwise). Minimal declaration when the command touches no
  tracked toolchain, file, or external identity:
  `--execution-inputs '{"version":1,"toolchains":[],"localInputs":[],"externalInputs":[],"sensitiveInputs":[]}'`
- `--grounding "<file:line - the fact it shows>"` per grounding row

The footprint holds every cited file and the existing test module of each: a test
module the task does not need leaves it in one call,
`bash "$DRV" spec footprint drop --feature-dir "$feature_dir" --file <test module> --reason "<why>"`,
which is refused while the file it tests changes.

Under a v1 contract (`requirementsContract.format`, the default for every new cycle;
a resumed pre-7 cycle stays legacy -- `docs/loop-spec/requirements-format.md`), the
skeleton opens with an empty `### Good Enough`: the driver allocates a fresh
`GE-NNN`/`SC-NNN` on your first `--command`/`--expect` fill, never a placeholder row,
and `--row` names a requirement by that stable ID, never a position.

An intent gap is a choice the user would notice in the result that the code cannot
settle; everything else you decide and record
(`bash "${LOOP_SPEC_SKILL_DIR}/../../lib/decisions.sh" add "$feature_dir" spec "<q>" "<a>" "<why>"`).
Gaps are one list, asked once (one `AskUserQuestion` round attended; the recommended
answer into the same record autonomous). You never escalate: a gate does, from
evidence. No score, no transcript, no pruning pass: the shape is under 60 lines.

## 4. Return

Return to the cycle; never run the exit yourself. `next --returned-from spec` runs the
two spec lints and, on the short route, enters ONESHOT in this same session.
