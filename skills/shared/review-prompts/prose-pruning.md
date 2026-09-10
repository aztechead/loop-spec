# Independent prose review

Use this contract to find artifact text that adds no useful information:

> Which lines of this artifact could be removed without changing what its reader
> would do next?

`lib/artifact-lint.sh` checks structure. `lib/grounding-lint.sh` checks supporting evidence.
This review checks for unnecessary prose, like the code review in `agents/code-reviewer.md` checks for unnecessary code.

## The fresh-eyes contract

Read only the artifact and its template contract.
Do not read the authoring conversation, interview transcript, or reasons for the wording.
If you received that extra context, report it and stop. This review requires an independent reader.

## Where this runs

- **SPEC**, on `SPEC.md` after the structural lint passes, before commit
  (`skills/spec/SKILL.md`).
- **PLAN**, on `PLAN.md` after the coverage and grounding gates pass, before commit,
  only when `lib/plan-render.sh prose-lines` counts 120 or more prose lines; the rendered
  task sections are out of scope
  (`skills/plan/SKILL.md`).

## The pruning tests

For each proposal, name exactly one failed test below.
Keep lines that fail none of these tests. Preserve every decision.

1. **derivable** — restates what the file it cites plainly shows on one read.
2. **duplicate** — the same fact or decision already stated elsewhere in this artifact.
   Name both locations.
3. **speculative** — serves a requirement nothing in the artifact names: hypothetical
   future needs, options considered and not chosen (unless recorded as a decision),
   capabilities nothing depends on.
4. **narrative** — records the authoring process or its history rather than the current
   state: "after discussion we settled on", "this section was rewritten because".
5. **over-template** — content the template contract does not ask this artifact to carry
   and no later phase reads.

## Never propose — the carve-outs

Do not propose changes to these items:

- `### Good Enough` acceptance criteria and `## Decisions` entries — coverage gates match
  them verbatim; cutting one is a **scope change**, not a prune. If one genuinely looks
  like surplus, report it under `out-of-scope:` and let the maker escalate.
- `unresolved_questions` and `trust` frontmatter blocks, and `STALE` banners.
- `EVID-NNN` citations and `ASSUMPTION:` lines — grounding is never surplus.
- Template-required section headings, even when their section is thin.
- `simplicity:` markers and TODO/FIXME/NOTE/HACK/SAFETY markers.

## Output — listing only

You never rewrite. The author accepts or rejects each proposal.
Return one line per proposal:

```text
cut: <path>:<start>-<end> fails=<test> -- <one line: what the reader loses (nothing)>
merge: <path>:<lines> into <path>:<lines> fails=duplicate -- <the one statement that remains>
shrink: <path>:<start>-<end> fails=<test> -- <what the shorter form still says>
out-of-scope: <path>:<lines> -- <why this looks surplus but is a scope decision>
```

No severity, no ranking, no rewritten text. When nothing fails any test, output exactly:

`No prunable prose found.`
