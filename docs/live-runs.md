# loop-spec 8.x live runs

For a contributor who needs to show, or check, how loop-spec behaves with a real
model. Unit tests cover the program's deterministic Python; everything a model does
in a run is shown here by a recorded live run, never simulated.

Record one run per row as it happens.

## How to record a run

1. Run an entry against a throwaway repository with an `origin` you can push to, in
   Claude Code (`claude -p ... --output-format stream-json --verbose > run.jsonl`) or
   with [examples/sdk-plugin](../examples/sdk-plugin/README.md).
2. Add a row: the date, the loop-spec commit, the entry and mode, the lead's model,
   what the run showed, and its result (`status`, PR link if public).
3. Keep the transcript out of the repository; note where it is kept, if anywhere.

| Date | Commit | Entry, mode | Lead model | What it showed | Result |
|---|---|---|---|---|---|
| 2026-10-04 | `59556a6` | cycle, autonomous; kvstore TTL + LRU + persisted stats (A) | Sonnet 5.5, medium; all agents Sonnet | All phases in 104 s: 7-criterion spec, a 2-task chain the lead did itself, one reviewer (found a `delete` bug, fixed), verify passed in a clean checkout. Stopped at deliver (no GitHub origin) without `finish`, and wrote `"prepare": "true"`; both fixed in `82ae482` | no result written; hidden acceptance 11/11 |
| 2026-10-04 | `82ae482` | same as above (A) | Sonnet 5.5, medium; all agents Sonnet | 105 s. One-task plan done by the lead, reviewer, verify; ended with `finish --status escalated` naming the blocker and the verified SHA | escalated (no GitHub origin), `verifiedSha` set; hidden acceptance 11/11 |
| 2026-10-04 | `82ae482` | cycle, autonomous; kvstore CSV io + key validation + history (B) | Sonnet 5.5, medium; all agents Sonnet | 147 s. A real DAG: T-1, T-2, T-3 independent, T-4 depends on all three; three implementers dispatched in one message, each reviewed by the lead before `task done`; reviewer found a CSV traceback, fixed with a test; verify passed | escalated (no GitHub origin), `verifiedSha` set; hidden acceptance 7/7 |

For comparison, 7.9.0 on request A with the same model settings (`--answer-policy default`,
every role on Sonnet) took 1108 s, 237 tool calls, and 26 worker dispatches, and
reported $6.13 against 8.0's $0.41. Its spec included a criterion that no file
contain the word `sleep`; a test comment ("instead of sleeping") kept failing it, VERIFY
routed the run back twice, and the recurrence guard ended it `escalated` with no
verified head. Its code also passed the hidden acceptance check, 11/11.
