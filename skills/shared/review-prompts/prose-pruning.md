# Fresh-eyes prose pruning — canonical prompt directive

Single source of truth for the pruning pass over prose artifacts. It asks the one
question the structural and grounding lints do not:

> Which lines of this artifact could be removed without changing what its reader
> would do next?

`lib/artifact-lint.sh` catches malformed content and `lib/grounding-lint.sh` catches
ungrounded content; neither catches **surplus** content. The code side already has this
pass — the over-engineering review in `agents/code-reviewer.md` ("the diff's best outcome
is getting shorter"), pinned into every dispatch by `tests/ponytail-coverage.test.sh`.
This is the same pass pointed at prose.

Ported from [BMAD-METHOD](https://github.com/bmad-code-org/BMAD-METHOD)'s ingest-closing
pruning subagent (v6.10.0), on its stated grounds: *the writer who just heard every line
justified cannot honestly run the pruning test on it.*

## The fresh-eyes contract

You receive ONLY the artifact and the template contract it was written against — never
the authoring conversation, the interview transcript, or the justifications. If you were
given more than that, say so and stop: a pruner who has heard the justifications is the
exact reviewer this pass exists to replace.

## Where this runs

- **SPEC**, on `SPEC.md` after the structural lint passes, before commit
  (`skills/spec/SKILL.md`).
- **PLAN**, on `PLAN.md` after the coverage and grounding gates pass, before commit
  (`skills/plan/SKILL.md`).
- **map-codebase**, on the domain documents when `lib/map-audit.sh budget` reports
  `over-budget` — the budget probe says the map must shrink; this pass names what
  (`skills/map-codebase/SKILL.md`).

## The pruning tests

Every proposal names exactly one test the lines fail. A line that fails none of these
stays — pruning is not compression, and shorter prose that loses a decision is a defect,
not a cut.

1. **derivable** — restates what the file it cites plainly shows on one read. The map
   mappers are already forbidden to write these; this catches the ones that got through.
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

These are load-bearing for other machinery, whatever they look like to fresh eyes:

- `### Good Enough` acceptance criteria and `## Decisions` entries — coverage gates match
  them verbatim; cutting one is a **scope change**, not a prune. If one genuinely looks
  like surplus, report it under `out-of-scope:` and let the maker escalate.
- `ambiguity_scores` and `trust` frontmatter blocks, and `STALE` banners.
- `EVID-NNN` citations and `ASSUMPTION:` lines — grounding is never surplus.
- Template-required section headings, even when their section is thin.
- `simplicity:` markers and TODO/FIXME/NOTE/HACK/SAFETY markers.

## Output — listing only

You never rewrite. The maker applies or declines each proposal; your job ends at the
list. One line per proposal:

```text
cut: <path>:<start>-<end> fails=<test> -- <one line: what the reader loses (nothing)>
merge: <path>:<lines> into <path>:<lines> fails=duplicate -- <the one statement that remains>
shrink: <path>:<start>-<end> fails=<test> -- <what the shorter form still says>
out-of-scope: <path>:<lines> -- <why this looks surplus but is a scope decision>
```

No severity, no ranking, no rewritten text. When nothing fails any test, output exactly:

`No prunable prose found.`
