# Execution discipline (evidence over recall) — canonical prompt directive

Include this directive in every EXECUTE and VERIFY dispatch.
`tests/execution-discipline-coverage.test.sh` checks those references.
The directive applies to every model and preserves existing grounding, test-integrity, and independent-review gates.

Use `skills/shared/laziness-ladder.md` for implementation size and `skills/shared/design-for-change.md` for design boundaries.
This contract governs evidence and scope during execution.

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
