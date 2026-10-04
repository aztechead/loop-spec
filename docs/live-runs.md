# loop-spec 8.x live runs

For a contributor who needs to show, or check, how loop-spec behaves with a real
model. Unit tests cover the program's deterministic Python; everything a model does
in a run is shown here by a recorded live run, never simulated.

Record one run per row as it happens.

## Scenarios

Each run uses one of these against a small Python repository (`kvstore`, a JSON-file
key-value store with a CLI). A scenario names what the run must show; a hidden
acceptance script, never shown to the lead, checks the pushed branch.

| Id | Request | The run must show |
|---|---|---|
| A | Add per-key TTLs (`--ttl`), an LRU cap (`--max-keys`), and persisted hit/miss/eviction/expiration stats; tests must not sleep | a spec whose criteria each name a check; verify passing in a clean checkout; 11/11 hidden acceptance |
| B | Add CSV import and export, key validation, and a history command | a task graph with independent tasks dispatched to implementers in parallel; 7/7 hidden acceptance |
| C | A, with a branch and PR title named, CI that runs the repository's workflow, and a commit landing on origin's main mid-run | `checks` taken from the repository's rules files; `deliver` refusing the moved origin, then `sync`, verify, deliver; CI passing |
| D | A, with no branch or title named; CONTRIBUTING.md sets branch and title rules, a PR template, and a changelog entry; a reviewer requests a change after delivery | `set` before delivering; `pr.md` following the template; the review item shown once, fixed or answered, and the run ending on the next `feedback` |
| E | D without a PR template | `pr.md` in the bundled visual-pr format |

The method is written for both Claude Opus 5.5 and Claude Sonnet 5.5 as the lead;
record which one led each run.

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
| 2026-10-04 | `cd25cf2` | cycle, autonomous; request A plus a branch and PR title; a stand-in `gh` whose CI runs the repo's workflow steps on the pushed branch; a teammate commit lands on origin main mid-run (C) | Sonnet 5.5, medium; all agents Sonnet | Branch and title passed from the request. `checks` taken from CLAUDE.md. Reviewer and simplifier dispatched together. `deliver` refused the moved origin; `sync` merged it; verify and deliver again; CI passed first round. The lead first wrote code into the user's checkout through relative paths, noticed, and moved it; fixed in `629c5e0` (work in `work`) | completed, CI passed; pushed branch passes hidden acceptance 11/11 |
| 2026-10-04 | `629c5e0` | C, plus a CI-only changelog rule | Sonnet 5.5, medium; all agents Sonnet | The lead stayed in `work`; the user's checkout stayed clean. It read the workflow and wrote a changelog entry up front, so CI passed first round. Relative spec and plan paths landed one directory too high (fixed: absolute paths in `next`) | completed, CI passed; 11/11 |
| 2026-10-04 | `6a1044b` | C, plus a hidden org-policy CI rule (an SPDX header on every changed Python file) | Sonnet 5.5, medium; all agents Sonnet | The full loop: `deliver` refused the moved origin, `sync`, verify, deliver; `ci` round 1 failed with the policy log; the lead judged the change caused it, added the headers, verified, delivered, and `ci` round 2 passed. The Stop hook fired three times and let each stop through (twice `LOOP_SPEC_WAITING`, once after the result) | completed, CI passed after one fix round; 11/11 |
| 2026-10-04 | `b7b9f1c` | request A with no branch or title named; CONTRIBUTING.md requires `kv/<topic>` branches, `[KV]` titles, a PR template, and a changelog entry; after delivery a reviewer requests a change and asks a design question (D) | Sonnet 5.5, medium; all agents Sonnet | The lead read CONTRIBUTING.md and ran `set --branch kv/key-expiry --title "[KV] ..."` before delivering, wrote `pr.md` to the template, and added the changelog line. `feedback` showed the change request and the question once; the lead added the `total` line, answered the question with `deliver --comment-file`, and the next `feedback` found nothing new and ended the run. The Stop hook let three stops through (twice `LOOP_SPEC_WAITING`, once after the result) | completed, CI passed, `reviews: {ana: CHANGES_REQUESTED}` awaiting re-review; 11/11 |
| 2026-10-04 | `80c7715` | D without a PR template (E) | Sonnet 5.5, medium; all agents Sonnet | With no repository template, `status` pointed `pr.md` at the bundled visual-pr format; the lead wrote a one-sentence why, three reviewer notes, and a change outline (a file-format diff, an operations sketch, a file tree), and deliver folded the criteria below it. Branch, title, and review handling as in D | completed, CI passed |
| 2026-10-04 | `2b449d8` | D, checking the phase stream | Sonnet 5.5, medium; all agents Sonnet | 151 s, $0.66. `events.jsonl` held SPEC, PLAN, EXECUTE, VERIFY, ITERATE, and DELIVER in order with 7.x's fields, then the review round as `deliver` rewind, `iterate`, `deliver`, and `completed`. The lead piped some commands through `grep` and `tail`, which hid markers from its own transcript but not from the file. The fix was committed and verified in one step, so the rewind skipped VERIFY; `verify` now syncs the stream first | completed, CI passed |

For comparison, 7.9.0 on request A with the same model settings (`--answer-policy default`,
every role on Sonnet) took 1108 s, 237 tool calls, and 26 worker dispatches, and
reported $6.13 against 8.0's $0.41. Its spec included a criterion that no file
contain the word `sleep`; a test comment ("instead of sleeping") kept failing it, VERIFY
routed the run back twice, and the recurrence guard ended it `escalated` with no
verified head. Its code also passed the hidden acceptance check, 11/11.
