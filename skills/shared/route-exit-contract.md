# No route exits without a terminal result (shared contract)

A routed run must publish `.loop-spec/last-result.json` before it ends.
Follow `docs/loop-spec/agent-output-contract.md` for the result format.
Headless callers use `converged` to determine success. A missing result means the run did not report an ending.
Publish a result for delivery, failure, escalation, interruption, or a request outside repository work.

## The rule

- Every route (`micro`, `debug`, `full`) publishes exactly one terminal result before
  the run ends. `/loop-spec:auto` arms the run at routing time, so the obligation
  starts before the routed skill does.
- A request the router accepted, and any request that involves editing the repository,
  must run through that protocol or promote to a larger route.
  Use the maintenance profile for smaller work (`skills/shared/tier-matrix.md`).
- Leaving the protocol and doing the work yourself is not an ending. Never hand-write a
  converged result for work the route did outside its own delivery contract.
  `converged: true` means that protocol's verification and PR delivery ran.

## Ending on a protocol mismatch

Use `protocol-mismatch` only for pure questions, explanations without edits, or work that needs another product.
Rebases, branch syncs, merge-conflict resolutions, PR re-reviews, and one-command chores are repository work.
Use micro within its limits, or full with `profile=maintenance` otherwise.
Run the selected protocol through delivery and publish its result.

When the request is genuinely not repository work, stop **before changing the
repository** and publish:

```bash
bash "${LOOP_SPEC_SKILL_DIR}/../../lib/cycle-result.sh" write-terminal \
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

After delivery, publish full-cycle success with `write <feature_dir> --status completed` or `write-terminal --outcome delivered`.
The graph engine also publishes when it enters the `completed` node.
Run every remaining agent node, including ITERATE and DELIVER, even on the maintenance short path.

## Enforcement

- `lib/task-route.sh validate` arms the run (`cycle-result.sh begin`, git-ignored
  `.loop-spec/active-run.json`); a published terminal result is the only thing that
  disarms it.
- `lib/cycle-result.sh state` answers `published | unaccounted | idle` for a root.
- `hooks/team/route-terminal-guard.sh` (Stop) blocks the end of an autonomous session
  whose armed run published nothing. Kill switch: `LOOP_SPEC_ROUTE_GUARD=0`.
- `hooks/team/cycle-stamp-guard.sh` (Stop) blocks the end of a session that was
  invoked as `/loop-spec:cycle` and never called the driver (the prompt stamp
  `cycle-driver.sh start` consumes is still there; the decline above is the one way
  past it, and `LOOP_SPEC_INVOCATION_STAMP=0` stops the stamp and with it the deny),
  and the end of a session that opened a phase and never returned it to the driver
  (a `phase_start` with no `phase_end` and no newer result; `next --returned-from`
  or `escalate` is the way past it).
- `lib/cycle-reconcile.sh --result-root <root>` converts a surviving armed run into a
  terminal result after the fact. It is the out-of-band backstop and the in-band
  confirmation `/loop-spec:auto` runs after its delegated route returns. A PR
  already delivered in that run is recorded `completed`/`delivered` (or
  `delivered-draft` when the PR remains a draft after green checks), not
  `interrupted`.

Codex registers `cycle-stamp-guard.sh` and `route-terminal-guard.sh` on Stop.
Exit 2 with stderr continues the turn, as on Claude Code (`skills/shared/codex-harness.md`).
OpenCode and ADK have no equivalent Stop veto (`skills/shared/opencode-harness.md`, `skills/shared/adk-harness.md`).
Their explicit driver gates and result validation enforce route completion.
Run `/loop-spec:auto`'s reconcile call on every harness.
