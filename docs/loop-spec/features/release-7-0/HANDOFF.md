# 7.0 implementation handoff

For the agent continuing `feat/7.x.x` (work is on branch `claude/7-0-release-handoff-0biuqi`, to be merged into `feat/7.x.x`). **This checkpoint completes all twelve EXECUTE tasks. The cycle stands at the EXECUTE-to-VERIFY boundary.**

## Completed work

The approved release design is in SPEC.md and PLAN.md. EXECUTE has twelve tasks; all are complete, reviewed, verified, and recorded done in [the progress snapshot](handoff/tasks-progress.json):

| Task | Commits | Result |
| --- | --- | --- |
| 001 | `8c59e82` | Versioned requirement inventory, grammar, stable IDs/revisions |
| 002 | `716fb4d` | Nested identity/publication state validation and monotonic ledger |
| 003 | `354cc49` | Generation-aware publication, locking, journal recovery, persistence |
| 004 | `33631d0` … `9552c4e` | Every producer route stages and publishes with its original ingress token |
| 005 | `c041129` | Coverage validated against the complete dispatch representation |
| 006 | `207306d` | Declared execution input identities |
| 007 | `6cec0e7` | Bounded driver-owned execution observations |
| 008 | `2f97ad2` | Observed scenario evidence at VERIFY/ITERATE gates and fresh final-candidate observations before delivery |
| 009 | `54e205b`, `02c4aa9`, `3fe355e` | Guarded publication on all four harnesses; v1 default; strict ingress tokens |
| 010 | `7e5eb30` | Deterministic read-only migration preview |
| 011 | `9df14bd` | Migration apply, resume and rollback under the publication lock |
| 012 | `76d76ba`, `4920103`, `096e0d5`, `c3284a5`, `b911135` | Release notes, roadmap status, the release coverage suite, review hardening, and the 7.0.0 version bump |

Task 004 landed as reviewed checkpoints, each verified against its suites before commit: publication primitive fixes (`33631d0`), quality-loop and artifact-sink publication (`9d3713b`), driver/engine/phase-lifecycle token threading with the publication-callers inventory (`a817d32`), the portability probe (`d81b8fa`), v1 authoring routes (`f0673ec`), the bad-spec review recovery and the legacy-resume fixture (`06dd70c`), and the configuration reference plus a BSD-only sed fix (`9552c4e`). The exact task Verify command passes (every named suite exits 0), `tests/run-all.sh` passes (its two failures at `06dd70c` were pre-existing and fixed in `9552c4e`), and an independent compliance review from baseline `354cc49` found no blocking finding.

Tasks 005 through 012 passed a second independent compliance review from baseline `9552c4e`; its two should-fix findings (an edge-inference write outside the publication boundary, and tool-boundary guards that judged unresolved symlink paths) closed in `096e0d5`. One live-run findings pin then needed realignment with the print-only edges subcommand (`c3284a5`). The bump commit `b911135` ran the task 012 Verify on its own head.

The 6.6.0 hotfix (pull request 95, `main` at `fa8fa4d`) merged into this branch after the bump. It moves the Goal and Boundary freeze from SPEC exit to PLAN entry, records `specIntentSeen` at SPEC exit, retires an approval into `specApprovalHistory` on a human-approved rewind, and answers a refused phase entry with `entry_refused` instead of an escalation. Its state writes ride this branch's participant seam (`fset`/`fappend` in `lib/graph/driver.py`), and its test fixtures write through `fw_set` so the strict token rule holds. The 7.0.0 changelog entry sits above 6.6.0; the version stays 7.0.0.

## Contract now in force

Every state writer under `lib/` and `hooks/` is a publication participant: it captures one ingress token per operation (`lib/feature_write.py begin_operation`, the sourced helpers in `lib/feature-write.sh`, or `lib/publication_participant.py` for the driver and in-process engine), stages registered artifacts and publishes them with that token, adopts only its own or a child's accepted refresh, and never re-captures. Children receive `LOOP_SPEC_PUBLICATION_TOKEN` and return `LOOP_SPEC_PUBLICATION_TOKEN_OUTPUT` (documented in `docs/loop-spec/configuration.md`). `tests/lib/publication-callers.test.sh` sweeps the tree for writers at call time; a new writer fails it until handled. Every new cycle records a v1 requirements contract at creation; a resumed pre-7 cycle is bootstrapped once as legacy and held to the same token rule.

## Resume safely

1. Follow repository CLAUDE.md. The plugin runs on any *nix: run `bash lib/portability-scan.sh scan <files>` on every shell or Python edit. The handoff's `rtk` wrapper is a local tool of the original workstation; run plain `bash`. No live evals were authorized.
2. Do not dispatch tasks 001–012 again. Each task's Verify command in [the progress snapshot](handoff/tasks-progress.json) is authoritative; the task 012 Verify (`bash tests/run-all.sh && bash lib/bump-version.sh --check`) passes at `b911135` with 250 suites and no skip. `tests/adk-extension.test.sh` needs `google-adk` importable by `python3`; without it the suite prints `SKIP` with zero checks and exits 0, so run it once on a workstation that has the package before release.
3. Run each task's suites with `LOOP_SPEC_HARNESS`, `LOOP_SPEC_WORKTREES` and `LOOP_SPEC_CHECKPOINT_PR` unset in the shell; fixtures set their own. Exporting `LOOP_SPEC_WORKTREES=0` globally is what produced the seven spurious cycle-driver failures the previous checkpoint recorded.
4. In the original workspace, retain `.loop-spec/features/release-7-0` and its task statuses; the snapshots here are for a fresh checkout. The self-hosted cycle runs through the immutable runtime archive of planning revision `68a2f56fd2ce4e15604a6ee97a8aed872b7787b5`; do not edit that archive.
5. The next phase is VERIFY. Do not merge or publish a release automatically; a human decides the merge into `feat/7.x.x` and the release.

The approved Goals/Boundaries digest remains `c5036f53b764d067317f2e6778afdfd0fe272dd623c6996d7694ebb875ddc4be`, human-approved and re-verified at `b911135`. Product version is 7.0.0 in all three manifests and the README.
