# GDD — Verification

**Feature:** `gdd` · **Branch:** `feat/gdd` · **Base:** `836ef34`

Records the VERIFY gates run against the delivered change, including the ones that
did not pass. The first implementation of this spec passed 154 suites with its PLAN
critique gate disabled and its ITERATE convergence loop removed, so a green suite is
recorded here as the weakest evidence, not the headline.

## Repository grounding

- criterion: route conditions receive their declared args, not an empty argv | implementation: lib/graph/run.sh:148 - substitutes {featureDir}/{repoRoot}/{slug}/{node} into each declared arg | integration: tests/lib/graph-run.test.sh:122 - route-exact graph traversal asserts the args reach the probe
- criterion: a probe's first token must equal expects exactly, never as a substring | implementation: lib/graph/run.sh:194 - satisfied is (token == expects) | integration: tests/lib/graph-run.test.sh:122 - reintroducing substring matching flips this suite
- criterion: an unresolved condition never satisfies an edge, expects "none" included | implementation: lib/graph/run.sh:194 - unresolved probes yield no token to compare | integration: tests/lib/graph-run.test.sh:181 - gate-none graph asserts a crashed probe does not admit
- criterion: a node with no satisfied route aborts rather than falling through to a chain edge | implementation: lib/graph/run.sh:635 - raises RouteAbort with per-probe diagnostics, exit 5 | integration: tests/lib/graph-run.test.sh:181 - asserts the abort instead of a chain edge
- criterion: human nodes are skipped when not admitted, so unattended runs do not deadlock | implementation: lib/graph/run.sh:508 - evaluates the node's admit condition on entry | integration: tests/lib/graph-run.test.sh:238 - execStyle auto exits 0 with no pause
- criterion: resume prefers the pause record, then the ledger, then feature.json.currentPhase | implementation: lib/graph/run.sh:11 - documented resolution order, applied before any currentPhase write | integration: tests/lib/graph-run.test.sh:264 - resume starts at the SUCCESSOR of the paused node
- criterion: the spec-approval gate is reachable under step and interactive | implementation: lib/graph/probes/iterate-approval.sh:31 - answers the compound gap-and-style question in one route | integration: tests/lib/graph-probes.test.sh:263 - approval required for a spec gap under both styles
- criterion: a claimant cannot pass by echoing back its own bundle hash | implementation: lib/graph/port-local.sh:127 - re-derives the hash from the live feature.json | integration: tests/e2e/graph-handoff.test.sh:136 - claimant with forged/stale state rejected
- criterion: the cycle hands sequencing to the engine rather than prose | implementation: skills/cycle/SKILL.md:641 - Step 6 drives agent nodes through run.sh --step | integration: tests/graph-conformance.test.sh:1 - residual-prose check fails if a skill re-declares a successor

## Gate run

- `lib/test-tamper-scan.sh 836ef34 .` — rc=0, clean. Fifteen signals resolved: nine real, six from two precision bugs in the scan itself (see below).
- `lib/placeholder-scan.sh 836ef34 .` — rc=0, `placeholder-scan: ok`.
- `lib/plan-adherence.sh docs/loop-spec/features/gdd/PLAN.md` — 25 plan task ids, `gap_message: null`.
- `lib/comment-tells.sh scan` over the new `lib/` sources — `comment-tells: clean`.
- `lib/house-style.sh probe` — `comment_density=moderate (14.0%)`, `indent=spaces:2`, `naming=snake_case`, `line_length=p90:81`; consistent with neighbours.
- `lib/security-signal.sh first <changed files>` — one match, `CHANGELOG.md:216:term=permission`, in prose describing a hook. No security signal in changed code.
- `lib/artifact-lint.sh` (spec, plan, verification), `lib/grounding-lint.sh`, `lib/criteria-coverage.sh`, `lib/decision-coverage.sh` — all ok.
- `lib/verification-gap-scan.sh 836ef34 .` — rc=0, `scanned=28 uncovered=25 unknown=0` across 178 test files. Verdict analysed below.
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

## Verification-gap verdict

`scanned=28 uncovered=25`. That is not 25 gaps. Per the repo's own rule, `covered=no`
is a starting point and never a finding: the scan reports which test files *name* a
symbol, and 21 of the 25 are internal helpers of `lib/graph/run.sh` (`run_condition`,
`resolve_start`, `process_node`, …) that the suite exercises through the engine's CLI
rather than by name.

