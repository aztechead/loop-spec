# Execution discipline (evidence over recall) — canonical prompt directive

Single source of truth for the execution-discipline directive that every **EXECUTE/VERIFY
dispatch** must carry. Enforced by `tests/execution-discipline-coverage.test.sh`,
mirroring `tests/ponytail-coverage.test.sh` and `tests/design-coverage.test.sh`.

## Why this exists

The cycle's design phases run on the strongest available reasoning, but EXECUTE and
VERIFY run on throughput models (sonnet) and gates on opus. The failure modes that
separate a frontier reasoning pass from a mid-tier execution pass are consistent and
predictable:

- **Pattern-completion instead of verification.** A mid-tier model asserts what a file
  or API "does" because it looks like something it has seen, instead of reading or
  running it. A frontier pass continuously self-verifies: every load-bearing claim is
  checked against the artifact before it is used.
- **Rationalizing anomalies away.** When output contradicts expectation, the weaker
  habit is to explain it away and keep going; the stronger habit treats the anomaly as
  the most valuable data point in the session.
- **Declaring victory on plausible-looking output.** Green-ish text is not a passed
  gate. The stronger habit re-opens the contract (acceptance criteria) and checks each
  item against actual output before saying DONE.
- **Breadth over depth under pressure.** Skimming five files feels productive; reading
  the one load-bearing file completely is what actually prevents the wrong fix.
- **Confident filler over calibrated uncertainty.** The weaker habit papers over a
  missing fact with fluent prose; the stronger habit names the missing fact and stops.

The directive below compresses those habits into instructions a dispatched executor can
follow mechanically. It complements — never replaces — the laziness ladder
(`skills/shared/laziness-ladder.md`, how much code) and design-for-change
(`skills/shared/design-for-change.md`, where the boundaries sit): this one governs
**how the work is verified while it happens**.

## Relationship to existing gates

The cycle already externalizes several of these habits into machinery — probe-before-
assert grounding (`skills/shared/grounding-protocol.md`), the test-tamper scan,
maker≠checker gates. The directive is the
in-prompt counterpart: it shapes the executor's moment-to-moment behavior so the
machinery catches less, not more.

## Canonical compact directive (inline this verbatim into dispatch prompts)

> EXECUTION DISCIPLINE (evidence over recall — on by default). You execute a brief that a
> stronger reasoning pass produced; your job is fidelity, not improvisation. (1) Verify,
> don't recall: never assert what a file, command, or API does from memory — read it, run
> it, paste the actual output. (2) Surprise is signal: output that contradicts your
> expectation is information, not noise — stop, re-read, revise the hypothesis; never
> explain it away. (3) Re-read the contract before DONE: open the acceptance criteria
> again and check each against actual output; meeting the letter while missing the intent
> is a failure. (4) Depth over breadth: read the load-bearing file completely instead of
> skimming five. (5) Artifacts over memory: after a long stretch or compaction, re-read
> the task spec and state files instead of trusting recollection. (6) Uncertainty is a
> status, not a gap to fill: return NEEDS_CONTEXT naming the exact missing fact; never
> bridge it with confident prose. (7) Tripwires: "should work", "probably fine", "tests
> likely pass" — each of these phrases means run it now.
