# Execution discipline (evidence over recall) — canonical prompt directive

Single source of truth for the execution-discipline directive that every **EXECUTE/VERIFY
dispatch** must carry. Enforced by `tests/execution-discipline-coverage.test.sh`,
mirroring `tests/ponytail-coverage.test.sh` and `tests/design-coverage.test.sh`.

## Why this exists

Every phase may run on any inherited model, subject to explicit phase or role routes.
The execution failures this directive prevents are consistent across model catalogs:

- **Pattern-completion instead of verification.** A model asserts what a file
  or API "does" because it looks like something it has seen, instead of reading or
  running it. Continuously self-verify: every load-bearing claim is
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
> likely pass" — each of these phrases means run it now. (8) Scope is closed: the brief's
> acceptance criteria are the whole job — never skip, trim, or defer an item, and never
> write "follow-up", "deferred", or "future work" notes; a criterion you cannot meet is
> NEEDS_CONTEXT or a loud failure with evidence, never a note
> (`skills/shared/no-deferral.md`). (9) Keep extras out: if you find a pre-existing bug,
> performance concern, or behavior the task does not mention, leave it unchanged unless
> the requested behavior cannot work without it; record the out-of-scope finding where
> the phase contract permits. Keep permanent tests to requested behavior or the
> repository's established convention, normally one focused test per stated behavior;
> scratch checks need not ship. (10) Prefer targeted edits: when the result is unchanged,
> surgically edit the needed lines instead of rewriting a whole file.
