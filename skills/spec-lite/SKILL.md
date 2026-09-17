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
repo_root="$(git rev-parse --show-toplevel)"
pb="$(bash "$DRV" phase-begin spec --feature-dir "$feature_dir")"
# .entry.fields (slug, feature_title, execStyle, greenfield, autonomous, models.routeJudge)
# .entry.read[] (spec-draft.md, prior decisions)  .entry.flags[]
```

## 1. Scout

Search the code using the request's terms and relevant symbols. Read entry points and
follow imports and callers until you can locate the change. Cite each affected file
with a line that shows why it must change: the citations are the footprint.

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

`j.action` `in-harness`: before the skeleton, dispatch `subagent_type:
"loop-spec:route-judge"` ONCE (model `models.routeJudge`; `task_path: .task`,
`footprint_path: .footprint`, `repo_root`, no `verdict_path`), save its final message
to a file, run `spec judge ... --verdict <file>`; `.stored` false means the skeleton
routes on the deterministic rules. `sk.route` is `full` (`.reason` says why): read the
snapshot path in `.fullSpec` and continue from its step 1; your cites stand. `oneshot`:
the driver wrote the skeleton at `.spec`; the rest of SPEC is the list below. The route
lengthens only: a reviewer BLOCK (one on scope included) or a held exit lengthens it.

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
- `--grounding "<file:line - the fact it shows>"` per grounding row

A test module the task does not need leaves the footprint in one call, refused while the
file it tests changes: `bash "$DRV" spec footprint drop --feature-dir "$feature_dir" --file <test module> --reason "<why>"`.

An intent gap is a choice the user would notice in the result that the code cannot
settle; everything else you decide and record
(`bash "${LOOP_SPEC_SKILL_DIR}/../../lib/decisions.sh" add "$feature_dir" spec "<q>" "<a>" "<why>"`).
Gaps are one list, asked once (one `AskUserQuestion` round attended; the recommended
answer autonomous). You never escalate: a gate does, from evidence. No score, no
transcript, no pruning pass: the shape is under 60 lines.

## 4. Return

Return to the cycle; never run the exit yourself. `next --returned-from spec` runs the
two spec lints and, on the short route, enters ONESHOT in this same session.
