# Orchestrator port: third audit, at b5008b4

For the agent driving PR 94. This audits the eighteen commits after f0959f6 (fee59f6
through the PR 93 merge b5008b4, version 6.5.0) against
`docs/loop-spec/orchestrator-port-followup-2.md` and a fresh live run on the new head.
The earlier documents stand. This one records what moved, what did not, and the next
ordered list.

## Verdict

This round made real progress for the first time. Both fixtures began a cycle,
followed the short route, and delivered. The bug fix halved in cost against dda2cca.
Eleven of twelve follow-up items were started and seven are done. The bar is still
missed by about 2.5 times on cost and 2 times on time, and the reasons are now
specific and few.

| run | cost USD | minutes | turns | rounds | artifact lines | delivered | checks |
|---|---|---|---|---|---|---|---|
| bar, bug fix | 0.25 | 3 | | 1 | 50 | yes | |
| BMad, bug fix | 0.23 | 1.8 | 26 | 1 | 43 | local commit | 2 of 2 |
| loop-spec dda2cca | 1.26 | 9.5 | 117 | 2 | 119 | pushed | 2 of 2 |
| loop-spec f0959f6 | 0.12 | 0.7 | 15 | 1 | 0 | no | 0 of 2, no cycle |
| loop-spec b5008b4 | 0.62 | 6.2 | 55 | 2 | 83 | pushed | 2 of 2 |
| bar, feature | 0.60 | 5 | | 1 | 100 | yes | |
| BMad, feature | 0.35 | 2.8 | 34 | 1 | 56 | local commit | 4 of 4 |
| loop-spec f0959f6 | 2.48 | 20.4 | 207 | 4 | 127 | pushed | 4 of 4 |
| loop-spec b5008b4 | 0.87 | 8.3 | 78 | 2 | 145 | pushed | 3 of 4 |

Code quality: both diffs are the same correct minimal change as every prior run. The
bug fix again uses single quotes on lines whose neighbors use double quotes. The
feature run added no test, for the fourth time in this series, and that is the failed
check.

Where the remaining cost sits, from the driver answers in both transcripts:

- **Five format REDO rounds on the bug fix.** SPEC: `artifact-lint` demanded an H1
  title and a `## Problem` heading on the oneshot-shaped spec, twice. ONESHOT:
  `artifact-lint` raised 21 flags on VERIFICATION.md, then `verification-grounding`
  raised two more rounds on one line. The driver-written skeletons exist in the tree
  and did not prevent any of these. Either the lead overwrote the skeleton, or the
  SPEC exit gate runs the full-shape lint on the oneshot shape. Either way F4's done
  condition, zero format rounds, is not met, and this is most of the gap to the bar.
- **The footprint promise has an escape hatch.** The feature spec named
  `tests/test_wc_tool.py` in its footprint. The exit gate flagged the untouched file
  twice, and its message offers "or say why". The lead wrote a reason, the gate
  accepted it, and the run delivered without the test. A promise the lead can talk its
  way out of is a judgment selecting a branch.
- **DELIVER is a second session.** Both runs are two rounds because DELIVER hands off.
  It costs 0.07 to 0.16 USD and up to 1.2 minutes per run. On the short route DELIVER
  is mechanical and belongs in the same session, or the bar's round count should say
  so. This document says same session.

## Test suite

232 suites pass at b5008b4. Two fail on this machine, and the cause is not a code
change: the live run at f0959f6 created a feature worktree inside the plugin checkout
itself, `.claude/worktrees/add-a-json-flag-...` on a `feat/` branch at 18:29, and the
ad-hoc verify guard's own tests then found an in-flight feature and stood down. With
that worktree removed the suite is green. Two findings follow: a cycle escaped into a
repository that was not its project, which is the "second cycle in the plugin's own
repository" failure the port findings already recorded, recurring at f0959f6; and the
test suite is not hermetic against it. The b5008b4 run did not escape.

## Scorecard

