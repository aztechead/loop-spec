# Task 004 work-in-progress handoff

For the lead and next implementer resuming publication participant integration.

Status: STOPPED INCOMPLETE at the user's usage-limit handoff request. Do not mark this task done or integrate it as passing. No commit, branch change, worktree creation, push, live eval, or actual cycle-state edit was performed by this agent. Parent owns checkpointing.

## Agent-owned source changes

- lib/feature_write.py: factors existing state transaction into write_operation(directory, operation, value, keys=(), token=None, registry=None). Gate-controller authorization applies to Python callers too. begin_operation(directory, token=None, registry=None, bootstrap=True) validates original ingress or captures before work; incomplete schema7 bootstraps recorded legacy via requirements.bootstrap_state, completed unrecorded history is unchanged. participant_registry handles relocated canonical tasks pointers. CLI adds ingress/ingress-read; existing CLI operations remain.
- lib/feature-write.sh: remains executable launcher and can be sourced for loop_spec_publication_begin, loop_spec_feature_write, loop_spec_publication_run, loop_spec_publication_lib. Input token file is LOOP_SPEC_PUBLICATION_TOKEN; accepted refresh destination is LOOP_SPEC_PUBLICATION_TOKEN_OUTPUT. Each shell frame makes a private token; child output is explicitly adopted. These helpers are intermediate, not fully audited or fully wired.
- lib/execute_remediation.py: initialized state captures before reader/work, stages unique task candidate and publishes tasks plus queue/receipt acknowledgment together. It accepts token and token_output parameters; CLI consumes/returns token environment. Unrecorded non-schema7 fixtures retain existing behavior.
- lib/graph/driver.py: fill_requirement separates stable IDs and scenario_checks; entries are GE-ID/SC-ID -> {command,executionInputs}. spec_fill receives persisted contract, replaces by named ID, rejects positional aliases, and avoids whole-artifact compaction for v1. cmd_spec wraps author_spec with a staging candidate and ledger reconciliation under publication. It accepts --token or input env and emits accepted refresh to output env. Approval uses trusted token writer when available. This is incomplete route integration.
- Initial shell ingress/child transfer wiring: lib/graph/state.sh, lib/graph/gate.sh, lib/iterate-judged.sh, lib/execute-step.sh, lib/verify-gate.sh, lib/verify-prepare.sh, lib/execute-prepare.sh, lib/feature-init.sh (activate), lib/checkpoint-pr.sh, lib/revise-state.sh (existing state).
- New tests/lib/publication-callers.test.sh currently contains focused executable seam, remediation, stable-ID fill, and shell transfer cases. It DOES NOT yet enumerate every writer and is NOT registered in tests/run-all.sh.

Parent separately owns lib/artifact_publication.py, lib/artifact_sink.py, lib/artifact-sink.sh and their publication/sink tests, plus PLAN/SPEC scope edits. See task-004-parent-report.md for parent evidence. No agent changes were made to those source files.

## Confirmed failures at stop

1. Execute preparation currently fails on macOS /var -> /private/var aliases. Parent ingress resolves feature_dir to /private/var; participant_registry returns the validated local tasks path. execute-prepare still passes persisted /var tasks path to execute_remediation, whose explicit registry is rejected with `absolute artifact path escapes the feature roots`. The focused repro /tmp/task004-prepare-repro.sh confirms this. Suggested next repair: obtain the tasks target from the already validated original token inputs.tasks.path / trusted participant registry, rather than resolving arbitrary caller paths or recapturing at egress. This repair was NOT applied after the stop request.
2. /tmp/task004-execute-prepare.log: Results: 49 passed, 28 failed from the outer caller wiring revision. The earlier pre-wiring execute-prepare run passed 77 cases; that older success does not validate current source.
3. An initial cycle-driver run failed 80 passed/180 failed because participant_registry tried reading feature.json during its first creation. Fixed before rerun by allowing an absent file. The rerun completed: cycle-driver: 254 passed, 7 failed. Output /tmp/task004-cycle-driver.log. Failures: Claude worktree creation, control checkout stays main, next inside worktree, answered phase record, next from project root, Claude resume worktree, and gitfile reason text. The suite ran under required LOOP_SPEC_WORKTREES=0; whether these expectations need fixture-local override requires evidence, not a baseline exemption. No passing claim.

