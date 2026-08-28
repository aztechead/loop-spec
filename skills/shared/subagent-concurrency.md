# Subagent concurrency contract

`LOOP_SPEC_MAX_PARALLEL_SUBAGENTS=N` is the deployment-wide cap on simultaneous
one-shot Agent calls. It is optional; unset preserves each phase's normal fixed
fan-out. When set, `N` must be a positive integer.

An explicit cap changes dispatch policy:

- Agent calls are issued in waves of at most `N`; stop until a wave completes before
  starting the next. Never AskUserQuestion as a wait
  (`skills/shared/harness-call-contracts.md`).
- `N=1` means serial one-shot subagents. The lead waits for each role agent and then
  continues, so role context stays outside the lead even though no workers overlap.
- Do not leave background Agent calls running across later dispatch points. A phase
  either awaits the bounded wave or defers the optional prefetch to its normal join.
- Agent teams, Workflow fan-out, and EXECUTE loop fleets are disabled because their
  internal live-worker count cannot be proven to honor this cross-phase cap. The
  deterministic capability scripts enforce that downgrade; phases use the no-teams
  one-shot fallback.
- EXECUTE also clamps `maxParallelImplementers` to `N`.

On the headless one-shot subagent rung, Agents share the lead's session cwd even
when `LOOP_SPEC_WORKTREES=1`. Parallel implementers are collision-safe only when
the lead creates each task worktree **before** dispatch (`subagentIsolation=
lead-worktree`). Wave width > 1 is forbidden unless those worktrees exist; a
failed add serializes the wave onto `feat/{slug}`. Raising the implementer cap
(caps → 3 and beyond) is gated on that isolation remaining in force.

The cap controls agent fan-out, not Cloud Run CPU, RAM, instance concurrency, or the
number of independent containers. Those remain deployment settings.
