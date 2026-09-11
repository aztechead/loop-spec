# 7.0 implementation handoff

For the agent continuing `feat/7.x.x` (work is on branch `claude/7-0-release-handoff-0biuqi`, to be merged into `feat/7.x.x`). **This checkpoint completes tasks 004 through 010; tasks 011–012 remain.**

## Completed work

The approved release design is in SPEC.md and PLAN.md. EXECUTE has twelve tasks; tasks 001–010 are complete, reviewed, verified, and recorded done in [the progress snapshot](handoff/tasks-progress.json):

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

Task 004 landed as reviewed checkpoints, each verified against its suites before commit: publication primitive fixes (`33631d0`), quality-loop and artifact-sink publication (`9d3713b`), driver/engine/phase-lifecycle token threading with the publication-callers inventory (`a817d32`), the portability probe (`d81b8fa`), v1 authoring routes (`f0673ec`), the bad-spec review recovery and the legacy-resume fixture (`06dd70c`), and the configuration reference plus a BSD-only sed fix (`9552c4e`). The exact task Verify command passes (every named suite exits 0), `tests/run-all.sh` passes (its two failures at `06dd70c` were pre-existing and fixed in `9552c4e`), and an independent compliance review from baseline `354cc49` found no blocking finding.

## Contract now in force

Every state writer under `lib/` and `hooks/` is a publication participant: it captures one ingress token per operation (`lib/feature_write.py begin_operation`, the sourced helpers in `lib/feature-write.sh`, or `lib/publication_participant.py` for the driver and in-process engine), stages registered artifacts and publishes them with that token, adopts only its own or a child's accepted refresh, and never re-captures. Children receive `LOOP_SPEC_PUBLICATION_TOKEN` and return `LOOP_SPEC_PUBLICATION_TOKEN_OUTPUT` (documented in `docs/loop-spec/configuration.md`). `tests/lib/publication-callers.test.sh` sweeps the tree for writers at call time; a new writer fails it until handled. Every new cycle records a v1 requirements contract at creation; a resumed pre-7 cycle is bootstrapped once as legacy and held to the same token rule.

## Resume safely

1. Follow repository CLAUDE.md. The plugin runs on any *nix: run `bash lib/portability-scan.sh scan <files>` on every shell or Python edit. The handoff's `rtk` wrapper is a local tool of the original workstation; run plain `bash`. No live evals were authorized.
2. Continue with task 011 in PLAN order; do not dispatch tasks 001–010 again. Each task's Verify command in [the progress snapshot](handoff/tasks-progress.json) is authoritative.
3. Run each task's suites with `LOOP_SPEC_HARNESS`, `LOOP_SPEC_WORKTREES` and `LOOP_SPEC_CHECKPOINT_PR` unset in the shell; fixtures set their own. Exporting `LOOP_SPEC_WORKTREES=0` globally is what produced the seven spurious cycle-driver failures the previous checkpoint recorded.
4. In the original workspace, retain `.loop-spec/features/release-7-0` and its task statuses; the snapshots here are for a fresh checkout. The self-hosted cycle runs through the immutable runtime archive of planning revision `68a2f56fd2ce4e15604a6ee97a8aed872b7787b5`; do not edit that archive.
5. Stop at the EXECUTE-to-VERIFY phase boundary after all twelve tasks. Do not merge or publish a release automatically.

The approved Goals/Boundaries digest remains `c5036f53b764d067317f2e6778afdfd0fe272dd623c6996d7694ebb875ddc4be`, human-approved and re-verified at `9552c4e`. Product version has not been bumped.
