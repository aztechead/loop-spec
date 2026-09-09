# Orchestrator port: fourth audit, at d17da82

For the agent driving PR 94. This audits the nine commits after b5008b4 (44c6288
through d17da82, version 6.5.0) against the third follow-up's N1 to N7 and a fresh live
run on the new head. The landing record you appended to
`docs/loop-spec/orchestrator-port-followup-3.md` said the next live run was the
evidence. This is that run.

## Verdict

The short route now works the way the plan described. Both fixtures delivered in one
session with zero REDO rounds. The feature task met the cost and artifact bars and
missed the time bar by 24 seconds. The bug fix is within 1.7 times the cost bar, down
from 5 times at dda2cca. The remaining gap is small, specific, and the same defect
class each time: a value the model asserts where the driver should observe.

| run | cost USD | minutes | turns | rounds | artifact lines | REDO | delivered | checks |
|---|---|---|---|---|---|---|---|---|
| bar, bug fix | 0.25 | 3 | | 1 | 50 | 0 | yes | |
| BMad, bug fix | 0.23 | 1.8 | 26 | 1 | 43 | | local commit | 2 of 2 |
| dda2cca | 1.26 | 9.5 | 117 | 2 | 119 | 6 | pushed | 2 of 2 |
| b5008b4 | 0.62 | 6.2 | 55 | 2 | 83 | 5 | pushed | 2 of 2 |
| **d17da82** | **0.42** | **3.5** | 47 | 1 | 68 | 0 | pushed | 2 of 2 |
| bar, feature | 0.60 | 5 | | 1 | 100 | 0 | yes | |
| BMad, feature | 0.35 | 2.8 | 34 | 1 | 56 | | local commit | 4 of 4 |
| f0959f6 | 2.48 | 20.4 | 207 | 4 | 127 | | pushed | 4 of 4 |
| b5008b4 | 0.87 | 8.3 | 78 | 2 | 145 | 3 | pushed | 3 of 4 |
| **d17da82** | **0.55** | **5.4** | 57 | 1 | 91 | 0 | pushed | 3 of 4 |

Against BMad, loop-spec's short route is now within twice the cost on both tasks, and
it pushes and reconciles a PR where BMad stops at a local commit. Sample size is one
run per cell. Three runs per task before the final reading.

Code quality: the bug fix is the same correct two lines, this time with the neighbors'
double quotes. The feature is correct and, for the fifth time, has no test.

## Scorecard

| item | state | note |
|---|---|---|
| N1 lead never writes a shape | partial | Fill commands exist and re-lint on each write; the path deny works for Write and Edit; the eval records REDO by class. Three writers remain: `spec write --file` copies any file over the spec with no route check; a shell redirect, `sed -i`, or `python3 -c` is not a Write; and the deny returns allow on every uncertainty. |
| N2 footprint promise | done, one order hole | The prose exit is gone and the drop is a ruling. Dropping the source file first and its test module second is accepted. |
| N3 DELIVER in session | done | `rounds: 1` on both runs. The "no other edge" pin excludes every edge into deliver instead of every edge not from oneshot. |
| N4 path bound | done, zero headroom | The path is 600 of 600. The next added line turns the suite red. |
| N5 fail-opens | done | Dispatch event withheld unless the reviewer completed and wrote its report. Stamp guard denies the open-phase state. |
| N6 plugin repo | done | Two on-disk probes, exit 3. The suite refuses a foreign active worktree. |
| N7 pins | partial | Duplicate-pair pinned without a reproduced fix. Bar pinned to the plan, but `rounds` is not in task.json. The state-ref test is unchanged; two cycle-driver checks cover the intent. PR 93's additions recorded. |

Principles held this round: no new variable, no new guard, cycle skill 231 to 176,
loaded path 1,387 to 600. One guard-describing line entered the oneshot skill.

## What the live run showed that the audit did not

### 1. The test module became read-only by the lead's say-so

The feature spec's footprint lists `wc_tool.py` alone, and Implementation notes says
`tests/test_wc_tool.py: read-only; the change does not touch it.` N2's refusal never
fired because the test module was never in the footprint. The read-only marking is
written by the lead, so the promise now has a new prose exit one line earlier.

Fix, deterministic: read-only is a fact from the task, never from the lead. The
driver's footprint list marks a file read-only only when the task's protected list
names it. A changed source file's existing test module is in the footprint by
construction, added by the driver at skeleton time from the test-module rule
`lib/oneshot-spec-lint.sh` already applies, and leaves only through the drop ruling.
Done when: the feature run adds a test or refuses to deliver, and
`tests/lib/oneshot-exit-gate.test.sh` has the case where the lead writes read-only
against a file the task does not protect.

