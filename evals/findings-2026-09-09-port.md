# Outcome eval findings, 9 September 2026, orchestrator port (WP0 to WP6)

For the maintainer checking the done conditions of `docs/loop-spec/orchestrator-port-plan.md`
work packages 0 to 6 against live runs (haiku for the oneshot fixtures, sonnet for
`fastapi-items`). Same driver as
`evals/findings-2026-09-09-round-4.md`, no judge model (over-build is app lines added
over the task's reference size). Records: `evals/results/wp0-haiku-slugify/`,
`evals/results/wp1-haiku/` (ignored, as every record under `evals/results/`; the numbers are copied below).

## WP0: the full path reaches DELIVER

Plugin b1f9bbd, `slugify-bug`, haiku, one round, `--phase-fresh` off.

| task | accepted | delivered | phase | cost USD | min | turns | agents | app +/- | artifact + | over-build |
|---|---|---|---|---|---|---|---|---|---|---|
| slugify-bug | 2/2 | pushed | completed | 1.99 | 15.8 | 122 | 6 | +2/-0 | +384 | 0.25x |

The done condition holds: the run reached DELIVER (`delivery_status: pushed-no-pr`,
the sandbox has no PR remote), accepted both checks, and the state ref kept the branch
to code and artifact commits. The four defects the plan lists did not recur: no
misplaced SPEC.md, no converged-floor veto, no dirty-candidate abort in VERIFY, no
state commit on the branch. What the numbers say about the full path on a two-line
fix: 384 artifact lines and six agents for two lines of code. That ratio is WP1's
reason to exist.

## WP1: the oneshot route

Plugin 7013bca, haiku, one round each, both tasks in one run (`evals/results/wp1-haiku/`).

| task | accepted | delivered | route | cost USD | min | turns | agents | app +/- | artifact + | over-build |
|---|---|---|---|---|---|---|---|---|---|---|
| slugify-bug | 2/2 | pushed | oneshot | 0.56 | 4.1 | 57 | 0 | +2/-0 | +111 | 0.25x |
| wc-json | 3/4 | pushed | oneshot | 0.80 | 6.7 | 63 | 1 | +6/-1 | +185 | 0.17x |

Both runs took the route: three commits on each branch (`spec:`, the fix, `oneshot:`),
no DISCUSS, PLAN, EXECUTE, VERIFY, or ITERATE. Against WP0's full path on slugify-bug
the route cost 28 percent of the money and 26 percent of the time, with 29 percent of
the artifact lines.

The plan's bar is not met. It asks for slugify-bug at 0.25 USD, 50 artifact lines, 3
minutes, and wc-json at 0.60 USD, 100 lines, 5 minutes, delivered and accepted.
slugify-bug is over on all three; wc-json is over on all three and failed one check.

### 1. The footprint was a claim, not a promise

wc-json's SPEC named `tests/test_wc_tool.py` in its footprint. The implementation
touched only `wc_tool.py`; the reviewer wrote "consider adding automated tests" under
Minor and the phase deferred it. The eval's `json_test_added` check failed. Fixed in
the same change: `lib/oneshot-exit-gate.sh` flags a footprint file absent from the
diff since `baseSha`, and the skill says the footprint is a promise
(`tests/lib/oneshot-exit-gate.test.sh`, "an untouched footprint file flags").

### 2. The review pass was skipped and nobody could tell

slugify-bug's VERIFICATION.md says "No findings" under Code review, names no
reviewer, and the record counts zero agents: the lead wrote the verdict itself. Fixed:
the exit gate requires a `dispatch` event with role `code-reviewer` in phase `oneshot`
(`events.jsonl`, the dispatch telemetry contract every other phase already carries),
and `skills/oneshot/SKILL.md` emits it in the same call that reads the reviewer's
result. Self-reported, as in VERIFY, but a lead that skips the dispatch now has to
forge an event to pass, and `hooks/team/result-forgery-guard.sh` is on that path.

### 3. The spec kept the full shape's weight

The oneshot template is under 60 lines; the runs wrote 37 and 93. The 93-line spec
carried Goals, Non-goals, Boundaries, Constraints, and User-facing behavior sections the
route never reads. Fixed: `lib/oneshot-spec-lint.sh` runs at SPEC's exit and flags a
spec with a oneshot footprint over 60 lines or without `## Implementation notes`.

### 4. Where the rest of the cost sits

57 to 63 turns for a two-line change. The route removed five phases; what remains is
SPEC's scout (evidence probes, `doc-deps`, `docs-probe` for every dependency the scout
names) and the driver's phase bookkeeping, both sized for a feature. The plan's bar is
BMad's measured number for a flow with no scout and no gates; reaching it means a
lighter SPEC on the route (a scout that stops at the footprint), which is WP6's spec
work, and the driver leaving the lead (WP4). Not changed here.

### Reproduce

```bash
LOOP_SPEC_EVAL_LIVE=1 bash evals/run.sh --model haiku --confirm-spend \
  --tasks slugify-bug,wc-json --parallel 2 --budget-usd 3 --run-id wp1-haiku
```

## WP4, WP5, WP6 on the final plugin (dda2cca)

Every run below is on plugin dda2cca: the Python driver with one phase per invocation
(WP4), the session layer and rung (WP5), the two spec shapes and the review triage gate
(WP6), plus the guards the earlier rounds forced (`nested-session-guard.sh`, the parser's
leading-flag rule, the one-paused-feature resume). Records: `evals/results/final-haiku-oneshot/`,
`evals/results/final-haiku-todo/`, `evals/results/final-sonnet-fastapi/` (ignored; the
numbers are copied below).

