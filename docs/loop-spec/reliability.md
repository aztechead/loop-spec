# Reliability of specs, loops, and graph recovery

For maintainers changing the workflow: this explains the reliability decisions behind
the 6.0 release and the evidence that can falsify them. Source review cutoff: September
4, 2026. These are engineering recommendations drawn from primary sources, not a claim
that the three development approaches share a formal industry standard.

## Specs are testable contracts

[GitHub Spec Kit's analysis command](https://github.com/github/spec-kit/blob/main/templates/commands/analyze.md)
checks consistency and coverage across requirements, plans, and tasks. Loop-spec already
has task criteria, decision coverage, and repository grounding. The gap was at convergence:
a missing specification or a result marked PENDING could still clear the mechanical floor.

`lib/converged-floor.sh` now requires a readable Good Enough contract, grounding for each
GE identifier, and exactly one PASS acceptance result per criterion. Acceptance rows use
the criterion's number or GE identifier in the `#` column; the header names the status
column (`Status` or `Result`), and the cell begins with PASS, FAIL, or N/A. VERIFY's exit
runs the same parser with `--shape`, so a table the floor cannot read is a REDO in VERIFY,
never a veto of a converged verdict that rewinds through an empty EXECUTE. A grounding row establishes where the behavior
lives; it does not replace the acceptance result. Semantic agreement between a requirement
and its implementation still needs the goal judge and reviewer.

`lib/phase-exit.sh` enforces the floor before accepting a converged ITERATE verdict,
so omitting a prose instruction cannot skip this check.

Evidence: `tests/lib/converged-floor.test.sh` exercises missing contracts, missing results,
PENDING/SKIP/UNKNOWN outcomes as failures, the verifier's four-column table, and `--shape`;
`tests/lib/phase-exit.test.sh` pins the VERIFY-exit flag.

## Loops need outcome evidence and durable handoffs

[Anthropic's evaluation guidance](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents)
distinguishes outcomes from an agent's trajectory and recommends inspecting evaluation
failures. Its [March 2026 harness experiments](https://www.anthropic.com/engineering/harness-design-long-running-apps)
also stress evaluating which orchestration components improve results before retaining
their complexity. Loop-spec already separates implementation from judging and bounds
iteration. This release strengthens the state and tests those mechanisms depend on.

Feature writes serialize field updates and preserve a continuously readable current
file. Resume carries the selected slug rather than choosing the first directory in a
shared checkout. The complete offline test command includes integration and harness
suites; selecting a suite cannot silently omit it.

Evidence: `tests/lib/feature-write.test.sh`, `tests/lib/cycle-driver.test.sh`, and
`tests/run-all.test.sh`. Concurrent callers serialize per feature; state processing is
linear in the state document's size. Full snapshot replacement is still an overwrite,
so concurrent callers use field operations.

## Graphs distinguish admission from completion

[LangGraph persistence](https://docs.langchain.com/oss/python/langgraph/persistence) and
its [functional API guidance](https://docs.langchain.com/oss/python/langgraph/functional-api)
separate persisted results from replayed work and call for idempotent side effects.
Applying that principle here requires a started/completed distinction in the existing
checkpoint ledger, without adopting another graph runtime.

An agent dispatch remains started until its caller acknowledges the returned node.
Resuming without an acknowledgement retries it. Function and gate failures stop the graph,
and checkpoint publication failures prevent further dispatch. The graph does not promise
exactly-once external effects: node implementations must observe existing results or
use idempotent operations when replaying.

Retry counts travel with checkpoints. Each process resumes the consumed budget, and
route edges obey the matching loop ceiling. Repeated process launches cannot replenish
the retry allowance.

Evidence: `tests/lib/graph-recovery.test.sh` checks interrupted dispatch, wrong completion
identity, failed-gate replay, and unavailable checkpoint storage. The larger graph suite
checks routing and the shipped cycle with explicit acknowledgements.

## Upgrade from 5.x

Ordinary cycle callers keep using `next --returned-from PHASE`; the driver carries the
acknowledgement. Direct graph callers must pass `--completed-node ID` after a successful
agent return. See [the graph contract](graph-remediation-contract.md). Resume callers
must pass `--slug` when several feature directories share their selected root. Legacy
checkpoint records retain their completed meaning.

`bash tests/run-all.sh` is now the complete offline gate. The shorter check remains
available as `RUN_ALL_PROFILE=unit bash tests/run-all.sh`. Offline checks establish
mechanical behavior; they do not measure live model task success or replace the manual
harness matrix in [the test guide](../../tests/README.md).

## Upgrade from 6.x: traceable requirements

7.0 delivered [the roadmap's 7.0 stage](7.x-roadmap.md#70-connect-requirements-tasks-and-evidence):
stable requirement identity and revision (`lib/requirements.py`,
[requirements-format.md](requirements-format.md)), a driver-owned publication
transaction every producer route stages through (`lib/artifact_publication.py`),
declared execution-input identity (`lib/execution_inputs.py`), bounded driver-owned
observation records that VERIFY and ITERATE cross-check before accepting PASS
(`lib/execution_observation.py`, `lib/converged-floor.sh`), the same protected-path
guard on all four harnesses (`bash lib/harness.sh protected-path`,
`skills/shared/claude-harness.md` "Protected publication paths"), and a deterministic,
read-only migration preview plus recoverable apply/resume/rollback for an incomplete
pre-7 cycle (`lib/requirements_migrate.py`, [requirements-migration.md](requirements-migration.md)).
Evidence: `tests/lib/requirements.test.sh`, `tests/lib/artifact-publication.test.sh`,
`tests/lib/execution-observation.test.sh`, `tests/lib/requirements-migrate.test.sh`, and
`tests/release-7-0-coverage.test.sh` (the cross-file wiring). The roadmap's 7.1
(capability lifecycle) and 7.2 (selective evidence reuse) stages remain open; this
release does not implement either.
