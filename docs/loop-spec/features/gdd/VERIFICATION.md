# GDD — Verification

**Feature:** `gdd` · **Branch:** `feat/gdd` · **Base:** `836ef34`

Records the VERIFY gates run against the delivered change, including the ones that
did not pass. The first implementation of this spec passed 154 suites with its PLAN
critique gate disabled and its ITERATE convergence loop removed, so a green suite is
recorded here as the weakest evidence, not the headline.

## Repository grounding

- `lib/test-tamper-scan.sh 836ef34 .` — **rc=1**, 6 signals remaining (from 15). See "Accepted findings".
- `lib/placeholder-scan.sh 836ef34 .` — rc=0, `placeholder-scan: ok`.
- `lib/plan-adherence.sh docs/loop-spec/features/gdd/PLAN.md` — 25 plan task ids, `gap_message: null`.
- `lib/comment-tells.sh scan` over `lib/graph/*.sh`, `lib/graph/probes/*.sh`, `lib/effort-probe.sh`, `lib/conflict-monitor.sh` — `comment-tells: clean`.
- `lib/house-style.sh probe` — `comment_density=moderate (14.0%)`, `indent=spaces:2`, `naming=snake_case`, `line_length=p90:81`; consistent with neighbours.
- `lib/security-signal.sh first <changed files>` — one match, `CHANGELOG.md:216:term=permission`, in prose describing a hook. No security signal in changed code.
- `lib/artifact-lint.sh` (spec, plan), `lib/grounding-lint.sh`, `lib/criteria-coverage.sh`, `lib/decision-coverage.sh` — all ok.
- `lib/verification-gap-scan.sh 836ef34 .` — **did not run**. See "Defects found in the repo's own tooling".
- `bash tests/run-all.sh` — 155 suites passed, 0 failed.

## Acceptance criteria

Each of the four runtime failures a critique reproduced against the shipped engine,
re-checked against a real git-backed feature rather than a synthetic fixture.

| # | Criterion | Method | Result |
|---|---|---|---|
| 1 | ITERATE routes by gap class instead of chaining unconditionally to DELIVER | probe matrix over 4 gap classes x 4 execution styles | pass — `execute`/`plan` route to their phase, `spec` to `discuss`, `none` to `deliver` |
| 2 | `plan.critique` is visited when a security signal is present | traversal against a repo with a security-relevant changed file | pass — `route:plan.critique.gate->plan.critique`; bypassed when the signal is absent |
| 3 | An `auto` run traverses without pausing | full dry-run traversal, `execStyle: auto` | pass — `spec` through `completed`, rc=0 |
| 4 | A pre-3.0 feature resumes where its committed state says | feature at `currentPhase: verify`, empty checkpoint ledger | pass — resumes at `verify`, `currentPhase` unchanged |
| 5 | Route conditions fail closed | all-probes-fail node | pass — exit 5, no fallthrough to a `chain` edge |
| 6 | Spec-approval gate reachable under `step`/`interactive` | route ordering assertion + probe matrix | pass — mutation-proved by reordering the routes |
| 7 | Delivery handles all three `nextPhase` values | probe over `execute`/`completed`/`deliver` | pass — bounded retry declared for `deliver` |

Every fix carries a mutation proof: the defect is re-introduced, a named test is shown
to fail, and the file is restored. Mutations proved: substring route matching, the
`expects: "none"` fail-open, the staleness check, bundle-id uniqueness, `expects`
answer-set membership, the per-(from,to) loop carve-out, the human-gate admit token,
and the approval-route ordering.

## Accepted findings

`lib/test-tamper-scan.sh` exits 1 with 6 remaining signals. Nine were real and fixed by
recording exit codes instead of discarding them. The remaining six are false positives of
a word-matching heuristic, accepted and listed here rather than suppressed:

| Signal | Why it is not tampering |
|---|---|
| `graph-conformance.test.sh: sys.exit(0)` / `sys.exit(1)` | The result of an inline Python reachability check, not a test skip |
| `graph-schema.test.sh: sys.exit(0 if bad else 1)` | Same — a Python helper returning its verdict |
| `graph-port-contract.test.sh: chmod +x ... \|\| true` | Fixture setup, not a test result |
| `graph-run.test.sh: trap '... \|\| true' EXIT` | Cleanup trap; a failing cleanup must not fail the suite |
| `graph-run.test.sh: rm -rf ... \|\| true` | Teardown of scratch dirs |

**The scan was deliberately not modified to make this branch pass.** Editing the gate
that exists to catch test-weakening, inside the change it flagged, is the behaviour the
gate is for. The precision gap is recorded below as a follow-up instead.

## Defects found in the repo's own tooling

1. **`lib/verification-gap-scan.sh` cannot run on a large diff.** It exports the full diff
   and test-file list to Python through the environment (`DIFF_TEXT=... python3 -`), so a
   65-file change exceeds `E2BIG` and the gate dies with
   `/usr/local/bin/python3: Argument list too long`. It works on a one-commit diff. The
   gate is advisory in this release, so nothing was blocked — but it fails precisely on
   the large changes it is most needed for, and it fails loudly rather than silently only
   because the caller checks. Fix: pass the diff on stdin or via a temp file.

2. **`lib/test-tamper-scan.sh` flags cleanup traps, fixture setup, and inline Python
   `sys.exit()` as tampering.** Six false positives on this change. Fix: exclude `trap`
   lines, `chmod`/`rm` teardown, and `sys.exit` inside a heredoc from the swallowed-exit
   and skip heuristics.

Both are pre-existing and neither is caused by this change.

## Known gaps carried into the PR

- The handoff port has no production consumer; `execute-rung.sh` can select the `foreign`
  rung and the skill documents it, but nothing in the shipped cycle claims a bundle.
- `feature.json` stays at schema v7; pre-3.0 resume works by falling back to
  `currentPhase` rather than by a migration.
- The bounded delivery-retry semantics for `nextPhase=deliver` were chosen without a
  critique pass, and reverse a deliberate decision by the agent that wrote the probe.
- SPEC.md §10's "declared, therefore self-correcting" argument remains weaker than it
  reads; the validator now closes the two drift surfaces that had already drifted.
</content>
