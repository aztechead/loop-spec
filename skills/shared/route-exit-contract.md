# No route exits without a terminal result (shared contract)

A routed run ends by publishing `.loop-spec/last-result.json`. That pointer is the whole
machine-readable contract (`docs/loop-spec/agent-output-contract.md`). Headless callers
gate success on its `converged` flag, and its absence means the run reached no terminal
emission. **Any** ending is a publishable ending — delivered, failed, escalated,
interrupted, or "this request is not repository work". Only silence is not.

Silence is what an abandoned protocol produces. A route loads a skill, judges it a poor
fit, leaves it, and finishes the task by hand: the work happens, the record does not.
The supervisor then reads the missing pointer as failure, wakes a human, and marks a
good PR a draft. Being right does not make the run accountable.

The complementary failure is declining work the router already accepted. v3.0.1 stopped
the freelance path by requiring a terminal result; using `protocol-mismatch` to refuse a
rebase, a branch sync, a merge-conflict resolution, a PR re-review, or a one-command
chore produces a published no-op. Headless callers gating on `converged` still fail, and
nothing was delivered. Report a mismatch, or run the protocol — never a third thing, and
never a decline of repository work.

## The rule

- Every route (`micro`, `debug`, `full`) publishes exactly one terminal result before
  the run ends. `/loop-spec:auto` arms the run at routing time, so the obligation
  starts before the routed skill does.
- A request the router accepted, and any request that involves editing the repository,
  is work to execute through that protocol (or to promote into a larger one). Ceremony
  that feels heavy is the maintenance profile / graph short path
  (`skills/shared/tier-matrix.md`), not a licence to stop.
- Leaving the protocol and doing the work yourself is not an ending. Never hand-write a
  converged result for work the route did outside its own delivery contract.
  `converged: true` means that protocol's verification and PR delivery ran.

## Ending on a protocol mismatch

`protocol-mismatch` is reserved for a genuine **non-task**: a pure question, an
explanation with no edit, or work that needs a different product entirely. It is not
for a task whose seven-phase shape looks like a poor fit. A rebase, a branch sync, a
merge-conflict resolution, a PR re-review, or a one-command chore is repository work —
route it to a fitting protocol (micro when the bounds hold; full with
`profile=maintenance` when they do not) and execute it to a converged terminal result.

When the request is genuinely not repository work, stop **before changing the
repository** and publish:

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-result.sh" write-terminal \
  --result-root "$repo_root" --cycle-type <full|micro|debug> \
  --status escalated --outcome protocol-mismatch --converged false \
  --title "$title" --reason "<why this is not repository work>" \
  --summary "<what the request actually needs, and that no work was done>" \
  --autonomous "$autonomous"
```

`protocol-mismatch` requires `--status escalated`, a non-empty `--reason`, and an
unmodified tracked tree — the writer rejects it otherwise. Having already changed the
repository is not a mismatch to report; it is work to finish or a failure to declare
(`--status failed --outcome interrupted`).

## Delivery still publishes

A run that does the work is not done until the terminal result lands. Full-cycle success
is `write <feature_dir> --status completed` (or `write-terminal --outcome delivered`,
DELIVER's own word). The graph engine also publishes on entering the `completed` node.
Walk every remaining agent node — ITERATE and DELIVER included — even on the
maintenance short path. Skipping DELIVER to "save ceremony" is the same unaccounted
ending this contract exists to prevent.

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

Under OpenCode, ADK, and Codex no Stop event can veto
(`skills/shared/opencode-harness.md`, `skills/shared/adk-harness.md`,
`skills/shared/codex-harness.md`). Codex Stop polarity is inverted versus
Claude Code (`decision: "block"` continues the turn), so Claude Stop guards
are not bridged there either. The reconcile call in `/loop-spec:auto` is the
only enforcement on those three harnesses. Run it.