| item | state | evidence |
|---|---|---|
| F1.1 stop deny on unconsumed stamp | done | `hooks/team/cycle-stamp-guard.sh`, registered under Stop, no switch of its own. Its deny message prints a 100-character absolute driver path for the lead to retype, the exact failure F1.3 removes. Test case "a" asserts an edits-without-driver-call state the hook never reads. |
| F1.2 stop deny while a phase is open | not done | No hook reads `phase_start` or `phase_end`. The stamp is consumed at `begin`, so the guard cannot cover a later phase by construction. The lead that declares a phase complete still stops freely. |
| F1.3 driver path not retyped | partial | `DRV` is bound once and every call is `bash "$DRV"`. No test pins it. |
| F1.4 micro directive stands down headless | done | Attended probe in `lib/harness.sh` initialized false; injects only on proven attended. Bridge harnesses answer attended on silence, documented. |
| F1.5 eval names "no cycle" | done | `cycle_begun` and the summary row. |
| F2 short route in one session | done | `sameSession` on the edge, driver answers `NEXT`, guard reads the probe, pinned both directions. Full route still hands off per phase. |
| F3 line budget | partial | `lib/context-load.sh` and a test bound `skills/oneshot/SKILL.md` at 600, measured 463. The probe's own reading of the whole short path is 2,166 lines at depth one and 7,279 transitive, because the cycle skill (231) and the full SPEC body (257) load regardless of which section runs. The test bounds one skill; the bar was written for the path. |
| F4 zero format rounds | not met | Skeletons exist (`driver.py spec skeleton`, `write_skeletons`). Five format REDOs on the live bug fix. Five flag sources remain reachable on the short route. |
| F5 spec written where the gate reads it | done | `driver.py spec write --file`, main-agent deny, worktree-versus-parent test. |
| F6 exit-gate fail-open cases | done | Unreadable frontmatter flags; scans run on escalation; workspace per repo; diff outside footprint routes to full; five test cases. The gate mutates its input spec while grading it. |
| F4 addition, driver-launched reviewer | done, one fail-open | `driver.py cmd_oneshot` runs the reviewer through the session layer and emits the dispatch event. The event is emitted for every return code before the status is checked, so a failed reviewer session still satisfies the gate's review check. |
| F7 typed reader leftovers | done | Five readers migrated, two-pass coverage scan, stray keys fail, rewind pinned. |
| F8 session rung in the driver | partial | The EXECUTE spawn moved into `lib/execute-step.sh` behind a driver call; the ONESHOT reviewer spawns from the driver. Guard allow-list is by path token with word boundaries. Vendoring recorded. Rung still not run live. |
| F9 phase subsets | done differently | Subsets pinned by a test against the graph, not derived. Validator runs on the test's graph copy. Disclosed. |
| F10 pin couplings | partial | `still FAIL` pinned in both files; triage lint fixed. State-ref test still counts on `main` in a synthetic repo. |
| F11 docs | done | Stale variable gone, marker renamed, exceptions recorded. `skills/cycle/SKILL.md` grew anyway. |
| F12 state ref push | open | Left to the maintainer, correctly. |

Principle compliance across the delta: `skills/cycle/SKILL.md` 226 to 231,
`skills/spec/SKILL.md` 211 to 257, `skills/oneshot/SKILL.md` 114 to 125, net +42.
Variables 194 to 198 and guards 27 to 30, all four variables and all three guards
arriving through the PR 93 merge, not the port commits. The port commits deleted
guard-describing prose in two places and added a driver-call block in one. The PR 93
policy of keeping findings out of the tree is not in force in the merged tree.

## Required work, in order

The first four are the gap to the bar. Do them before any new eval.

### N1. The lead never writes a shape

Evidence: five format REDOs with skeletons present. Make the skeleton the only writer.
The driver writes `SPEC.md` and `VERIFICATION.md`; the lead fills named fields through
`driver.py spec fill --field <name> --value <text>` and `verification fill --row <id>
--implementation <file:line> --proof <text>`, and the driver re-validates on every
write. Deny a direct `Write` or `Edit` to either file from `hooks/restrict-agent-paths.sh`
while the route is oneshot. Then the SPEC exit gate cannot see an H1 problem, because
the lead never had the file open.

Done when: `evals/eval_run.py` records REDO rounds by flag class, and a haiku bug-fix
run records zero in the classes `artifact-lint`, `verification-grounding`, and
`misplaced`.

### N2. The footprint is a promise with no prose exit

Evidence: the feature run delivered without the test its own spec promised. Remove the
"or say why" branch from `lib/oneshot-exit-gate.sh`. A footprint file absent from the
diff is a REDO. To drop a file the lead runs `driver.py spec footprint drop <file>
--reason <text>`, which writes the decision to `decisions.jsonl` and to the spec, and
the gate reads the ledger. The reason is recorded, not adjudicated. When the dropped
file is a test module for a changed file, the drop is refused.

Done when: a haiku feature run adds a test or fails, never delivers without one, and
`tests/lib/oneshot-exit-gate.test.sh` has the refused-drop case.

### N3. DELIVER joins the short session

Evidence: two rounds on every short-route run. Put `sameSession: true` on
`oneshot -> deliver` as F2 did for `spec -> oneshot`. DELIVER has no model work on the
short route. The bar's round count then reads one.

Done when: both fixtures record `rounds: 1`.

### N4. Bound the path, not the skill