Classifying by BEHAVIOUR instead of by symbol found exactly one real gap. Every other
newly-wired component carried an assertion — `assert-reads`
(`tests/lib/graph-run.test.sh:364`), `conflict-monitor` (`:395`), `last-result`
(`:433`), `subgraph` (`:462`), `trace` — and **effort carried none**. Nothing held
`lib/graph/run.sh:371`'s raise-never-lower rule in place, which is the whole point of
remediation contract §7. Now covered: a node declared `system1` is raised when the
probe says `system2`, a node declared `system2` is not lowered when the probe says
`system1`, and a fresh-fixture case proves the probe is consulted rather than a blanket
default applied. Mutation-proved by replacing the rule with `final = probe_mode`.

155 green suites did not find that. The gate that had never run was the only thing that did.

## Defects fixed in the repo's own tooling

Both were pre-existing, neither was caused by this change, and both are now fixed with
tests rather than deferred.

1. **`lib/verification-gap-scan.sh` could not run on a large diff.** It exported the
   full diff and test-file list to Python through the *environment*, so a 65-file change
   exceeded `E2BIG` and the gate died with `Argument list too long` — it failed on
   exactly the diffs it is most needed for. Both inputs now go through a temp file. The
   analysis is unchanged and the env form still works for older callers.

2. **`lib/test-tamper-scan.sh` reported six false positives, from two real bugs.**
   - `xit\(` carried no LEFT boundary, so it matched the tail of `e|xit(`. Every
     `sys.exit()`, `os._exit()` and plain `exit()` in a shell or Python test read as a
     skipped test — a false positive for any repo whose tests call `exit()`, not just
     this branch. Fixed with `(^|[^A-Za-z0-9_.])`.
   - The swallowed-exit rule fired on cleanup traps and fixture setup. The signal it
     exists for is a *test command's* exit code being discarded; `trap 'rm -rf "$WORK"'
     EXIT` is correct, and a cleanup that fails must not fail the suite. Housekeeping
     commands are now exempt; anything that runs the thing under test still flags.

   `tests/lib/test-tamper-scan.test.sh` pins both directions with eleven cases: `xit(`,
   `describe.only(`, `@pytest.mark.skip`, `t.Skip(`, a swallowed `run_the_thing || true`
   and a swallowed `pytest tests/ || true` must all still flag; `sys.exit(0)`, a
   conditional `sys.exit`, a cleanup `trap`, a teardown `rm` and a fixture `chmod` must
   be clean. Mutation-proved twice — dropping the `xit` boundary fails the suite, and
   widening the exempt list to cover a real test command fails it too.

   This was done only after the branch's own nine real signals had been fixed on their
   merits, so the gate was never edited to hide a finding.

## Known gaps carried into the PR

The handoff port gap is CLOSED. `examples/foreign-claimant/` is a working consumer: it
lists claimable work, claims a bundle, does what the bundle's brief says, runs the
bundle's verify command, refuses to complete when that fails, and releases the lease in a
`finally`. It reaches the port only through `lib/graph/port.sh` — no direct storage
access — so it exercises the seam rather than the reference adapter's internals.
`tests/e2e/foreign-claimant-app.test.sh` proves it end to end: a separate process with a
scrubbed environment claims the bundle, produces `app.py`, and `GET /` over 127.0.0.1
returns exactly `hello world`.

Building it exposed a real contract defect. `lib/graph/handoff.sh export` carried no
`brief` and no `files`, so a claimant sharing nothing with the originating session could
not know what to build — which is precisely what the port exists to make possible. No
test caught it because every test supplied the work out of band. Fixed with
`--brief`/`--files`, wired at the Rung 5 call site so it is reachable from production
rather than merely available.

It remains a REFERENCE consumer, not a supported product surface, and the port still has
no consumer inside the cycle's own default path: `foreign` stays opt-in behind
`LOOP_SPEC_FOREIGN_CLAIMANTS=1`. The gap moved from unusable-and-unproven to
proven-and-opt-in, not to shipped-by-default.

Remaining gaps:

- `feature.json` stays at schema v7; pre-3.0 resume works by falling back to
  `currentPhase` rather than by a migration.
- The bounded delivery-retry semantics for `nextPhase=deliver` were chosen without a
  critique pass, and reverse a deliberate decision by the agent that wrote the probe.
- SPEC.md §10's "declared, therefore self-correcting" argument remains weaker than it
  reads; the validator now closes the two drift surfaces that had already drifted.
