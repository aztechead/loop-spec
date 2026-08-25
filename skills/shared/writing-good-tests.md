# Writing good tests

Canonical test-authoring reference for implementer dispatches. Load this when
writing or changing tests. Superpowers v6.2.0 rebuilt anti-pattern prose as a
positive catalog; loop-spec keeps the two named traps as a gate, not a sermon.

A test exists to catch a specific break.

1. Every test names the break it catches.
2. Every test exercises the real thing.

## Gate (before the test body)

Name the production change that should make this test fail.

- Cannot name one → redesign around an observable behavior.
- "The source text changed" → run the artifact and assert its effects
  (exit code, stdout, a file it wrote). Never `grep` the source of a skill,
  script, or prompt as the only assertion — that is the string-presence trap.
- Only an intentional decision can fail it (a constant, exact wording,
  private structure) → change detector; test the behavior that depends on
  the decision.

Derive the expected value without the code under test. Literals and
hand-checked fixtures. An expectation computed by the code under test
passes no matter what that code does.

Trivial forwarding, constructors, and human prose earn no test. Skills are
tested by the consuming agent's behavior (`CLAUDE.md`: eval evidence), not
by asserting that a markdown file contains a sentence.

## TDD

If the task has testable behavior, write or extend the failing test first
and watch it fail against real code. Mock only when the real dependency is
slow or external.