Evidence: the probe reads 2,166 lines for the path and the test bounds 463 of them.
Split the oneshot candidate's SPEC section into its own skill file so the harness loads
it instead of the 257-line SPEC body. Cut `skills/cycle/SKILL.md` to the launcher the
plan asked for by moving steps 1 to 3 into `begin`'s output. Then change
`tests/lib/context-load.test.sh` to sum the three bodies the short route loads, at
600.

Done when: `lib/context-load.sh sum` over the three bodies the short route loads, the
cycle skill, the new lite spec skill, and the oneshot skill, is at or under 600 and the
test says so.

### N5. Close the two fail-opens this round added

- `driver.py cmd_oneshot` emits the reviewer dispatch event only after
  `status == "completed"` and the report file exists.
- `hooks/team/cycle-stamp-guard.sh` denies the open-phase state too: `phase_start`
  newer than the last `phase_end` or `paused` record and no result newer than it.
  Rewrite its deny message to name `bash "$DRV" begin` and nothing longer. Fix test
  case "a" to assert what the hook reads.

### N6. A cycle never runs in the plugin's own repository

Evidence: the escape at f0959f6. `driver.py init` refuses when the checkout it would
initialize contains `.claude-plugin/plugin.json` naming this plugin, or when the
checkout is the directory the eval driver launched from. Probe, reason, exit 3. And
`tests/run-all.sh` refuses to start when `lib/active-cycle.sh has-active` answers yes
for the checkout, naming the worktree, so a leaked feature cannot turn a guard test
green by accident.

### N7. Small pins

- Duplicate `phase_end` and `phase_start` events on the same-session re-entry, seen
  again this round. One transition, one pair.
- The pass-bar figures in `evals/tasks/*/task.json` are copied from the plan with no
  test tying them to it.
- `tests/lib/state-ref.test.sh` counts commits on a driver-delivered branch, as F10
  asked.
- The PR 93 merge added four variables and three guards. Either apply rule 9 to them
  now or record each as accepted with its observed failure.
- The findings-out-of-tree policy from PR 93: apply it to the four port findings
  files, or record why not.

## Pass bar, restated

Unchanged. Measured with `evals/run.sh` on haiku, delivered:

| task | cost USD | artifact lines | minutes | rounds |
|---|---|---|---|---|
| slugify-bug | 0.25 | 50 | 3 | 1 |
| wc-json | 0.60 | 100 | 5 | 1 |

At b5008b4 the bug fix is at 0.62, 83, 6.2, and 2. N1 and N3 are the two that close it.

## Reproduce

```bash
LOOP_SPEC_EVAL_LIVE=1 bash evals/run.sh --model haiku --tasks slugify-bug,wc-json \
    --parallel 2 --run-id port3-haiku --confirm-spend
```

The two runs cost 1.49 USD together. `bash tests/run-all.sh` at b5008b4: 232 suites
passed and 2 failed with the escaped worktree present; the two failing suites pass
once it is removed.

## Landing record

For the reviewer of PR 94. What each item above became on the branch, in the order the
items were worked, with the decisions the audit did not anticipate taken by
`docs/loop-spec/orchestrator-port-principles.md`. Offline evidence is
`bash tests/run-all.sh` (235 suites). The live evidence is one run more than the audit
had, and it is recorded before the work below landed: no live run has measured N1,
N2, or N4 yet, and that measurement is the user's spend, not this branch's.

