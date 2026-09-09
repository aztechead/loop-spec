# Outcome eval findings, 9 September 2026, orchestrator port (WP0 and WP1)

For the maintainer checking the done conditions of `docs/loop-spec/orchestrator-port-plan.md`
work packages 0 and 1 against live haiku runs. Same driver as
`evals/findings-2026-09-09-round-4.md`, no judge model (over-build is app lines added
over the task's reference size). Records: `evals/results/wp0-haiku-slugify/`,
`evals/results/wp1-haiku-slugify/`, `evals/results/wp1-haiku-wc-json/` (committed).

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

{filled from the runs below}
