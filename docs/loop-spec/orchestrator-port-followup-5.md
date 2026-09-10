# Orchestrator port: fifth audit, at ccaf910

For the agent driving PR 94. This audits the one code commit after d17da82 (ccaf910,
"the driver observes what the lead used to assert") against the fourth follow-up, with
the three-runs-per-task reading that follow-up asked for. Every item landed and the
offline suite is green. The live reading regressed, and the cause is one defect chain
that the landing record could not have seen without a run.

## Verdict

At d17da82 the bug fix cost 0.42 USD with zero REDO rounds. At ccaf910, three runs of
the same task cost 0.47, 1.97, and 0.84 USD, with 12, 8, and 3 REDO rounds, and one of
them left the short route for the full seven-phase route. The feature task went 2.33,
1.41, and 1.07 USD, with one run on the full route and two undelivered. The bet is not
won at this head, and d17da82 remains the best head measured.

| run | cost USD | minutes | turns | rounds | artifact lines | REDO | delivered | checks | route |
|---|---|---|---|---|---|---|---|---|---|
| bar, bug fix | 0.25 | 3 | | 1 | 50 | 0 | yes | | short |
| d17da82, bug fix | 0.42 | 3.5 | 47 | 1 | 68 | 0 | yes | 2 of 2 | short |
| ccaf910 run 1 | 0.47 | 4.5 | 49 | 1 | 71 | 12 | yes | 2 of 2 | short |
| ccaf910 run 2 | 1.97 | 17.8 | 137 | 7 | 352 | 8 | yes | 2 of 2 | escalated to full |
| ccaf910 run 3 | 0.84 | 5.3 | 53 | 1 | 71 | 3 | yes | 2 of 2 | short |
| bar, feature | 0.60 | 5 | | 1 | 100 | 0 | yes | | short |
| d17da82, feature | 0.55 | 5.4 | 57 | 1 | 91 | 0 | yes | 3 of 4 | short |
| ccaf910 run 1 | 2.33 | 23.0 | 181 | 7 | 387 | 4 | yes | 4 of 4 | escalated to full |
| ccaf910 run 2 | 1.41 | 14.1 | 124 | 3 | 38 | 5 | no, no result | 3 of 4 | escalated, stopped in PLAN |
| ccaf910 run 3 | 1.07 | 8.9 | 90 | 1 | 38 | 0 | no | 4 of 4 | short, reviewer failed 3 times |

The code was correct in every run that produced code. The first-turn context was
29,800 input tokens on all six runs, a fixed cost the new record field now makes
visible.

## The defect chain

Read in the order it fired on run 1 of the bug fix.

1. **The lead typed the criterion without a command.** `spec fill --json -` wrote the
   Good Enough line as `python3 -m unittest discover -s tests exits 0: all four test
   cases pass`, no backticks. The oneshot skeleton's placeholder does not require a
   backticked command, and nothing in `skills/spec-lite/SKILL.md` makes the command a
   separate field. A criterion is a sentence the lead composes, and the driver then
   searches that sentence for a command.
2. **The driver could not run it and stopped.** `verification_run` in `lib/graph/driver.py`
   raises when the first Good Enough line carries no backticked span. The boundary
   swallows the error, the Status cell stays empty, and `lib/converged-floor.sh` vetoes.
   That is the REDO the lead saw: "criterion GE-001 carries no backticked command to
   run". Six times on run 1.
3. **The lead fixed the criterion and the fix did not replace it.** `spec_fill` appends
   a `--criterion` line after the first fill; only the placeholder is replaced. The spec
   then held GE-001 without backticks and GE-002 with them, and the driver kept failing
   on GE-001. One lead reported this in its own words: "spec fill added duplicate
   criterion instead of updating existing one; ONESHOT cannot resolve".
4. **The lead escalated, because escalation was the only exit.** `spec escalate --reason`
   is a command the lead may call. Three of six runs called it, and the reasons are all
   this chain: "criterion format needs backticks for verification run to parse",
   "success criteria lack backticked commands", and "footprint includes the test module
   but no changes needed". Escalation writes `route: full` and the run pays for DISCUSS,
   PLAN, EXECUTE, VERIFY, and ITERATE on a two-line fix: seven rounds, 352 lines, 1.97
   USD.
