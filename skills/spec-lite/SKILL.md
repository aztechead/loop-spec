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
# .entry.read[] (spec-draft.md, a prior transcript)  .entry.flags[]
```

## 1. Scout

Search the code by the ask's vocabulary and the obvious symbols, read the entry points
you find, and follow imports and callers far enough to know where the change lands. As
you read, cite each file the change will touch with the line that shows why; mark a
file the change must not touch (a protected test, a generated file) read-only. The
record is the footprint; you never type it anywhere else:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/footprint.sh" cite "$feature_dir" <path>:<line> "<why>"
bash "${CLAUDE_SKILL_DIR}/../../lib/footprint.sh" cite "$feature_dir" <path>:<line> --read-only "<why>"
```

Cite a footprint file's existing test module too: in the footprint when it changes,
read-only when it must not. A claim about an external system gets its read-only probe
first (`skills/shared/grounding-protocol.md#Probe-before-assert rule`).

## 2. The route, from the record

```bash
sk="$(bash "$DRV" spec skeleton --feature-dir "$feature_dir")"
```

`.route` is `full` (`.reason` says why: four files, a read-only file, a security
signal): invoke `Skill(loop-spec:spec)` and continue there from its step 1; your cites
stand and it extends the scout. `.route` is `oneshot`: the driver wrote the skeleton
at `.spec`, and the rest of SPEC is the list below. The route lengthens only: a fourth
file escalates in ONESHOT.

## 3. Fill the skeleton

The driver is the only writer of the spec; you never open it. Fill its values through
`bash "$DRV" spec fill --feature-dir "$feature_dir"`, one value per call, and read the
`flags` each answer carries (the exit gate's findings so far):

- `--intent "<the ask, one paragraph, in the requester's terms>"`
- `--file <path> --note "<what changes there, with the symbol or line>"` once per
  footprint file
- `--criterion "<check command> exits 0: <what it proves>"` once per observable
  outcome, the command exactly as ONESHOT will run it
- `--grounding "<file:line - the fact it shows>"` per grounding row

A cited file the change will not touch leaves the footprint through
`bash "$DRV" spec footprint drop --feature-dir "$feature_dir" --file <path> --reason "<why>"`;
a test module of a footprint file cannot leave it.

An intent gap is a choice the user would notice in the result that the code cannot
settle; everything else you decide and record
(`bash "${CLAUDE_SKILL_DIR}/../../lib/decisions.sh" add "$feature_dir" spec "<q>" "<a>" "<why>"`).
Gaps are one list, asked once (one `AskUserQuestion` round attended; the recommended
answer into the same record autonomous). A gap left open is
`bash "$DRV" spec escalate --feature-dir "$feature_dir" --reason "<the gap>"`: the full
path. No score, no transcript, no pruning pass: the shape is under 60 lines.

## 4. Return

Return to the cycle; never run the exit yourself. `next --returned-from spec` runs the
two spec lints and, on the short route, enters ONESHOT in this same session.
