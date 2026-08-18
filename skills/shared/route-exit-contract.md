# No route exits without a terminal result (shared contract)

A routed run ends by publishing `.loop-spec/last-result.json`. That pointer is the whole
machine-readable contract (`docs/loop-spec/agent-output-contract.md`). Headless callers
gate success on its `converged` flag, and its absence means the run reached no terminal
emission. **Any** ending is a publishable ending — delivered, failed, escalated,
interrupted, or "this protocol did not fit". Only silence is not.

Silence is what an abandoned protocol produces. A route loads a skill, judges it a poor
fit, leaves it, and finishes the task by hand: the work happens, the record does not.
The supervisor then reads the missing pointer as failure, wakes a human, and marks a
good PR a draft. Being right does not make the run accountable.

## The rule

- Every route (`micro`, `debug`, `full`) publishes exactly one terminal result before
  the run ends. `/loop-spec:auto` arms the run at routing time, so the obligation
  starts before the routed skill does.
- Judging the routed protocol a poor fit is a legitimate finding. Acting on it by
  leaving the protocol and doing the work yourself is not. Report the mismatch, or
  run the protocol — never a third thing.
- Never hand-write a converged result for work the route did outside its own delivery
  contract. `converged: true` means that protocol's verification and PR delivery ran.

## Ending on a protocol mismatch

When the routed protocol genuinely does not fit the task, stop **before changing the
repository** and publish:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-result.sh" write-terminal \
  --result-root "$repo_root" --cycle-type <full|micro|debug> \
  --status escalated --outcome protocol-mismatch --converged false \
  --title "$title" --reason "<why this protocol does not fit>" \
  --summary "<what the task actually needs, and that no work was done>" \
  --autonomous "$autonomous"
```

`protocol-mismatch` requires `--status escalated`, a non-empty `--reason`, and an
unmodified tracked tree — the writer rejects it otherwise. Having already changed the
repository is not a mismatch to report; it is work to finish or a failure to declare
(`--status failed --outcome interrupted`).

Stopping is the point. The caller learns the request needs a different protocol and can
re-route it; that is a smaller loss than an unaccounted run.

## Enforcement (probe and guard, not prose hope)

- `lib/task-route.sh validate` arms the run (`cycle-result.sh begin`, git-ignored
  `.loop-spec/active-run.json`); a published terminal result is the only thing that
  disarms it.
- `lib/cycle-result.sh state` answers `published | unaccounted | idle` for a root.
- `hooks/team/route-terminal-guard.sh` (Stop) blocks the end of an autonomous session
  whose armed run published nothing. Kill switch: `LOOP_SPEC_ROUTE_GUARD=0`.
- `lib/cycle-reconcile.sh --result-root <root>` converts a surviving armed run into a
  terminal result after the fact. It is the out-of-band backstop and the in-band
  confirmation `/loop-spec:auto` runs after its delegated route returns. A PR
  already delivered in that run is recorded `completed`/`delivered`, not
  `interrupted`.
- Full-cycle success is `write <feature_dir> --status completed`. `--outcome
  delivered` (write or write-terminal) is that alias — DELIVER's own word. The
  graph engine also publishes on entering the `completed` node, so the agent
  does not have to hand-author the exact CLI.

Under OpenCode and ADK no Stop event can veto
(`skills/shared/opencode-harness.md`, `skills/shared/adk-harness.md`), so the
reconcile call in `/loop-spec:auto` is the only enforcement there. Run it.
