# super-spec test matrix

## Automated suites

Run from repo root:

```bash
bash tests/run-all.sh
```

This runs every non-interactive suite: the agent/manifest validators, the hook
tests, the `lib/` unit tests, and (when a node runtime is available) the workflow
syntax checks in `tests/workflows/smoke.sh`. It needs only bash, git, jq, python3,
and (for the workflow checks) node. It does NOT require the Claude CLI.

There is no scripted end-to-end cycle test: driving a full `super-spec:cycle`
headless against the installed plugin proved unreliable (it exercises a cached
plugin snapshot and the interactive AskUserQuestion path). End-to-end coverage is
the manual matrix below, run against a live Claude Code session.

## Manual end-to-end matrix

Run a subset before each tag (against a live Claude Code session with the plugin
installed). Full grid quarterly.

| # | Feature | Tier | Exec Style | Status |
|---|---------|------|------------|--------|
| 1 | trivial 1-task | quality | auto | not run |
| 2 | trivial 1-task | quality | step | not run |
| 3 | trivial 1-task | quality | interactive | not run |
| 4 | trivial 1-task | quality | review-only | not run |
| 5 | trivial 1-task | balanced | auto | not run |
| 6 | trivial 1-task | balanced | step | not run |
| 7 | trivial 1-task | balanced | interactive | not run |
| 8 | trivial 1-task | balanced | review-only | not run |
| 9 | trivial 1-task | quick | auto | not run |
| 10 | trivial 1-task | quick | step | not run |
| 11 | trivial 1-task | quick | interactive | not run |
| 12 | trivial 1-task | quick | review-only | not run |
| 13 | medium 5-task | quality | auto | not run |
| 14 | medium 5-task | quality | step | not run |
| 15 | medium 5-task | quality | interactive | not run |
| 16 | medium 5-task | quality | review-only | not run |
| 17 | medium 5-task | balanced | auto | not run |
| 18 | medium 5-task | balanced | step | not run |
| 19 | medium 5-task | balanced | interactive | not run |
| 20 | medium 5-task | balanced | review-only | not run |
| 21 | medium 5-task | quick | auto | not run |
| 22 | medium 5-task | quick | step | not run |
| 23 | medium 5-task | quick | interactive | not run |
| 24 | medium 5-task | quick | review-only | not run |
| 25 | complex 10-task | quality | auto | not run |
| 26 | complex 10-task | quality | step | not run |
| 27 | complex 10-task | quality | interactive | not run |
| 28 | complex 10-task | quality | review-only | not run |
| 29 | complex 10-task | balanced | auto | not run |
| 30 | complex 10-task | balanced | step | not run |
| 31 | complex 10-task | balanced | interactive | not run |
| 32 | complex 10-task | balanced | review-only | not run |
| 33 | complex 10-task | quick | auto | not run |
| 34 | complex 10-task | quick | step | not run |
| 35 | complex 10-task | quick | interactive | not run |
| 36 | complex 10-task | quick | review-only | not run |

Total: 36 cells (3 feature sizes x 3 tiers x 4 execution styles).

For each cell, drive `super-spec:cycle` in `SUPER_SPEC_NON_INTERACTIVE=1` mode
(set `SUPER_SPEC_ANSWER_TIER`, `SUPER_SPEC_ANSWER_STYLE`, `SUPER_SPEC_ANSWER_TITLE`)
and confirm SPEC.md / PLAN.md / VERIFICATION.md are produced, `feature.json`
`currentPhase == "completed"`, and the feature branch carries the expected commits.

### Pre-tag minimum

- One trivial + quick + auto cell.
- Plus 3 hand-picked cells from rows 13-36 covering: parallel waves, AUTO self-heal
  triggered, STEP execution.

### Quarterly

Run all 36 cells. Track failures in the CHANGELOG of the next release.

## Fixtures

`tests/fixtures/` holds inputs for the automated suites (e.g. probe transcripts,
sample agent definitions). To add a fixture for a new manual end-to-end cell,
create `tests/fixtures/{name}/` with a `Makefile` exposing `test`, `lint`, and
`typecheck` targets, plus a short `README.md` describing its purpose.