5. **On the full route the re-entry defect came back.** Feature run 2 entered DISCUSS
   twice and PLAN twice and then returned no result at all, so the eval stopped it. The
   short route's one-session fix did not cover the full route's handoffs.
6. **The driver-launched reviewer failed three times and the run gave up.** Feature run
   3 hit `FLAG [review] the driver-launched reviewer session ended failed` on three
   consecutive returns, then the lead declined and the record reads phase `micro`,
   status failed, with four of four checks passing on the working tree and nothing
   delivered. The feature directory was removed by the run's end, so the reviewer's
   stderr is gone with it. The driver keeps no durable log of the session it launched.

Every step is deterministic code behaving as written. The chain is a design fault: the
driver was made to observe, but the thing it observes is still a sentence the lead
composes, and the one command the lead had left for an unresolvable state was the
expensive one.

## Scorecard

| item | state | note |
|---|---|---|
| 1 read-only from the task | done | Protected list from the invocation; test module added by construction. A source file with no existing test module still adds nothing, and the footprint pass skips silently when the feature root cannot be resolved. |
| 2 the table can say FAIL | done, and it caused the chain | The status is observed. The command it observes is the lead's sentence. |
| 3 review section from the report | done | `none` when empty; verdicts per finding. |
| 4 empty blocks flagged | done | Boundary run before the exit gate; lint on empty fences. |
| N1 remaining writers | done, one inversion | The path hook now fails closed on an unreadable spec. The forgery guard still exits 0 on the same unreadable spec, so the shell path opens where the Write path closed. |
| 5 batch fill and tokens | done | One new variable, `LOOP_SPEC_FOOTPRINT_ROOT`. |
| pins | done | Drop order, N3 edge, `bar.rounds`, state-ref on a delivered branch. |

Offline: 235 suites pass at ccaf910. The path is 600 of 600. The changelog still cites
live run 4 as 0.41 USD, 3.8 minutes, 74 lines, and 39 turns, which is not this
document's d17da82 row; one of the two is not the record.

## Required work, in order

### R1. A criterion is two fields, never a sentence the driver parses

`spec fill --criterion` takes `--command <shell>` and `--expect <text>`, writes the
line as `` - [ ] `<command>` exits 0: <expect> ``, and refuses a criterion without a
command. The skeleton's placeholder shows the two fields. `verification_run` reads the
command from the frontmatter or a fenced block the driver wrote, never from prose.
Done when: `tests/lib/cycle-driver.test.sh` refuses a criterion with no command, and
`lib/artifact-lint.sh` flags a Good Enough line with no backticked span at SPEC exit,
before the oneshot boundary can ever see one.

### R2. Fill replaces by id

`spec fill --criterion --row GE-001` replaces the row; a fill with no row appends only
when no criterion exists. Same for grounding rows. Done when: the driver test fills
GE-001 twice and the spec holds one criterion.

### R3. The lead cannot escalate

Remove `spec escalate` from the lead's reach on the short route. Escalation is a gate's
decision from evidence: a diff outside the footprint, a reviewer BLOCK, or a REDO
count at `LOOP_SPEC_REDO_MAX`. When the count is reached, the driver escalates with
the flag classes as the reason, so a full-route run always names the deadlock that
sent it there. Done when: no transcript of a short-route run contains a lead-issued
escalate, and the driver test escalates on the third identical REDO.

### R4. A test module the change does not need is a decision, not a deadlock

The by-construction test module is right, and the feature task needs a test. For a
task that does not, the drop ruling exists. The spec-lite skill must say so in the
line that shows the footprint, and the drop must be one call. Done when: a run that
drops the test module records the ruling and delivers, and the feature fixture, whose
task carries no protected test, adds a test in three of three runs.

### R5. The full route's re-entry

Feature run 2's DISCUSS-twice, PLAN-twice, then no result. The one-phase rule holds; the
lead is re-invoked into a phase it already handed off from, and the second entry finds
nothing to do. Reproduce it with the eval's round loop on the full route before
fixing. Done when: a full-route run on `todo-due` enters each phase once.