### 2. The acceptance table cannot say FAIL

The audit found it in code and the run shows it in the artifact:
`render_skeleton` writes `PASS` into every Status cell, and `verification fill` matches
only a `PASS` row. `lib/converged-floor.sh` reads its verdict from that column. On
this run the test did pass, so nothing was wrong. On a run where it does not, the
floor reads a value the driver wrote before anyone ran anything. That is the
self-graded ambiguity gate again, one layer down.

Fix: `verification run --row <id>` runs the criterion's verify command from the spec,
records the exit code as the status, and writes the output block. The lead never
supplies a status. The skeleton's Status cell is empty until the driver fills it, and
`artifact-lint` flags an empty Status cell at exit. Done when: a fixture whose verify
command fails produces a FAIL row and the floor refuses convergence, in
`tests/lib/converged-floor.test.sh`.

### 3. The review section is theater when there is nothing to review

The bug fix's Code review section reads `slugify.py:1 — no style or correctness issues
found | verdict: true`. That is not a finding. The triage lint demands a location and a
verdict per bullet, so the lead invented one to satisfy the shape. The lint accepts
`none`; the skill should say so, and the driver should write the review section from
the reviewer's report file instead of the lead transcribing it. Done when: a reviewer
report with no findings renders as `none` and the lint passes.

### 4. Two skeleton blocks were never filled and nothing flagged it

The bug fix's `## Final test suite` block is an empty fence. `artifact-lint` did not
flag it. Fix: the driver runs `commands.test` at the oneshot exit and writes that
block itself, and `artifact-lint` flags any empty fenced block in VERIFICATION.md.

### 5. Where the last 0.17 USD sits

47 turns for two lines. Each `spec fill` and `verification fill` is one Bash turn, and
each turn re-reads the context. Two levers, both driver-side:

- Batch fills: `spec fill` accepts every field in one call from a JSON on stdin, and
  `verification run` fills the whole table in one call. Target under 25 turns.
- Measure tokens, not lines: the landing record measured 30k input tokens at the first
  turn. Add `first_turn_input_tokens` to the eval record, from the round's usage, and
  bound it. The line probe has no headroom left; the token number is what the bill
  reads.

## Required work, in order

1. Items 1 and 2 above. Both are the same rule: the driver observes, the lead never
   asserts. Both have a fixture-level done condition.
2. Items 3 and 4.
3. N1's three remaining writers: route-check `spec write --file`, extend the deny to
   Bash writes into the two files by path match in `hooks/team/result-forgery-guard.sh`
   or a sibling, and make the deny fail closed when the feature dir is known.
4. Item 5, then the N2 order hole, the N3 pin scope, `rounds` in task.json, and the
   state-ref test as asked.
5. Then three runs per task, haiku, and the final reading. If the bug fix lands at or
   under 0.25 USD on two of three, the bet is won. If it lands between 0.25 and 0.35 on
   all three with zero REDO and one round, say so and let the maintainer decide whether
   the bar or the route moves.

## Reproduce

```bash
LOOP_SPEC_EVAL_LIVE=1 bash evals/run.sh --model haiku --tasks slugify-bug,wc-json \
    --parallel 2 --run-id port4-haiku --confirm-spend
```

The two runs cost 0.97 USD together. `bash tests/run-all.sh` at d17da82: 235 suites
passed, 0 failed.

## Landing record

For the reviewer of PR 94. What each item above became on the branch, in the audit's
order. Offline evidence is `bash tests/run-all.sh`. The live reading the audit asks for
(three runs per task) follows this record and is reported in the eval results.

