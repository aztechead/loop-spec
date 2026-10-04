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
| 2026-10-04 | `2b449d8` | E, checking the phase stream | Sonnet 5.5, medium; all agents Sonnet | 151 s, $0.66. `events.jsonl` held SPEC, PLAN, EXECUTE, VERIFY, ITERATE, and DELIVER in order with 7.x's fields, then the review round as `deliver` rewind, `iterate`, `deliver`, and `completed`. The lead piped some commands through `grep` and `tail`, which hid markers from its own transcript but not from the file. The fix was committed and verified in one step, so the rewind skipped VERIFY; `verify` now syncs the stream first | completed, CI passed |
| 2026-10-04 | `9699c8e` | E, after the split into an overview and per-phase references | Sonnet 5.5, medium; agents per frontmatter | 209 s, $0.98. Read `SKILL.md` at the start, then `spec.md`, `plan.md`, `execute.md`, `review.md`, and `deliver.md` each as its phase began. Read the visual-pr template for `pr.md`, but not `show-me.md`, its outline's views. Branch and title from CONTRIBUTING.md; a review fix after verify and the change request after delivery each rewound to VERIFY; the reply comment answered the design question | completed, CI passed; 11/11 |
| 2026-10-04 | `9699c8e` | same as above | Opus 5.5, medium; agents per frontmatter | 339 s, $1.91. The same reads, except the visual-pr template: it wrote the format's sections from SKILL.md's summary. Neither run opened `show-me.md`; the `next` line names both since `ab85a70`. Split the work into two implementers. Same phase stream and rewinds; a longer, structured reply to the design question | completed, CI passed; 11/11 |
| 2026-10-04 | `ab85a70` | E, after spec.json checks and the deliver guides | Sonnet 5.5, medium; agents per frontmatter | 210 s, $0.95. Spec and plan passed the new checks first time. Read each phase's reference as before; at DELIVER the `next` line named `deliver.md`, the visual-pr template, and `show-me.md`. The lead had already read the template and did not open `show-me.md`, yet its change outline used show-me's views (a changed-file tree and pseudocode). `pr.md` had no placeholder lines left | completed, CI passed; 11/11 |
| 2026-10-04 | `fa01fa8` | A, interactive, in Docker through `examples/sdk-plugin` with questions answered on stdin; a private GitHub repository with real Actions CI (ruff, pytest, an SPDX policy script, a changelog job), CONTRIBUTING.md branch and title rules, a PR template; a teammate's CHANGELOG commit lands on origin main mid-run; an inline change request and a question posted from the same account that ran it | Sonnet 5.5; agents per frontmatter | 190 s, $0.65. Asked only for spec approval. Did the one task itself instead of dispatching an implementer. `deliver` refused the moved origin; `sync` merged the CHANGELOG conflict keeping both lines. `feedback` ended the run on green CI without showing the two review comments: it skipped every item the gh account wrote. Fixed in `6dcba1a` | completed, CI passed, comments unanswered; hidden acceptance 13/13 |
| 2026-10-04 | `fa01fa8` | same as above, without the review comments | Opus 5.5; agents per frontmatter | 480 s, $2.00. Asked two design questions (is the cap saved; what counts as an expiration) and for approval of 11 criteria. Dispatched two Sonnet implementers; the Opus reviewer found a missed expiration count, fixed. Synced the moved origin as above | completed, CI passed; 13/13 |
| 2026-10-04 | `6dcba1a` | round 1 again, comments posted as soon as the PR opened | Sonnet 5.5; agents per frontmatter | 170 s, $0.57. Wrote the code in `work` before any spec, skipped the interactive approval, then backfilled `spec.json` and `plan.json` and moved the code into T-1 through a side branch (fixed in `feb56ef`: no code before the plan, and the approval named in the `next` line). `feedback` showed both comments; the lead added `kv stats --reset` with tests and answered the question with `deliver --comment-file`. The run ended 24 s after redelivery, before the reviewer could look again (fixed in `feb56ef`: `deliver` re-requests review from feedback authors, and `feedback` waits for requested reviews) | completed, CI passed; 13/13 |
| 2026-10-04 | `6dcba1a` | same, plus a slow CI job pushed to origin main mid-run | Opus 5.5; agents per frontmatter | 1,040 s (about 5 min of it waiting on answers, 4 min on CI), $2.32. Two design questions and approval. Two Sonnet implementers. `deliver` refused the moved origin; after `sync` it added the new job's smoke command to `checks`. For the change request it added AC-8 and a T-3 task rather than a bare commit, and checked its answer with the real binary on a 0.1.0 file before replying | completed, CI passed (4 jobs); 13/13 |
| 2026-10-04 | `feb56ef` | cycle, autonomous; kvstore CSV export/import, key validation, `kv history` (a three-part request); CI adds a 2-minute integration job and an organization docstring policy from a private action repository; a real review comment (export writes legacy keys import rejects) posted while CI runs | Sonnet 5.5; agents per frontmatter | 480 s, $0.76. Spec, then plan, then one Sonnet implementer for one task (the r2 shortcut did not recur). Added docstrings after reading the workflow, so the policy passed. `feedback` showed the review comment; the lead made export fail naming the keys, with a test, and replied | completed, CI passed (5 jobs); hidden acceptance 12/12 |
| 2026-10-04 | `feb56ef` | same | Opus 5.5; agents per frontmatter | 580 s, $1.56. Two Sonnet implementers (store, then CLI), reviewer and simplifier. Chose to skip invalid legacy keys on export with a warning, and said why in its reply | completed, CI passed (5 jobs); 12/12 |
| 2026-10-04 | `feb56ef` | revise, autonomous, on the PR above; a new change request (delete clears history) and a question (does import record history) | Sonnet 5.5; agents per frontmatter | 220 s, $0.51. Judged the earlier comment already answered, made one criterion per new comment. `deliver` pushed, then failed reading `pr.md`, which a revise run does not write; the lead wrote a stub and delivered again. The first `feedback` listed the three comments the run started from as new; the lead ran it again (both fixed in this commit) | completed, CI passed |
| 2026-10-04 | `feb56ef` | same | Opus 5.5; agents per frontmatter | 250 s, $0.90. The same two defects and the same workarounds | completed, CI passed |

For comparison, 7.9.0 on request A with the same model settings (`--answer-policy default`,
every role on Sonnet) took 1108 s, 237 tool calls, and 26 worker dispatches, and
reported $6.13 against 8.0's $0.41. Its spec included a criterion that no file
contain the word `sleep`; a test comment ("instead of sleeping") kept failing it, VERIFY
routed the run back twice, and the recurrence guard ended it `escalated` with no
verified head. Its code also passed the hidden acceptance check, 11/11.

## Trigger checks

Whether a plain request, with no slash command, picks the right entry skill from its
description alone: `claude -p "<request>"` in a clone of the scenario repository,
stopped after two turns, recording the `Skill` call.

| Date | Commit | Requests | Sonnet 5.5 | Opus 5.5 |
|---|---|---|---|---|
| 2026-10-04 | `1f68429` | a feature with tests and a PR (cycle); a one-line message change (micro); a traceback (debug); "address the review comments on PR #7" (revise); explain a function, change nothing (none) | 4/5: the message change ran without `micro` | 5/5 |
| 2026-10-04 | `3805ec4` | the message change (micro) and the explain request (none), three tries each, after `micro`'s description named small changes and "even if they never mention loop-spec or a PR" | 6/6 | 6/6 |
