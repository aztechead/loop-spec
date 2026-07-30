# Subagent concurrency contract

`LOOP_SPEC_MAX_PARALLEL_SUBAGENTS=N` is the deployment-wide cap on simultaneous
one-shot Agent calls. It is optional; unset preserves each phase's normal fixed
fan-out. When set, `N` must be a positive integer.

An explicit cap changes dispatch policy:

- Agent calls are issued in waves of at most `N`; wait for a wave before starting
  the next.
- `N=1` means serial one-shot subagents. The lead waits for each role agent and then
  continues, so role context stays outside the lead even though no workers overlap.
- Do not leave background Agent calls running across later dispatch points. A phase
  either awaits the bounded wave or defers the optional prefetch to its normal join.
- Agent teams, Workflow fan-out, and EXECUTE loop fleets are disabled because their
  internal live-worker count cannot be proven to honor this cross-phase cap. The
  deterministic capability scripts enforce that downgrade; phases use the no-teams
  one-shot fallback.
- EXECUTE also clamps `maxParallelImplementers` to `N`.

The cap controls agent fan-out, not Cloud Run CPU, RAM, instance concurrency, or the
number of independent containers. Those remain deployment settings.
