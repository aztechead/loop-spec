# 7.0 implementation handoff

For the agent continuing `feat/7.x.x`. The user requested a commit and push checkpoint because usage was running low. **This checkpoint is incomplete and is not release-ready.**

## Completed work

The approved release design is in SPEC.md and PLAN.md. EXECUTE has twelve tasks; only tasks 001–003 are complete, reviewed, verified, and recorded done:

| Task | Commit | Result |
| --- | --- | --- |
| 001 | `8c59e82` | Versioned requirement inventory, grammar, stable IDs/revisions |
| 002 | `716fb4d` | Nested identity/publication state validation and monotonic ledger |
| 003 | `354cc49` | Generation-aware publication, locking, journal recovery, persistence |

Task 003's integration Verify passed. Its repeated-interruption recovery defect was fixed and independently re-reviewed before commit. Task 004's review baseline remains `354cc49c4e88d66a366adb6a4c68160878e709bb`; the handoff checkpoint does **not** mark task 004 complete.

## Current work and evidence

Read [the implementer report](handoff/task-004-report.md), [parent evidence](handoff/task-004-parent-report.md), [the exact expanded task brief](handoff/task-004-brief.md), and [progress snapshot](handoff/tasks-progress.json). They are handoff snapshots, not new editable sources of requirement truth. PLAN remains the task authority.

Task 004 partially integrates stable-ID SPEC authoring, legacy bootstrap, original-token state writers, shell parent/child token transfer, and transactional remediation. The complete producer/caller sweep, phase exit/acknowledgement, quality-loop, graph-engine integration, templates/skills, and all acceptance fixtures remain unfinished. The expanded scope is recorded in PLAN, the SPEC footprint, the local task sidecar, and dispatch preparation packet.

Latest checks:

- Cycle-driver: **254 passed, 7 failed**. See [full log](handoff/task004-cycle-driver.txt). Several fixture assumptions conflict with the required Codex / `LOOP_SPEC_WORKTREES=0` environment; investigate each without weakening production checks.
- Execute-prepare: **49 passed, 28 failed**. See [full log](handoff/task004-execute-prepare.txt). Confirmed mismatch: parent resolves `/var` to `/private/var`, while remediation supplies the persisted alias as its registry. Normalize the trusted resolver consistently; do not trust arbitrary token paths or recapture at egress.
- Feature writer: 33 cases and four concurrency tests passed; graph-state: 21 passed. See report for timing relative to subsequent edits.
- Publication primitive: nine test groups passed after the trusted external-root/deletion extension.
- Artifact sink: ten existing shell checks and the new real Git stale-write/interruption/recovery regression passed. This last bounded check includes the sink edits made while wrapping up.
- Full task 004 Verify, its fresh compliance review, and the repository-wide suite have **not** passed or been completed.

## Parent-owned sink changes

The existing sink shell now launches `lib/artifact_sink.py`. It prepares a separate Git index and stages archive copies, baseline document restoration/deletion, live index bytes, and artifactSink metadata through one publication transaction. `store` supports explicit input/accepted-output token transport; `recover` rebuilds trusted registrations from journal key families. External roots are received by the Python publication API, never granted by tokens or a generic CLI flag.

The sink is newly implemented and still requires full review. In particular, check executable baseline document modes (the current manifest carries bytes, not desired modes), hard process death while holding Git's index lock, archived state metadata consistency, source additions during preparation, replay/idempotence validation, and integration with finalization and token propagation. Do not mistake the focused passing regression for completed task 004 acceptance.

Parent source probes passed except two adjudicated duplication findings: a sequence of stdlib imports (not duplicated behavior) and the pre-existing test harness. Four doc-tells references on unchanged PLAN line 15 name modules intentionally created by later tasks; do not add placeholders or suppress lint to satisfy these references.

## Resume safely

1. Follow repository CLAUDE.md and `/Users/aztechead/.codex/RTK.md`; every shell command uses `rtk`. No live evals were authorized.
2. Continue task 004; do not dispatch tasks 001–003 again. Fix its failures and complete every criterion before marking it done. Review the whole task from baseline `354cc49`, including checkpointed changes and later edits.
3. In this existing workspace, retain `.loop-spec/features/release-7-0` and its task statuses. Do not re-extract PLAN into the live sidecar or overwrite approval state. The portable progress/brief snapshots here are for a fresh checkout, not instructions to replace existing runtime state.
4. The running cycle is self-hosted through an immutable Git archive of planning revision `68a2f56fd2ce4e15604a6ee97a8aed872b7787b5`, at `.git/loop-spec/runtimes/<that SHA>`. Use its `lib/cycle-driver.sh` and `lib/state-ref.sh` for cycle control. Keep `LOOP_SPEC_HARNESS=codex LOOP_SPEC_WORKTREES=0 LOOP_SPEC_CHECKPOINT_PR=0`. Do not edit that archive or switch the active cycle to changing source instructions. A fresh clone must recreate this archive and establish runtime state through supported cycle tooling; ignored runtime files and local state refs are not included by an ordinary branch push.
5. After task 004 passes fresh review and its exact Verify, continue tasks 005–012 in PLAN order. The new v1 default/strict-token activation belongs to task 009. Observations, final-candidate exact-SHA evidence, migration, and the 7.0.0 release bump are not implemented yet.
6. Stop at the EXECUTE-to-VERIFY phase boundary after all twelve tasks. Do not merge or publish a release automatically.

The approved Goals/Boundaries digest remains `c5036f53b764d067317f2e6778afdfd0fe272dd623c6996d7694ebb875ddc4be`, human-approved. Footprint refinements did not change those sections. Product version has not been bumped.