| task | model | accepted | delivered | route | rounds | cost USD | min | turns | agents | app +/- | artifact + | over-build |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| slugify-bug | haiku | 2/2 | pushed | oneshot | 1 | 0.88 | 6.1 | 82 | 1 | +2/-0 | +92 | 0.25x |
| wc-json | haiku | 3/4 | pushed | oneshot | 1 | 1.35 | 8.3 | 113 | 1 | +6/-1 | +112 | 0.17x |
| todo-due | haiku | 5/5 | pushed | oneshot | 5 | 1.38 | 10.9 | 132 | 1 | +57/-6 | +156 | 0.95x |
| fastapi-items | sonnet | in flight | in flight | full | 5+ | 4.61 so far | 39+ | 179+ | - | - | - | - |

### WP1 bar, second reading

Not met, and further from it than the first reading (0.56 and 0.80 USD). What the
transcripts say the money went to, in order:

1. **One session ran every phase.** Both oneshot runs completed in one round. The
   driver handed off after SPEC (`paused` events at 16:02:48 and 16:03:17), the handoff
   guard denied `Skill(loop-spec:oneshot)`, and the lead invoked it again: the denied
   attempt was now the transcript's last phase, so the second call passed as a
   same-phase retry. The guard counted a denied attempt as a prior phase. Fixed after
   these runs (`hooks/team/phase-handoff-guard.sh`, "a phase denied once is denied again").
   The next reading pays a fresh session per phase, so cost per phase drops and cost per
   run may not.
2. **The footprint left the test out.** wc-json's SPEC named `wc_tool.py` alone, the
   implementation added no test, the reviewer wrote "consider adding tests" under
   Minor, and `json_test_added` failed again, as in the first reading. Fixed after these
   runs: `lib/oneshot-spec-lint.sh` flags a footprint file whose existing test module
   the spec never names.
3. **82 and 113 turns for two and six lines.** SPEC's scout and grounding, the frozen
   Intent block, the code-review dispatch, the review triage, and DELIVER each cost
   their turns. The route is right; the phases on it are still sized for a feature.

### WP5: the session rung

`lib/harness.sh session-layer` answered `session` on every headless run here (`claude`
on PATH, `profiles/claude.toml`, python 3.11). The rung is EXECUTE's, and every haiku
fixture took the oneshot route, which has no EXECUTE: `todo-due` is a three-file
footprint and went oneshot in five rounds. `fastapi-items` is the one full-route run;
its EXECUTE is where the rung shows (see the WP4 section). The runner itself was proven
against the real CLI before the runs: `session_run.py --profile claude --model haiku` on
a one-line prompt created the file and returned `status: completed` in 6.4 seconds.

The Codex half of the done condition did not run: the sandbox has no `codex` binary.
`profiles/codex.toml` is the launch line `skills/shared/codex-harness.md` documents;
nothing here has executed it.

### WP4: one phase per invocation

The `fastapi-items` run on dda2cca was still in round 5 (PLAN) when this record was
committed; its final numbers follow in the next commit. What its first four rounds say:

| round | phase entered | cost USD | turns | ended |
|---|---|---|---|---|
| 1 | SPEC | 1.47 | 89 | handoff to DISCUSS |
| 2 | DISCUSS | 0.38 | 13 | paused at DISCUSS again |
| 3 | DISCUSS | 2.42 | 66 | handoff to PLAN |
| 4 | PLAN | 0.33 | 11 | paused at PLAN again |
| 5 | PLAN | running | | |

Rounds 2 and 4 are the shared-transcript defect: on dda2cca the eval driver dropped only
`CLAUDE_CODE_SESSION_ID`, which was not enough (measured after the run: the child took
its own transcript only once the remote-session plumbing was dropped too, daf2aef). A
round that inherits the previous round's transcript meets the handoff guard's "one phase
per invocation" on its first phase call, gives up, and is re-invoked; that costs about
0.35 USD and a dozen turns per phase boundary and is charged to WP4 here although it is
the harness's. Read the bar against rounds 1, 3, and 5 onward.

The phase-per-invocation protocol itself held on every boundary: each round entered
exactly the phase the previous round handed off, through `lib/phase-entry.sh`, with the
state on `refs/loop-spec/state/<slug>` and no state commit on the branch.

### What the earlier rounds cost and taught

The rounds before dda2cca were stopped and are not in the table. Three of their
defects are fixed on dda2cca and named in the changelog: a sonnet lead wrote its own
round script after the DISCUSS handoff and spent its budget twice; a haiku lead
reworded the task because the parser refused `python3 -m unittest` as a flag, and the
reworded slug matched no paused feature, so a second cycle started in the plugin's own
repository; and every nested `claude -p` inherited this session's identity, so all
rounds of a run shared one transcript and the handoff guard read round one's phase as
round three's. The last is an eval-harness defect, not a plugin one, and it invalidates
the earlier rounds' handoff numbers.

### Reproduce

```bash
LOOP_SPEC_EVAL_LIVE=1 bash evals/run.sh --model haiku --confirm-spend \
  --tasks slugify-bug,wc-json --parallel 2 --budget-usd 3 --run-id final-haiku-oneshot
LOOP_SPEC_EVAL_LIVE=1 bash evals/run.sh --model haiku --confirm-spend \
  --tasks todo-due --budget-usd 6 --run-id final-haiku-todo
LOOP_SPEC_EVAL_LIVE=1 bash evals/run.sh --model sonnet --confirm-spend \
  --tasks fastapi-items --budget-usd 12.2 --run-id final-sonnet-fastapi
```
