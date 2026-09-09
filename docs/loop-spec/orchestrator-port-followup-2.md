# Orchestrator port: second audit, at f0959f6

For the agent driving PR 94. This audits the eight commits after dda2cca (daf2aef
through f0959f6, still 6.4.0) against `docs/loop-spec/orchestrator-port-followup.md`
and a fresh live run on the new head. Read the follow-up and
`docs/loop-spec/orchestrator-port-principles.md` first if you have not. The eight
commits show no sign of either document: none of the twelve follow-up items was
started, and two of the commits do the thing the principles name as the failure mode.

## Verdict

The eight commits are sound. They fix real defects the other sonnet runs exposed: a
denied phase call counted as a prior phase, a lead that re-entered its own handed-off
session, a nested CLI that inherited the parent's launch stamp, and a repeated handoff
that lost its result pointer. Each has a test. 226 suites pass.

They do not move the bar, and the live run on f0959f6 shows the follow-up's first item
recurring in a new form.

| run | cost USD | minutes | turns | rounds | artifact lines | delivered | outcome |
|---|---|---|---|---|---|---|---|
| bar, bug fix | 0.25 | 3 | | 1 | 50 | yes | |
| BMad, bug fix | 0.23 | 1.8 | 26 | 1 | 43 | local commit | followed |
| loop-spec dda2cca, bug fix | 1.26 | 9.5 | 117 | 2 | 119 | pushed | 6 REDO rounds |
| loop-spec f0959f6, bug fix | 0.12 | 0.7 | 15 | 1 | 0 | no | never began a cycle, 0 of 2 checks |
| bar, feature | 0.60 | 5 | | 1 | 100 | yes | |
| BMad, feature | 0.35 | 2.8 | 34 | 1 | 56 | local commit | followed |
| loop-spec dda2cca, feature | 0.18 | 1.3 | 21 | 1 | 0 | no | never began a cycle, 2 of 4 |
| loop-spec f0959f6, feature | 2.48 | 20.4 | 207 | 4 | 127 | pushed | 4 of 4, one round wasted |

The feature run is the first loop-spec run in this series to deliver the feature task
with every check green. It cost four times the bar in money and time. Round by round:
SPEC 0.37 USD and 37 turns; ONESHOT 0.96 USD and 73 turns, ended by the lead declaring
the phase complete after the exit gate refused it for a missing reviewer dispatch;
ONESHOT again, 1.02 USD and 84 turns, this time with the reviewer; DELIVER 0.14 USD.
Three of its six branch commits are VERIFICATION.md format fixes. The code is correct,
with one precise test added.

The bug-fix run never began a cycle. The lead tried: it called the driver with the
absolute path from the skill text retyped with one digit wrong, the call failed, a
search from the wrong root found nothing, and it hand-fixed the file while printing
`SPEC:`, `PLAN:`, and `VERIFY:` labels for phases it never entered. It stopped with an
uncommitted edit and no result. On dda2cca the same class of failure came from the
micro directive. Two causes, one missing rule: nothing denies a stop after a cycle
invocation that never called `begin`.

## What the eight commits changed

| commit | change | sound | note |
|---|---|---|---|
| daf2aef | `hooks/team/phase-handoff-guard.sh` excludes denied calls from the prior-phase set; child env drops the whole session identity; `lib/oneshot-spec-lint.sh` flags a footprint file whose test module the spec never names | yes | The denied-call test matches the substring `hook error` in a tool result, which is fail-open toward allowing a second phase. The new lint skips silently when `git rev-parse` fails. It is a fifth format flag on the short route while F4 asks for zero. It also added a paragraph to `skills/spec/SKILL.md`. |
| f6ff84a | `lib/graph/driver.py` records the handoff session and refuses `phase-begin` from it; `lib/cycle-result.sh` requires a delivery record for `completed` in every phase | yes | Fail-closed. A harness that stamps no session id disables the check, by design and documented. Added four lines to `skills/cycle/SKILL.md`. |
| f7a5b53 | both runners drop `CLAUDE_CODE_ENTRYPOINT` so the child stamps its own launch | yes | Deterministic. Explains why the session rung never ran live. |
| 5de3b59 | a repeated handoff rewrites the paused result; `start` refuses the handed-off session | yes | The repeat emits a second `phase_end` and `phase_start` pair into `events.jsonl` (seen on the f0959f6 feature run at 18:46:26). Cosmetic, but a sink that counts phase ends now double-counts. |

