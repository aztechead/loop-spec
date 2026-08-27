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

One carve-out, and it is the repo's own convention: a COUPLING between two
files that no runtime exercises — a prompt template that must keep naming the
script it calls, a version declared in four manifests — is pinned by a
`tests/*-coverage.test.sh` grep, because the break it catches is real (one side
edited, the other left behind) and nothing else can catch it. That is a
coupling pin, not a test of the prose. Anything a runtime CAN exercise is
tested by running it.

## TDD

Code-producing tasks MUST write the failing test first (red), then the
minimal implementation (green). Skill/config/docs tasks are excluded.
Omitting a TDD label does not exempt a code-producing task.
Mock only when the real dependency is slow or external.
