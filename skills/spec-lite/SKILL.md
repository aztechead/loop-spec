---
name: spec-lite
description: SPEC's entry on every cycle - scouts the ask, decides the oneshot candidate from the scout's record, and on the short route fills the driver-written spec skeleton; on the full route it hands to loop-spec:spec. Cycle-internal - the driver names it under NEXT phase=spec; not for ad-hoc invocation (start at /loop-spec:cycle).
allowed-tools: Bash Read Glob Grep Skill AskUserQuestion
---

# SPEC, the candidate path

You are the lead of SPEC. `feature_dir` is `.loop-spec/features/{slug}`. Your inputs
are the entry packet and nothing else; a FLAG is a prior phase's failure, relay it:

```bash
DRV="${CLAUDE_SKILL_DIR}/../../lib/cycle-driver.sh"
pb="$(bash "$DRV" phase-begin spec --feature-dir "$feature_dir")"
# .entry.fields (slug, feature_title, execStyle, greenfield, autonomous)
# .entry.read[] (spec-draft.md, prior decisions)  .entry.flags[]
```

## 1. Scout

Search the code by the ask's vocabulary and the obvious symbols, read the entry points
you find, and follow imports and callers far enough to know where the change lands. As
you read, cite each file the change will touch with the line that shows why. The record
is the footprint; you never type it anywhere else. Read-only is the task's word, not
yours: a file the invocation named `protected:` is read-only, a `--read-only` mark on
any other file is a plain cite, and a cited source file's test module is in the
footprint by construction:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/footprint.sh" cite "$feature_dir" <path>:<line> "<why>"
bash "${CLAUDE_SKILL_DIR}/../../lib/footprint.sh" cite "$feature_dir" <path>:<line> --read-only "<why>"
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

The driver is the only writer of the spec; you never open it. Fill its values in one
call, `bash "$DRV" spec fill --feature-dir "$feature_dir" --json -` with a JSON object
`{intent, notes: {path: text}, criteria: [text], grounding: [text]}` on stdin (or one
value per call with the flags below), and read the `flags` the answer carries (the
exit gate's findings so far):

- `--intent "<the ask, one paragraph, in the requester's terms>"`
- `--file <path> --note "<what changes there, with the symbol or line>"` once per
  footprint file
- `--command "<shell>" --expect "<what exit 0 proves>"` once per observable outcome:
  the driver writes the line and runs that command at the boundary; you never compose
  the sentence (`--row GE-001` replaces a criterion)
- `--grounding "<file:line - the fact it shows>"` per grounding row

The footprint holds every cited file and the existing test module of each: a test
module the task does not need leaves it in one call,
`bash "$DRV" spec footprint drop --feature-dir "$feature_dir" --file <test module> --reason "<why>"`,
which is refused while the file it tests changes.

An intent gap is a choice the user would notice in the result that the code cannot
settle; everything else you decide and record
(`bash "${CLAUDE_SKILL_DIR}/../../lib/decisions.sh" add "$feature_dir" spec "<q>" "<a>" "<why>"`).
Gaps are one list, asked once (one `AskUserQuestion` round attended; the recommended
answer into the same record autonomous). You never escalate: a gate does, from
evidence. No score, no transcript, no pruning pass: the shape is under 60 lines.

## 4. Return

Return to the cycle; never run the exit yourself. `next --returned-from spec` runs the
two spec lints and, on the short route, enters ONESHOT in this same session.