Against the principles: `skills/cycle/SKILL.md` is 226 lines and `skills/spec/SKILL.md`
211, both up. Two of four fixes added a check and a paragraph describing the check.
The principles' rule 9 says the paragraph is deleted when the guard wins by
construction.

## Follow-up scorecard

| item | state at f0959f6 |
|---|---|
| F1 cycle begins or refuses | not started, and recurred with a second cause |
| F2 short route in one session | not started; 5de3b59 hardens the boundary the other way |
| F3 line budget | not started; both skill files grew |
| F4 zero format rounds | not started; a fifth format flag added; three format commits on the feature run |
| F5 spec written where the gate reads it | not started |
| F6 exit-gate fail-open cases | not started |
| F7 typed reader leftovers | not started |
| F8 session rung in the driver | partial: the entrypoint fix explains the miss; the rung has still not run live; the spawn is still prose |
| F9 phase subsets from the graph | not started |
| F10 pin the new couplings | not started |
| F11 stale docs | not started |
| F12 state ref on the remote | no decision recorded |

## Required work, in order

F1 first, with what the two runs added. Then F2 and F3, unchanged. Then F4 with one
addition. The rest stand as written in the follow-up.

### F1, extended

The two observed causes and the guards, all deterministic:

1. **Stop deny on an unconsumed stamp.** `hooks/team/invocation-stamp.sh` writes
   `.loop-spec/invocation-stamp.json` at prompt time with `skill: cycle`, and
   `driver.py start` consumes it. A Stop hook denies while that stamp exists and no
   `.loop-spec/last-result.json` is newer than it. The message names the `begin` call
   and the driver path. Both live runs would have been denied.
2. **Stop deny while a phase is open.** The f0959f6 feature run's second round ended
   with `phase_start oneshot` and no `phase_end`, no `paused` handoff, and no result
   newer than the phase start. The same Stop hook denies that state too. A lead that
   loses a REDO argument cannot end the session by declaring victory.
3. **The driver path is not retyped.** The bug-fix lead retyped a 120-character absolute
   path with one digit wrong. The skill text should never need the lead to reproduce
   that path in a Bash call. Bind `DRV` once in the skill through the harness
   substitution and make every later call `bash "$DRV"` verbatim, or ship a launcher the
   plugin puts on PATH. Pin it: a test that greps `skills/cycle/SKILL.md` for any
   absolute-path form of the driver.
4. **`micro-inject.sh` stands down headless**, using an attended probe in
   `lib/harness.sh` that fails safe to not injecting. f7a5b53 already made the child
   stamp its own entrypoint, so the probe can read `sdk-cli` now.
5. **The eval names the failure.** `cycle_begun` in the record, and a summary row that
   reads "no cycle" for `status: null`. Two runs in this series were scored as plugin
   results when the plugin never ran.

Done when: a haiku run of both fixtures reaches DELIVER in one attempt each, and the
Stop hook's test covers both deny states.

### F4, one addition

The reviewer dispatch is the one exit-gate check the lead cannot satisfy by editing a
document, and it is the one the lead abandoned the phase on. When the driver launches
the reviewer itself, from the session layer or through the phase body it emits, the
dispatch event is driver-written and the check disappears. That is F8's first bullet
moved forward, because the feature run paid 0.96 USD for its absence.

### Do not

- Do not add a paragraph to a SKILL.md that describes a guard. Delete the paragraph
  the guard makes redundant instead, and record the line count going down.
- Do not add a format flag on the short route. Add the shape to the skeleton the driver
  writes.
- Do not run another sonnet full-route eval until F1 through F3 are done. Every run
  before that measures the same fixed cost, and the fastapi run already spent 12 USD
  to show it.

## Reproduce

```bash
LOOP_SPEC_EVAL_LIVE=1 bash evals/run.sh --model haiku --tasks slugify-bug,wc-json \
    --parallel 2 --run-id port2-haiku --confirm-spend
```

The two runs above cost 2.60 USD together. `bash tests/run-all.sh` at f0959f6: 226
passed, 0 failed.