## Test evidence

All runs used LOOP_SPEC_HARNESS=codex and LOOP_SPEC_WORKTREES=0.

- First TDD red: AttributeError: module feature_write has no attribute write_operation. Green then proved valid relocated write, stale rejection with unchanged state, explicit own refresh, and protected gate ownership.
- Remediation TDD red: register() got unexpected keyword argument token. Green proved one transaction for tasks and queue acknowledgment and an injected reader generation change refusing publication without overwriting tasks/acknowledging queue.
- Stable-ID fill TDD red: spec_fill() got unexpected keyword argument contract. Green proved reordered GE-009/GE-003 retains identities, replaces GE-009, rejects numeric alias, and preserves the pre-criteria intent bytes. The fixture deliberately exercises the producer function; its ordinary SPEC lint flags remain visible, not claimed as a valid full SPEC fixture.
- Shell transport focused case passed: parent own write + child accepted write produces generation 2; original incoming token remains unchanged; replaying it fails without state mutation.
- Latest completed feature-write suite: 33 passed, 0 failed plus four Python concurrency cases OK. This preceded the final shell caller edits.
- Latest completed graph-state suite: 21 passed, 0 failed.
- Focused publication-callers last completed run passed all five current groups before the last caller wiring edits; no full completeness claim.
- Exact task Verify has NOT been completed. No full repository suite was run.

## Remaining acceptance work

- Complete real producer/callsite inventory and executable valid/stale tests per writer, with completeness enforcement and run-all registration.
- Engine and driver operation ingress across graph transitions, subprocesses, authoring, delivery, terminal result, and phase acknowledgment; no fresh egress token to legitimize old work.
- Phase-entry unique actor identity/staging paths and phase-exit shared transaction. Existing phase-entry shared sidecar is still unchanged and unsafe for the new contract.
- Quality-loop per-feature staged sidecar and reviewer ingress propagation; its skill and source are not yet changed by this agent.
- Deliver/cycle-result/cycle-preflight and all remaining producer routes; source files not mentioned in current changes are not integrated.
- Stable-ID new full/spec-lite/oneshot template creation, ingest, batch allocation/ledger updates, route escalation, all remaining positional enumerations, approved Goals/Boundaries/specApproval invariance. Current batch fill does not yet advance an in-memory allocation ledger between appended criteria, so multiple new requirements in one batch need attention.
- Driver spec wrapper currently returns no publication on skeleton full with no candidate; approval already-present no-op path needs final original-token acceptance check. Complete original-token/receipt behavior rather than assume these paths are covered.
- Bootstrap owner resolution currently uses persisted generated UUID per feature; inspect declared workspace/operator repository identity requirements before declaring creation semantics complete.
- Temporary shell token cleanup/bounds, robust original-input versus output-path validation, stale checks for direct sidecar writes and failures currently masked in existing shell flows, and final review of helper semantics.
- Final exact Verify, four-question recheck, and all required probes on final source.

## Probes run before later edits

On feature_write.py, execute_remediation.py and publication-callers.test.sh only: indirection/comment/failure scans clean. Duplication reported existing writer CLI shape against feature_read.py; house-style reported four-space indentation in existing writer and remediation modules against two-space neighbors. Baseline substantiation and final probes were not completed, so these are NOT adjudicated clean final results. Additional edits happened afterward.

## Design gate at ingress

Reuse transaction policy and receive a trusted resolver instead of deriving target authority from token paths. Keep original ingress immutable and return only accepted own-write refresh. Hash streaming and artifact/transaction limits remain the primitive's responsibility. Staging names are unique for concurrent producers. No third-party dependency or runtime version selected. Final design gate was not reached because work stopped incomplete.

## Final stop notes

The root-level untracked .artifact-publication.lock and .feature-write.lock are likely generated by the initial failed cycle-driver fixture cascading an empty feature directory into the writer (Path("") is cwd); timestamps match that test. They are empty runtime lock files, not source or handoff artifacts; exclude them from checkpoint.

Latest parent update: sink passes 10 shell checks plus the real stale/crash/index recovery regression after a bounded empty-directory-after-rollback repair. Parent probes are clean except equivalent stdlib import-block shape and unchanged test-harness baseline; see its separate report.