### R6. The reviewer session leaves a log

`cmd_oneshot` writes the reviewer session's stdout and stderr to
`<featureDir>/dispatch/oneshot.reviewer.log` and the REDO message names the last
line. The feature directory is not removed on decline; the result pointer is. Done
when: a failed reviewer session's reason is readable after the run ends.

### R7. Close the forgery guard's inversion

`hooks/team/result-forgery-guard.sh` returns allow on an unreadable spec while
`hooks/restrict-agent-paths.sh` denies. Both deny. Done when: the forgery guard's test
has the unreadable-spec case.

## The reading rule

Three runs per task, haiku, after R1 through R3. If the bug fix is at or under 0.25
USD on two of three, the bet is won. If all three land between 0.25 and 0.35 with zero
REDO and one round, say so and let the maintainer decide whether the bar or the route
moves. If any run leaves the short route, the reading does not count and the reason
is the next follow-up's first item.

## Reproduce

```bash
for n in 1 2 3; do
  LOOP_SPEC_EVAL_LIVE=1 bash evals/run.sh --model haiku --tasks slugify-bug,wc-json \
      --parallel 2 --run-id port5-haiku-$n --confirm-spend
done
```

The six runs cost 8.10 USD together. `bash tests/run-all.sh` at ccaf910: 235 suites
passed, 0 failed.

## Landing record

For the reviewer of PR 94. What each item became on the branch, in the audit's order.
Offline evidence is `bash tests/run-all.sh` (235 suites). The commit before this one
(799650f) had already closed the first three links of the chain from this branch's own
six-run reading: the bare criterion refused, the duplicate not appended, the Claude
profile's variadic flag moved off the prompt, a failed reviewer session handed to the
lead once, `decline` refused past begin.

| item | state | evidence |
|---|---|---|
| R1 | done | `spec fill --command <shell> --expect <text>` writes `` - [ ] `<command>` exits 0: <expect> `` and the command into the frontmatter `criteria:` map; `verification run` reads that map, never the sentence; a sentence is refused; `lib/oneshot-spec-lint.sh` flags a bare Good Enough line at SPEC's exit. Pinned in the driver and gate suites. |
| R2 | done | `--row GE-NNN` replaces the criterion (and the map entry); `--row N` replaces a grounding bullet; no row appends the next one; a repeat is never appended. The driver test fills GE-001 twice and the spec holds one criterion. |
| R3 | done | `spec escalate` is refused (exit 2). The third identical REDO on ONESHOT writes `route: full` with the flag classes as the reason, sets the attempt's VERIFICATION.md aside as `VERIFICATION.oneshot-attempt.md`, emits an `escalate` event, re-runs the exit, and hands the run to DISCUSS; other phases keep the terminal escalation. Pinned: two REDOs, then the NOTE, the frontmatter, the event, `HANDOFF next=discuss`. The two skills say the lead never escalates. |
| R4 | done | `skills/spec-lite/SKILL.md` names the one drop call in the line that shows the footprint, and says it is refused while the tested file changes. The live done condition (three of three feature runs add a test) is the reading's. |
| R5 | done offline, live open | A fresh session whose `next` finds a handoff record naming the current phase answers `NEXT` from the record, consumes the record, and steps the graph again only when the phase returns; pinned with one `phase_start` for DISCUSS. The live reproduction on `todo-due` the audit asks for is a full-route run and is not in this reading. |
| R6 | done | `cmd_oneshot` appends the session's stdout and stderr to `dispatch/oneshot.reviewer.log`; the REDO quotes stderr's last line and names the log. `decline` refuses past begin (799650f), so nothing removes the feature directory on that path. |
| R7 | done | `hooks/team/result-forgery-guard.sh` opens the shell path only on a readable `route=full`, the path hook's rule; the unreadable-spec case is in its suite. |
| the run-4 figures | recorded | Both are records: this branch's own run on d17da82 (0.41 USD, 3.8 minutes, 74 lines, 39 turns) and the auditor's on the same head (0.42, 3.5, 68, 47). The changelog names both. |
