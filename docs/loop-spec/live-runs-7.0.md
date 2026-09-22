# 7.0 live runs

For a reviewer of the 7.0 pull request: which checklist case in
[ROADMAP-7.0.md section 17](ROADMAP-7.0.md#17-testing-live-gates-and-cutover)
was shown by which recorded run, and what evidence backs it. This page records
runs already made; it does not describe how to run one.

## Versions

| Component | Version |
|---|---|
| Claude Code | 2.1.278 |
| Model | sonnet |
| Python | 3.13.2 |

## Cases

| Case | Run tag | Result | Evidence | Notes |
|---|---|---|---|---|
| Every phase external, all seven boundaries (M1) | `m1-ext` (program driven from the operator's shell, no model) | `converged` | [live-runs/7.0/m1-ext](live-runs/7.0/m1-ext/) | PR live-7#1; ID-01 rejected a stale binding; E5 rejected a product with no review; T-1 `human-attested`. |
| Full native cycle: lead SPEC and PLAN, critic with a Critical and one re-run, implementer and reviewer as fresh workers, VERIFY re-runs, ITERATE, DELIVER | `m3-run1`..`m3-run5`, session `ba499f53-7a0b-4883-a32b-e913e5faa7c8` | `converged` | [live-runs/7.0/m3-divide](live-runs/7.0/m3-divide/) | PR live-7#2 at `4821812`, the exact verified SHA; review `host-attested`; AC-3 carried a PLAN-declared VERIFY exception (`weakenedAssurance`). LF-05 to LF-12 came from this run. |
| Attestation both directions: verbatim prompt accepted, paraphrased prompt rejected (AT-02) | same session as the row above | shown | `events.jsonl` in `m3-divide` (`step_submitted` evidence levels) | Review steps `step-667ca2a359a6` and `step-2f997b497d10` recorded `unattested` (the lead paraphrased the prompt; the attestor's reason was `opening does not contain the composed prompt`); the re-issued `step-6cdfad7be377` recorded `host-attested` and is the review the result names. |
| Blocked exit answered `stop` | `m2-run1`..`m2-run3`, session `8c31cb9d-573d-4c76-80fc-290908003ea4` | `escalated` | [live-runs/7.0/m2-multiply](live-runs/7.0/m2-multiply/) | Reason: `execute paused; operator chose 'stop'`; `phaseReached: execute`; no PR, no false completion. |
| Two-repo workspace: per-repo base, worktrees, reviews, PRs | `m5-ws4`..`m5-ws7`, session `5b0ac74d-de4d-4a1f-a2c6-f2aec4c0433c` | `converged` | [live-runs/7.0/m5-workspace](live-runs/7.0/m5-workspace/) | PRs live-7#3 (`calc`) and live-7b#1 (`textutil`), both tasks `host-attested`. LF-24, LF-28, LF-31 came from this run. |
| Program's own invalid product ends the run as `failed` | `m5-ws1`..`m5-ws3`, session `5979de5b-2bc7-4509-a7b2-af61f46ab661` | `failed` | [live-runs/7.0/m5-workspace-failed](live-runs/7.0/m5-workspace-failed/) | Reason names the field: `$.remediationTasks[0].id: does not match pattern ^T-[0-9]+$` at `verify`; fixed as LF-25 before the re-run above. |
| debug entry: reproduction at base, compact SPEC/PLAN, critic Critical and re-pass, `mustFlip` repair | `m4-debug1`..`m4-debug4`, sessions `0901e4a9…` then `8f6c43c6-8721-4019-ae17-9d7487325d30` | `converged` | [live-runs/7.0/m4-debug](live-runs/7.0/m4-debug/) | PR live-7#4 at the verified SHA `3a17411`; the repair task's re-run recorded `mustFlip-ok` ("reproduction no longer fails"); review, verifier, final review and iterate judge all `host-attested`. LF-32 to LF-36 came from this run. |
| Blocked at the retry limit answered `stop` (revise, before LF-38) | `m5-revise1`..`m5-revise2`, session `0cf12810-0a6c-4b2b-a974-3fe1a8fef2b3` | `escalated` | [live-runs/7.0/m5-revise-escalated](live-runs/7.0/m5-revise-escalated/) | EXECUTE re-dispatched the adopted PR's own task until its retries ran out; the run blocked, the operator answered `stop`. LF-37 to LF-41 came from this run. |
| Program's own invalid product in a revise run | `m5-revise3`..`m5-revise5`, session `fb8b435c-6470-4904-b985-10d08af6a988` | `failed` | [live-runs/7.0/m5-revise-failed](live-runs/7.0/m5-revise-failed/) | Reason names the field: `$.tasks[0].review: expected at least one anyOf branch to match` (LF-43); `worktrees_removed` fired on the terminal result (LF-39 live). |
| Rewind budget exhausted (T1) | `m5-revise6`..`m5-revise8`, session `40db2995-6948-4cac-b68d-b4fd75bdd1e4` | `escalated` | [live-runs/7.0/m5-revise-rewind-escalated](live-runs/7.0/m5-revise-rewind-escalated/) | VERIFY routed `plan gap` twice on a bare verifier flag with every verdict passing; the second rewind had no budget and the run escalated with `rewinds: 2` and the reason naming the budget. LF-44 and LF-45 came from this run. |
| Permission denial under the default mode | `m6-perm1`..`m6-perm3`, sessions `ffbdff4e…`, `2cbbafed…`, `09e10c5b…` | no result (the lead stopped) | the three run transcripts (not checked in; see the notes) | With only the launcher allow-listed, the lead stopped and asked for approval rather than widening permissions or claiming completion. Run 3 showed the default mode denying every write under `~/.claude/plugins/data`; LF-27 moved model-written results to the project's `.loop-spec/results/`. |

## Reading the evidence

Each evidence directory holds the run's `result.json` (the shape `schemas/result.json`
in the program declares) and its `events.jsonl`. Paths inside them are the maintainer's
scratchpad at run time and are kept verbatim. The run tags name the `claude -p`
launches of one session; a session was resumed after each fix so the case continued
on the fixed program.
