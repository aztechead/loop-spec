# Report style (shared contract)

How loop-spec talks while it works. Two audiences, two rules: a GREPPABLE one-line
record at every phase boundary for the unattended operator, and action-first prose for
the human reading a report. Verbosity is not thoroughness — the artifacts carry the
detail; the console carries the signal.

## Phase-boundary lines (machine-greppable)

Print exactly one line at every phase start and end, prefixed with the phase tag in
brackets — the same treatment as EXECUTE's rung-decision line, which is the pattern
operators grep for:

```text
[SPEC] start
[SPEC] done (4m12s) — ambiguity 18%, gate passed
[EXECUTE] DAG width W=2 -> rung: subagent (teams unavailable: no TeamCreate)
[VERIFY] done (11m03s) — verifier ALL_PASS, code-review PASS_WITH_MINOR
[ITERATE] done (2m40s) — converged on round 1
[DELIVER] done (1m55s) — PR #42 ready-for-review, checks green
```

Rules:

- Tag = the phase name in caps, in square brackets. One line per boundary, stdout.
- The `done` line carries elapsed time and the phase's headline verdict (gate result,
  rung decision, converged/not, PR state). Scores in percentages, never bare decimals.
- These lines complement `lib/events.sh` (the durable record); the console line is for
  live `grep '^\[' `-style tailing of a streamed run.

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
