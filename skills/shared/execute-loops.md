# EXECUTE self-claim loops (reference)

Lead-side notes for the implementer and reviewer self-claim loops referenced by
`skills/execute/SKILL.md` Steps 5-6. The loops themselves are the team prompts the
teammates actually run — `skills/shared/team-prompts/implementer.md` and
`skills/shared/team-prompts/reviewer.md`; do not restate them here. The 3-state task
model lives inline in `skills/execute/SKILL.md` Step 5 because the lead's
wake/merge/exit logic depends on it. What follows is only the contract the lead
relies on:

- **Race-claim serialization.** The harness serializes concurrent `TaskUpdate` calls
  on the same task id: exactly one claimant wins, the loser gets an error and re-runs
  its self-claim loop. No additional locking exists at the cycle level.
- **State before message.** Every status transition (`TaskUpdate`) is written BEFORE
  its accompanying `SendMessage`, so `TaskList` is the source of truth even when a
  message drops at turn-end. The lead reconciles the merge queue and exit condition
  from `TaskList` state on every wake (execute SKILL Step 7), including the guaranteed
  `TeammateIdle` notification — a dropped `REVIEW PASS`/idle message cannot strand a
  completed task or hang the phase.
- **Queue discriminators.** Rework and review queues live in `metadata.phase`
  (`needs_rework` / `awaiting_review`) with `owner == null`; status stays
  `in_progress` while work is in flight. A blocked task terminates as
  `status: "completed"` with `metadata.result: "blocked"` so the harness list keeps
  moving while the lead's exit check still sees the failure.
- **Worktree resolution.** Implementers resolve their task worktree through
  `lib/worktree-base.sh resolve` (never a hard-coded path) and branch
  `task/{taskId}-{slug}` from the feature branch.
- **Unverified findings.** A reviewer `pass` requires empty `unverified[]`; non-empty
  goes to the lead as `UNVERIFIED:` for a ruling or promotion to rework. Items must
  not evaporate.
