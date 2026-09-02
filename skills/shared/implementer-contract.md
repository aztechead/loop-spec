# Implementer contract (four questions) — canonical prompt directive

Single source of truth for the design gate that every **code-producing dispatch** carries,
and the index of the engineering directives that travel with it. Enforced by
`tests/implementer-contract-coverage.test.sh`, mirroring
`tests/execution-discipline-coverage.test.sh`.

## Why this exists

The same engineering contract rides in every implementer prompt — the subagent rung's two
prompt templates, the team prompt, the implementer agent charter, the loop-fleet compiler
(`lib/plan-to-loop.sh`), and the workflow engine (`lib/workflows/execute-dag.js`) — because
a dispatched executor sees only its prompt; a pointer it will never follow is not a
contract. This file is the one place the assembly is defined, so a new rung or compiler
copies from here instead of from whichever prompt it happened to open, and the inline rung
(lead as implementer) binds it by cite.

## The four questions (design gate — on by default)

Before implementing, and again before DONE, ask of the change:

1. **Can I make it more modular?** Split at the seams the change already exposes; design
   to an interface; one unit, one reason to change (`skills/shared/design-for-change.md`).
2. **Can I make it more extensible?** Receive collaborators instead of hard-wiring them;
   leave a seam, not a speculation (`skills/shared/design-for-change.md`).
3. **Is this the least amount of code that makes it happen?** Climb the ladder — YAGNI,
   then DRY: reuse what is already here before writing anything new
   (`skills/shared/laziness-ladder.md`).
4. **Does this hold at production scale?** The fixture is small; the deployed input is
   not. Name the input whose size or rate the deployment controls (rows, files, events,
   concurrent callers) and keep memory and work bounded against it. A path that
   materializes or accumulates the whole input when the consumer needs a piece at a time
   survives the test and dies in production — that is not done.

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
