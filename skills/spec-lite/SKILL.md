---
name: spec-lite
description: "Inspect the requested change and record its footprint. Fill the driver's short spec or continue to the full SPEC instructions. Internal cycle entry for NEXT phase=spec. Start at /loop-spec:cycle."
allowed-tools: Bash Read Glob Grep Skill AskUserQuestion
---

# SPEC, the candidate path

You are the SPEC lead. `feature_dir` is `.loop-spec/features/{slug}`; use the entry
packet only and relay any prior FLAG:

```bash
DRV="${LOOP_SPEC_SKILL_DIR}/../../lib/cycle-driver.sh"
repo_root="$(git rev-parse --show-toplevel)"
pb="$(bash "$DRV" phase-begin spec --feature-dir "$feature_dir")"
# .entry.fields (slug, feature_title, execStyle, greenfield, autonomous, models.routeJudge)
# .entry.read[] (spec-draft.md, prior decisions)  .entry.flags[]
```

## 1. Scout

Trace the request through entry points, imports, and callers. Cite each affected file
with the line and reason that make it part of the footprint.

Only files marked `protected:` in the invocation are read-only; for other files,
`--read-only` records an ordinary citation. Each cited source file's test module is
in the footprint automatically:

```bash
bash "${LOOP_SPEC_SKILL_DIR}/../../lib/footprint.sh" cite "$feature_dir" <path>:<line> "<why>"
bash "${LOOP_SPEC_SKILL_DIR}/../../lib/footprint.sh" cite "$feature_dir" <path>:<line> --read-only "<why>"
```

A claim about an external system gets its read-only probe first
(`skills/shared/grounding-protocol.md#Probe-before-assert rule`).

## 2. The judge, then the route

```bash
j="$(bash "$DRV" spec judge --feature-dir "$feature_dir")"
sk="$(bash "$DRV" spec skeleton --feature-dir "$feature_dir")"
```

1. `j.action` is `in-harness`: dispatch `subagent_type: "loop-spec:route-judge"` ONCE
   (model `models.routeJudge`; `task_path: .task`, `footprint_path: .footprint`,
   `repo_root`, no `verdict_path`), save its final message to a file, and run
   `spec judge ... --verdict <file>` before the skeleton. `.stored` false: say so in one
   line; the skeleton then routes on the deterministic rules.
2. `sk.route` is `full`: read the snapshot at `.fullSpec` and continue from its step 1
   (`.reason` says why; your cites stand). `oneshot`: the skeleton at `.spec` is the spec.
3. The route lengthens only: a reviewer BLOCK (one on scope included) or a held exit.

## 3. Fill the skeleton

Only the driver writes the spec; never open it for editing. Fill it through
`bash "$DRV" spec fill --feature-dir "$feature_dir" --json -`. Send `{intent, notes: {path: text}, criteria: [text], grounding: [text]}` on stdin, or
one value per call with the flags below. Read the returned `flags` for exit-gate findings:

- `--intent "<the ask, one paragraph, in the requester's terms>"`
- `--file <path> --note "<what changes there, with the symbol or line>"` once per
  footprint file
- `--command "<shell>" --expect "<what exit 0 proves>"` once per observable outcome:
  the driver writes the line and runs that command at the boundary; you never compose
  the sentence (`--row GE-001` replaces a criterion)
- `--grounding "EVID-NNN: <fact>"` per external fact after recording it in the evidence
  ledger. Local `file:line` citations stay in notes/footprints; use
  `ASSUMPTION: <claim> | verify: <command>` without external evidence, or `none` when no
  external fact is load-bearing.
A test module the task does not need leaves the footprint in one call, refused while the
file it tests changes: `bash "$DRV" spec footprint drop --feature-dir "$feature_dir" --file <test module> --reason "<why>"`.

An intent gap is a choice the user would notice in the result that the code cannot settle;
everything else you decide and record (`bash "${LOOP_SPEC_SKILL_DIR}/../../lib/decisions.sh" add "$feature_dir" spec "<q>" "<a>" "<why>"`).
Gaps are one list, asked once (one `AskUserQuestion` round attended; the recommended
answer autonomous). You never escalate: a gate does, from evidence. No score, no
transcript, no pruning pass: the shape is under 60 lines.

## 4. Return

Return to the cycle; never run the exit yourself. `next --returned-from spec` runs the
two spec lints and, on the short route, enters ONESHOT in this same session.
