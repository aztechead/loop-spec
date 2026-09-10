# Implementer contract (four questions) — canonical prompt directive

Include this design gate in every dispatch that produces code.
Use the compact directive below when assembling subagent, team, loop-fleet, or workflow prompts.
For inline work, the lead reads this contract directly.
`tests/implementer-contract-coverage.test.sh` checks that all dispatch paths include it.

## The four questions (design gate — on by default)

Before implementing, and again before DONE, ask of the change:

1. **Can I make it more modular?** Split at the seams the change already exposes; design
   to an interface; one unit, one reason to change (`skills/shared/design-for-change.md`).
2. **Can I make it more extensible?** Receive collaborators instead of hard-wiring them;
   leave a seam, not a speculation (`skills/shared/design-for-change.md`).
3. **Is this the least amount of code that makes it happen?** Climb the ladder — YAGNI,
   then DRY: reuse what is already here before writing anything new
   (`skills/shared/laziness-ladder.md`).
4. **Does this hold at production scale?** Name the input whose size or rate the deployment controls.
   Examples include rows, files, events, and concurrent callers.
   Bound memory and work against that input. Avoid loading the whole input when the consumer needs only one part at a time.

A "yes, but not doing it" is fine when the rung says skip — say so in one line in the
report. A question never asked is the failure mode.

## Canonical compact directive (inline this verbatim into dispatch prompts)

> FOUR QUESTIONS (design gate — on by default). Before implementing and again before
> DONE, ask of the change: can I make it more modular? can I make it more extensible? is
> this the least amount of code that makes it happen? does this hold at production scale
> (memory and work bounded against deployment-sized input, not the fixture)? Full
> contract: `skills/shared/implementer-contract.md`.

## The directives that travel with it

Every code-producing dispatch prompt names each of these (read, never paste), with the
probe commands resolved for its rung:

| Directive | Canonical file | Probes before DONE |
|---|---|---|
| SIMPLICITY (ponytail laziness ladder) | `skills/shared/laziness-ladder.md` | `lib/indirection-scan.sh scan`, `lib/duplication-scan.sh scan` |
| DESIGN FOR CHANGE (seams, not speculation) | `skills/shared/design-for-change.md` | — |
| CODE FOR HUMANS (house style over habit) | `skills/shared/human-code.md` | `lib/house-style.sh probe` + `compare`, `lib/comment-tells.sh scan` |
| CODE A HUMAN CAN OPERATE (the failure path) | `skills/shared/human-code.md` | `lib/failure-tells.sh scan` |
| DOCS FOR HUMANS (the markdown is a deliverable too) | `skills/shared/human-docs.md` | `lib/doc-tells.sh scan` |
| WRITING GOOD TESTS | `skills/shared/writing-good-tests.md` | — |
| ENGINEERING DIRECTIVES (simple over clever, idiom, versions from a tool, scale first, small tests) | `skills/shared/engineering-directives.md` | `lib/grounding-lint.sh` (unverified versions) |
| TDD (red then green) | prompt-inline; force string pinned by `tests/tdd-red-green-coverage.test.sh` | — |
| NO NESTED SUBAGENTS | prompt-inline | — |
| EXECUTION DISCIPLINE (evidence over recall) | `skills/shared/execution-discipline.md` | — |
