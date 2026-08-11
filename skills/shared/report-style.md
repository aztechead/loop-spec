# Report style (shared contract)

How loop-spec talks while it works. Two audiences, two rules: a GREPPABLE one-line
record at every phase boundary for the unattended operator, and action-first prose for
the human reading a report. Verbosity is not thoroughness — the artifacts carry the
detail; the console carries the signal.

## Phase-boundary lines (machine-greppable) — emitted for you

**`lib/events.sh` prints these. You do not have to.** Every `events.sh emit` call
writes one `[PHASE] ...` line to **stderr** in addition to its durable JSONL record,
so the whole lifecycle is greppable from a streamed log:

```text
[SPEC] start
[DISCUSS] gate critique round 2 - escalated
[PLAN] dispatch planner [inherit, team]
[EXECUTE] DAG width W=2 -> rung: subagent (teams unavailable: no TeamCreate)
[VERIFY] FAILURE: code-review
[ITERATE] verdict: converged
[DELIVER] waiting on required checks (120s/900s elapsed, 3 pass, 1 pending, 0 failed of 4)
[DELIVER] done (115s) - completed -> completed
```

This used to be an instruction to *you* to print such lines. That made the only window
into a long unattended run depend on model compliance, with no test — and in practice
only EXECUTE and DISCUSS ever printed them, while gate rounds, dispatches and verify
failures reached no console at all. It is a mechanism now, pinned by
`tests/lib/events.test.sh` case P.

What this means in practice:

- **Emit the event and the line follows.** The observability you owe an operator is
  discharged by calling `events.sh emit` at the right moments — not by writing console
  prose. A missing boundary line is now a missing *event*, which is a real bug.
- **stdout is unchanged.** `LOOP_SPEC_PHASE_START` / `LOOP_SPEC_PHASE_END` plus their
  JSON still go to stdout for machine consumers; the human line goes to stderr. Both
  land in a streamed log.
- **`LOOP_SPEC_CONSOLE_STREAM=stdout`** moves the console lines to stdout for hosts
  that grade the two streams differently — Cloud Run assigns stderr output ERROR
  severity, so routine progress otherwise shows up in Cloud Logging as errors. It is
  opt-in because it is contract-affecting: with two lines on stdout, a consumer must
  select its record by prefix (`grep '^LOOP_SPEC_PHASE_'`) rather than pipe the whole
  stream to `jq`. `lib/pr-delivery.sh`'s heartbeat deliberately ignores this setting —
  its stdout is a single JSON document parsed whole by its caller, not a marker stream.
- **Kill switch:** `LOOP_SPEC_CONSOLE_EVENTS=0` silences the console lines without
  touching the JSONL ledger.
- **Still write prose the mechanism cannot know**, such as EXECUTE's rung-decision
  line: a domain-specific detail with no corresponding event. Use the same
  `[PHASE] ...` shape so it greps alongside the rest. Scores in percentages, never
  bare decimals.

## Report prose (action-first)

For every report returned to a human (phase summaries, completion reports, escalations):

- **Lead with the outcome or the next action** — first line answers "what happened" or
  "what do I do now", never background.
- **Restate state when returning control**: one line naming the feature, current phase,
  and what the loop is waiting on. The reader may have been away for an hour.
- **Mark wins visibly**: completed criteria/tasks get an explicit ✅; a list of done
  work is evidence, not decoration.
- **Numbered steps for anything the user must do** — commands first, rationale after.
- **Matter-of-fact errors**: state what failed, the evidence, and the route — no
  hedging, no apology, no "unfortunately".
- **No preamble, no closers**: never "Great!", "Let me...", "Hope this helps", and no
  restating the request back.
- **Cap lists at the load-bearing few** (~5 items); the rest belongs in the committed
  artifact, linked, not inlined.
- **No self-authored deferrals** — a report never invents "next steps" or "follow-ups"
  (`skills/shared/no-deferral.md`); the only forward pointer a completion report may
  carry is the deterministic one (e.g. `/loop-spec:revise <pr>` after changesRequested).
