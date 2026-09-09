# Outcome eval findings, 9 September 2026, orchestrator port (WP0 and WP1)

For the maintainer checking the done conditions of `docs/loop-spec/orchestrator-port-plan.md`
work packages 0 and 1 against live haiku runs. Same driver as
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