| item | state | evidence |
|---|---|---|
| 1 read-only from the task | done | `protected:a,b` is an invocation token (`lib/parse-invocation.sh`), carried by `start` and `init` into `feature.json.protected` (declared in `graph/schema.json`). `lib/footprint.sh list` honors `--read-only` only for a protected file, says so on stderr otherwise, and adds a cited source file's existing test module by construction, protected ones read-only; the probe and the skeleton read the same list. The eval passes each task's protected list. Pinned in the footprint, probe, and driver suites; the exit gate's untouched-file flag already ignores what the notes say. |
| 2 the acceptance table can say FAIL | done | The oneshot skeleton's Status cells are empty (`VERIFICATION-oneshot.md.template`, `render_skeleton`); `verification run` executes each criterion's command and writes PASS or FAIL from its exit, the evidence, and the output block; `artifact-lint` flags an empty Status cell; the floor vetoes an empty cell and a driver-written FAIL row (`tests/lib/converged-floor.test.sh`); the driver suite runs a passing and a failing criterion. |
| 3 the review section | done | `verification review --report` writes the section from the reviewer's report, `none` when it holds no finding, and the reviewer's verdict on the Reviewer line; the boundary review does it after the driver's own session; `verification verdict` records the lead's answer per finding; `--review TEXT` is gone from `fill`. |
| 4 empty blocks | done | `next --returned-from oneshot` runs `verification run` (criteria and `commands.test`) before the exit gate; `artifact-lint` flags an empty fenced block. |
| N1's three writers | done | `spec write --file` refuses over the oneshot skeleton; `hooks/team/result-forgery-guard.sh` denies `>`, `tee`, `cp`, `sed -i`, and a Python open for writing aimed at a oneshot feature's SPEC.md or VERIFICATION.md; the path hook's deny opens the file only on a readable `route=full` and fails closed on an unreadable spec. |
| 5 turns and tokens | done | `spec fill --json -` fills the whole spec in one call; `verification run` fills the whole table and the test block in one call; the eval record carries `first_turn_input_tokens` from the CLI's transcript of the session and the summary prints it. No bound on the token figure yet: the plan names none, and one measured value is not a bar. |
| N2 order hole | done | A test module of a file that changed in the diff cannot be dropped, whatever the footprint says now. |
| N3 pin | done | The "no other edge" pin excludes only `oneshot` to `deliver`. |
| `rounds` in task.json | done | Both tasks carry `bar.rounds: 1`; the verdict and the coverage check read it. |
| state-ref test | done | `tests/lib/state-ref.test.sh` drives a feature through `begin`, the fills, and the spec exit, and counts the branch: the artifact commit, no state commit, the ref holding the state. |
| N4 headroom | at the bound | The path is 600 of 600 again after the oneshot skill lost the guard-describing sentence the audit named and gained the observed-verification steps. |

## The first six-run reading, and what it found

Three runs per task on haiku at ccaf910 (`port4-haiku-1` to `-3`), the head with every
item above. Not a reading of the bar: three defects of this branch's own making spoiled
four of the six runs, and the reading is repeated on the head that fixes them.

| run | task | rounds | cost USD | minutes | turns | delivered | checks | REDO | what happened |
|---|---|---|---|---|---|---|---|---|---|
| 1 | slugify-bug | 7 | 2.31 | 21.2 | 208 | yes | 2 of 2 | 4 | the lead could not clear two artifact-lint flags in ONESHOT, escalated, and walked the full route |
| 1 | wc-json | 1 | 0.74 | 5.6 | 76 | yes | 4 of 4 | 2 | the test was written (item 1 held); two REDOs, footprint and grounding |
| 2 | slugify-bug | 1 | 0.58 | 5.5 | 50 | no | 2 of 2 | 3 | four criteria without a backticked command, appended twelve times over; the boundary run died and every Status cell stayed empty; escalated on the empty cells |
| 2 | wc-json | 1 | 0.42 | 3.6 | 53 | no | 3 of 4 | 0 | under every bar figure, then the driver-launched reviewer died on "no prompt" four times and the lead escalated |
| 3 | slugify-bug | 1 | 0.51 | 5.2 | 58 | no | 2 of 2 | 0 | the fix committed, the reviewer session died the same way, and the lead declined the run as a protocol mismatch |
| 3 | wc-json | 5 | 2.92 | 28.9 | 213 | no | 4 of 4 | 11 | the empty Status cells again, escalation, the full route, paused in ITERATE |

The three defects, each with its fix on the next commit:

1. **A criterion nobody can run.** `verification run` died on the first criterion with
   no backticked command and wrote nothing, so the empty-cell lint the audit asked for
   became a wall. Now `spec fill --criterion` refuses a bare criterion and never
   appends a duplicate, and the run writes row by row, turning a bare criterion into a
   FAIL row that names the cause.
2. **The reviewer session got no prompt.** The Claude profile's guarded list ended with
   `--allowedTools`, a variadic flag; with the reviewer model `inherit` no `--model`
   separated it from the prompt, and the CLI read the prompt as a tool name. The list
   now ends with `--permission-mode acceptEdits`, pinned in the sessions suite. A
   failed session is handed to the lead once, as the in-harness dispatch, instead of
   relaunched on every return.
3. **Decline after the work.** `decline` refuses once a feature has begun in the checkout.

What held: read-only from the task (both wc-json runs that reached the gate had the
test module in the footprint, and run 1 wrote the test, the first time in this series);
`first_turn_input_tokens` read 29k on every run; the one clean run, wc-json round 2,
sat under every bar figure at 0.42 USD, 3.6 minutes, 38 lines, zero REDO, before the
reviewer defect took it.
