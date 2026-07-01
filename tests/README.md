# loop-spec test matrix

## Automated suites

Run from repo root:

```bash
bash tests/run-all.sh
```

This runs every non-interactive suite: the agent/manifest validators, the hook
tests, the `lib/` unit tests, and (when a node runtime is available) the workflow
syntax checks in `tests/workflows/smoke.sh`. It needs only bash, git, jq, python3,
and (for the workflow checks) node. It does NOT require the Claude CLI.

There is no scripted end-to-end cycle test: driving a full `loop-spec:cycle`
headless against the installed plugin proved unreliable (it exercises a cached
plugin snapshot and the interactive AskUserQuestion path). End-to-end coverage is
the manual matrix below, run against a live Claude Code session.

## Manual end-to-end matrix

Run a subset before each tag (against a live Claude Code session with the plugin
installed). Full grid quarterly.

| # | Feature | Exec Style | Status |
|---|---------|------------|--------|
| 1 | trivial 1-task | auto | not run |
| 2 | trivial 1-task | step | not run |
| 3 | trivial 1-task | interactive | not run |
| 4 | trivial 1-task | review-only | not run |
| 5 | medium 5-task | auto | not run |
| 6 | medium 5-task | step | not run |
| 7 | medium 5-task | interactive | not run |
| 8 | medium 5-task | review-only | not run |
| 9 | complex 10-task | auto | not run |
| 10 | complex 10-task | step | not run |
| 11 | complex 10-task | interactive | not run |
| 12 | complex 10-task | review-only | not run |

Total: 12 cells (3 feature sizes x 4 execution styles; single-tier operation).

Additional scenario rows (run alongside the grid):

| # | Scenario | How | Status |
|---|----------|-----|--------|
| S1 | spec-file ingest | `/loop-spec:cycle path/to/spec.md` with a pre-authored spec (also headless: `LOOP_SPEC_SPEC_FILE=path`). Confirm: NO interview questions; SPEC.md preserves the draft's requirements verbatim; `spec-draft.md` exists in the feature dir; ambiguity gate scored on the draft. | not run |
| S2 | implicit-team harness (CC >= 2.1.178) | Any trivial cell with `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` on a modern CC. Confirm: `runtime.json.teamsMode == "implicit"`; NO `TeamCreate`/`TeamDelete` calls appear; teammates spawn via `Agent({name})` and rework rides `SendMessage`. | not run |
| S3 | explicit-team harness (CC < 2.1.178) | Same as S2 on a legacy CC. Confirm `teamsMode == "explicit"` and per-phase `TeamCreate`/`TeamDelete`. | not run |
| S4 | iterate budget ship | Force a persistent gap (spec asks for X+Y, sabotage Y) with `LOOP_SPEC_PHASE_TIMEOUT_MINS` low or a shrunken maxIterations via manual feature.json edit. Confirm: confirmation pass runs once; unresolved gaps land in `warnings[]` prefixed `iterate-budget-spent:` and in BACKLOG.md; cycle completion prints `## Shipped with warnings`. | not run |

For each cell, drive `loop-spec:cycle` in `LOOP_SPEC_NON_INTERACTIVE=1` mode
(set `LOOP_SPEC_ANSWER_STYLE`, `LOOP_SPEC_ANSWER_TITLE`, or `LOOP_SPEC_SPEC_FILE`
for the spec-file scenario)
and confirm SPEC.md / PLAN.md / VERIFICATION.md are produced, `feature.json`
`currentPhase == "completed"`, and the feature branch carries the expected commits.

### Pre-tag minimum

- One trivial + auto cell.
- Plus 3 hand-picked cells from rows 5-12 covering: parallel waves, AUTO self-heal
  triggered, STEP execution.
- Plus S1 (spec-file ingest) and whichever of S2/S3 matches the local CC version.

### Quarterly

Run all 12 cells. Track failures in the CHANGELOG of the next release.

## Fixtures

`tests/fixtures/` holds inputs for the automated suites (e.g. probe transcripts,
sample agent definitions). To add a fixture for a new manual end-to-end cell,
create `tests/fixtures/{name}/` with a `Makefile` exposing `test`, `lint`, and
`typecheck` targets, plus a short `README.md` describing its purpose.