| item | state | evidence |
|---|---|---|
| live run 3 | over the bar, before this work | `slugify-bug` on haiku at 44c6288 (the N3 commit): delivered in one round, 0.80 USD, 6.5 minutes, 124 artifact lines, 79 turns. Two thirds of the output tokens were the lead filling VERIFICATION.md by hand (21 edits, ten of them chasing a pipe the skeleton had written into a table cell unescaped, fixed at 1903e50). The bill is context reads: 30k tokens at the first turn, 93k at the last, 4.4M cached tokens read. |
| N3 | done | `"sameSession": true` on `oneshot` to `deliver` (44c6288); live run 3 recorded `rounds: 1`. |
| N5 | done | The driver emits the reviewer dispatch event only when the session completed and wrote its report (a failed or silent reviewer leaves the gate's review check to speak). `hooks/team/cycle-stamp-guard.sh` denies the open-phase state too: the newest `phase_start` with no `phase_end` and no newer result, read from every worktree of the project, until `LOOP_SPEC_PHASE_TIMEOUT_MINS`; both denials name the driver call through the `DRV` the cycle skill binds. Test case a asserts the stamp and the result file. |
| N6 | done, one deviation | `cycle-driver.sh init` exits 3 when the checkout carries this plugin's manifest and is not the project the harness opened, or when the driver runs from a copy inside that checkout (the eval's layout); self-development stays allowed. `tests/run-all.sh` refuses to start while an active cycle lives in *another* worktree of the repository, naming it; an active cycle in the very checkout the suite runs in is the plugin verifying itself from its feature worktree, which the documented workflow needs, so that case is not refused. The ad-hoc verify guard's suite runs every hook call from its fixture directory, which is the hermeticity the escape exposed. |
| N2 | done | `lib/oneshot-exit-gate.sh` flags every footprint file the diff never touched, whatever Implementation notes say; the `unchanged`/`read-only` reading and the silent non-test drop are gone. `cycle-driver.sh spec footprint drop --file --reason` is the one way out (a ruling in `decisions.jsonl`, a line in the spec, the file out of the list) and refuses the test module of a file that stays. Pinned in `tests/lib/oneshot-exit-gate.test.sh`. |
| N1 | done, unmeasured live | `cycle-driver.sh spec fill`, `spec escalate`, and `verification fill` fill the driver-written skeletons one value per call and answer with the exit lints' flags; `hooks/restrict-agent-paths.sh` denies a Write or Edit of SPEC.md or VERIFICATION.md while `lib/graph/probes/oneshot.sh` answers `route=oneshot`. The oneshot node's VERIFICATION.md skeleton is `VERIFICATION-oneshot.md.template`, the sections the gates read (44 lines for two criteria against 99 filled from the full template on run 3). Every REDO is a driver-observed `redo` event with its flag classes; the eval record carries `redo` and `format_redo`, and the summary prints them. Done condition (a haiku run with zero format REDOs) awaits the next live run. |
| N4 | done at the bound | `skills/spec-lite/SKILL.md` is SPEC's entry (the graph's `spec` node names it with the node key `skill`, printed as `EXT skill=spec-lite`); it hands to `loop-spec:spec` on the full route, whose body lost the candidate section. The cycle skill is the launcher: `begin` answers `decisions` with the rendered init and resume commands, `finish` prints the completion report from the record, `cycle-driver.sh decline --reason` writes the mismatch result; the headless-run and team-dispatch sections are gone. `tests/lib/context-load.test.sh`: cycle + spec-lite + oneshot with their cites is 600 lines, from 1387, at the bound. The prompt-normalize contract (76 lines) is the one cite left in the cycle skill: the rewrite is a judgment, not a driver step. |
| N7 | done, two recorded | A repeated handoff answer adds no phase event pair (pinned; the pair the audit saw could not be reproduced on this head). Each task's bar is checked against the plan's figures. The four port findings files leave the tree per the policy PR 93 set; the changelog names the runs. The state-ref count on a driver-delivered branch was pinned already (`tests/lib/cycle-driver.test.sh`, "carries no state commit", in place and in a worktree). PR 93's four variables and three guards stay as merged: `hooks/team/dispatch-prompt-guard.sh` (`LOOP_SPEC_DISPATCH_PROMPT_GUARD`) and `hooks/team/artifact-lint-feedback.sh` (`LOOP_SPEC_ARTIFACT_LINT_FEEDBACK`) each carry the tf-meldn run that produced them in their header, and their kill switches follow the convention of every hook that predates rule 9; `LOOP_SPEC_TASK_BATCH_AUTO` and `LOOP_SPEC_TASK_BATCH_CHAIN_FILES` are tuning of `lib/task-batch.sh`'s chain merge, with the eleven-task run in its header. The `cycle-stamp-guard.sh` is this branch's and has no switch. |
| live run 4 | over the bar, halved | `slugify-bug` on haiku at d17da82 (every item above landed): delivered in one round, 0.41 USD, 3.8 minutes, 74 artifact lines (SPEC.md 31, VERIFICATION.md 43), 39 turns, 1.44M cached tokens read, zero REDO rounds (`format_redo: 0`, N1's done condition). Against run 3: cost 0.80 to 0.41, turns 79 to 39, artifact lines 124 to 74, cached reads 4.4M to 1.4M. Still over the bar of 0.25 USD, 50 lines, 3 minutes. |
| the bet | open again | Three live runs before this work stood at 0.76, 0.56, and 0.80 USD against 0.25. The work above removes the two costs run 3 measured (the hand-filled artifact and the loaded context), and the audit's own reading says N1 and N3 close the gap. Run 4 is that run: it halved the cost and removed every format round, and it is still over the bar by 0.16 USD, 24 lines, and 0.8 minutes. What remains is the fixed cost of the opening context (56k tokens written to the cache at turn one, 1.4M read over 39 turns) and 39 turns for a two-line fix; the record now says which, and neither is a format round. |
