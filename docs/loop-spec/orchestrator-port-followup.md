# Orchestrator port: follow-up after the first landing

For the agent driving PR 94. This document audits the fourteen commits that landed the
six work packages of `docs/loop-spec/orchestrator-port-plan.md` (b1f9bbd through
dda2cca, version 6.4.0) against that plan's done conditions and against a fresh live run
on the final head. It ends with the work that is still required, in the order that moves
the pass bar. Read the plan first. This document does not repeat it.

## Verdict

The port landed its architecture. The loop left the lead, phases are graph data, state
lives on a ref, the oneshot route exists, and 226 offline suites pass at dda2cca. The
pass bar is not met, and one live run on the final head regressed below the starting
point: a cycle invocation never began a cycle.

Live runs on Claude Code, haiku, one run per cell. Every loop-spec row uses
`evals/run.sh` unchanged. BMad and control rows are from the 9 September head-to-head.

| run | cost USD | minutes | turns | artifact lines | delivered | process |
|---|---|---|---|---|---|---|
| bar (plan, WP1) | 0.25 | 3 | | 50 | yes | |
| BMad, bug fix | 0.23 | 1.8 | 26 | 43 | local commit | followed |
| control, bug fix | 0.06 | 0.5 | 9 | 0 | local commit | none |
| loop-spec c2fc8b9, bug fix | 0.68 | 3.9 | 64 | 213 | no | escalated in SPEC |
| loop-spec 7013bca, bug fix | 0.56 | 4.1 | 57 | 111 | pushed | oneshot, per its own record |
| loop-spec dda2cca, bug fix | 1.26 | 9.5 | 117 | 119 | pushed | oneshot, 6 REDO rounds |
| bar (plan, WP1) | 0.60 | 5 | | 100 | yes | |
| BMad, feature | 0.35 | 2.8 | 34 | 56 | local commit | followed |
| loop-spec c2fc8b9, feature | 3.97 | 30.0 | 201 | 768 | no | VERIFY infra error |
| loop-spec dda2cca, feature | 0.18 | 1.3 | 21 | 0 | no | never began a cycle |

On the bug fix the final head is five times the bar on cost, three times on time, and
2.4 times on artifact lines. It is worse than the WP1 commit on cost and time because
one phase per invocation now runs SPEC and ONESHOT in two sessions, and each session
loads its full context. The phase split is right for the full route. On the short route
it doubles the fixed cost.

The feature run did not fail inside the cycle. It failed to enter one. The details are
in F1 below.

Code quality on the bug fix is unchanged: the same correct two-line fix, this time with
single quotes on lines whose neighbors use double quotes. VERIFICATION.md is 80 lines
with file and line grounding for a two-line change.

## Scorecard against the plan

| package | state | evidence |
|---|---|---|
| WP0 spec path | partial | The lead itself wrote SPEC.md to the main checkout again on the dda2cca run. The new deny in `hooks/restrict-agent-paths.sh` covers only `spec-writer` and `planner` subagents. The `[misplaced]` flag in `lib/phase-exit.sh` caught it one round later. |
| WP0 floor veto to VERIFY | done differently | Routing works, but `lib/iterate-judged.sh` picks `verify` versus `execute` by grepping the literal string `still FAIL` from `lib/converged-floor.sh`. No test pins that coupling. |
| WP0 clean candidate | done | `lib/verification-baseline.sh` skips `docs/loop-spec` and `.loop-spec`. |
| WP0 state off the branch | done | `refs/loop-spec/state/<slug>` via `lib/state-ref.sh`. The test counts commits in a synthetic repo, not on a delivered branch. |
| WP0 .gitignore | done | Pinned. |
| WP0 eval check and judge | done | Judge removed. The `json_test_added` check still greps a substring. |
| WP1 probe and node | done | `lib/graph/probes/oneshot.sh` fails safe to full and never demotes. The footprint it reads is a model-written list. |
| WP1 exit gate | done, fail-open in two places | `lib/oneshot-exit-gate.sh` exits 0 for any `route=full`, including unreadable frontmatter. Footprint check is skipped in workspace mode. Footprint is enforced one way only: named files must be in the diff, but the diff may exceed the footprint. |
| WP1 pass bar | not met | Table above. |
| WP2 vocabulary from graph | partial | `lib/graph/phases.sh` is the source. Literal subsets remain in `lib/phase-mode.sh`, `lib/graph/driver.py` line 1377, and `hooks/team/placeholder-question-guard.sh`. |
| WP2 gates on nodes | done | `ingress` and `egress` per node. `tests/lib/graph-phases.test.sh` adds a phase to a graph copy but never runs `validate.py` or driver routing on it. |
| WP3 typed reader | done | `lib/feature_read.py` over the schema enum. |
| WP3 zero raw reads | not done | Five scripts still parse `feature.json` directly: `lib/pause-snapshot.sh`, `lib/ralph-remediation.sh`, `hooks/team/task-completed.sh`, `lib/cycle-reconcile.sh`, plus hash reads in `lib/graph/checkpoint.sh` and `lib/graph/port-local.sh`. The coverage test's regex needs the reader and the path on one line, so all five slip past. |
| WP3 semantics | changed, unpinned | `--all` drops any key outside the enum silently. Rewind now fires for any phase the graph lists earlier, so `iterate` to `verify` prints `REWIND`, which it did not before. Two scripts lost their jq-absent fallback. |
| WP4 Python driver | done differently | `lib/graph/driver.py`, 1,434 lines. `lib/cycle-driver.sh` is a 13-line shim, not deleted. Nothing records that exception. |
| WP4 one phase per invocation | done | Driver, `hooks/team/phase-handoff-guard.sh`, and `hooks/team/nested-session-guard.sh`. The dda2cca run shows the guard denying a second phase, as designed. |
| WP4 cycle skill as launcher | not done | `skills/cycle/SKILL.md` grew from 204 to 223 lines. |
| WP5 session layer | done differently | `extensions/sessions/session_run.py`, 216 lines from scratch, with an MIT notice naming what was taken. No hook relay; process exit is the only signal. No vendored tests; the new test skips below Python 3.11. |
| WP5 session rung in the driver | not done | `lib/execute-rung.sh` selects the rung. The spawn is prose in `skills/shared/execute-rungs.md`. The driver has no reference to it. |
| WP6 spec shape | done | Two shapes in `lib/artifact-lint.sh`. The live run still hit an H1 flag on the oneshot shape on its first draft. |
| WP6 review triage | done | `lib/review-triage-lint.sh`, wired as a VERIFY gate and in the oneshot exit gate. It scans only between `## Code review` and a `### Findings` heading, and its location regex accepts any `word:digits`. |
| non-goals | amend | `extensions/sessions/NOTICE` must name BMad. The plan's wording should allow attribution files. |

## Required follow-up, in order

Each item names the evidence, the file, and the done condition. The first six move the
bar. The rest make the landing durable. Do them in this order.

### F1. A cycle invocation must begin a cycle or refuse

Evidence: the dda2cca feature run. The prompt was `/loop-spec:cycle autonomous add a
--json flag ...`. The skill loaded. The lead's first line was `MICRO:`, it edited
`wc_tool.py` in place, wrote three entries to `.loop-spec/adhoc-ledger.md`, and stopped
with uncommitted changes, no branch, no result file, and no `begin` call. The eval
scored it 2 of 4 and undelivered.

Cause: `hooks/team/micro-inject.sh` runs on SessionStart and injects the ad-hoc micro
protocol whenever `.loop-spec/` exists and `LOOP_SPEC_AUTONOMOUS=1` is not in the
environment. The eval passes `autonomous` as a prompt token, and `child_env` strips
every `LOOP_SPEC_*` variable, so the directive fired. The cycle skill then loaded on top
of it. Two directives, and the model followed the one that needs no driver call. The
conflict exists at c2fc8b9 too. The new lead prose, "You are the lead of one phase",
made it more likely to lose.

Fix, all deterministic:

- `hooks/team/invocation-stamp.sh` already writes `.loop-spec/invocation-stamp.json`
  with `skill: cycle` at prompt time, and `driver.py start` consumes it. Add a Stop hook
  that denies when a stamp with `skill: cycle` is still present and no
  `.loop-spec/last-result.json` newer than the stamp exists. The message names the
  `begin` call. A model that skips the driver cannot stop.
- `micro-inject.sh` must stand down when the session is headless. Add a probe to
  `lib/harness.sh` that answers `attended=0` when stdin is not a terminal or
  `CLAUDE_CODE_ENTRYPOINT` says `sdk-cli`, and gate the injection on it. Fail safe
  means inject only when attended is proven.
- `evals/eval_run.py` records a new field, `cycle_begun`, true when the driver wrote
  `feature.json`, and the summary reports a run with `status: null` as "no cycle", not
  as a plugin result.

Done when: a haiku `wc-json` run on the fixture reaches DELIVER, and a new test under
`hooks/team/` drives a transcript with an unconsumed cycle stamp into the Stop hook and
asserts the deny.

### F2. The short route is one session, not two

Evidence: the dda2cca bug fix ran SPEC in one session (0.50 USD, 49 turns, 233 s) and
ONESHOT in another (0.76 USD, 68 turns, 335 s). BMad's whole path is one session at
0.23 USD. The fixed cost of a session on the short route is most of the bill.

Fix: give the `human.after-spec` decision to a probe that runs inside SPEC's session.
When `oneshot.sh` answers `route=oneshot`, the driver answers `NEXT phase=oneshot` in
the same invocation instead of `HANDOFF`. The one-phase rule in
`hooks/team/phase-handoff-guard.sh` gains one exception, data on the graph edge
(`"sameSession": true`), never prose. The full route keeps one phase per invocation.

Done when: a haiku `slugify-bug` run is one round to `pushed-no-pr`, and
`tests/lib/graph-run.test.sh` pins that the `spec` to `oneshot` edge does not hand off.

### F3. Cut what the short route loads

Evidence: on the short route the lead reads `skills/cycle/SKILL.md` (223 lines),
`skills/spec/SKILL.md` (209) and the six shared contracts it cites (730), then
`skills/oneshot/SKILL.md` (114) and its contracts (about 580), after six SessionStart
hooks inject their directives. About 1,850 lines against BMad's 475 for the same job.

Fix:

- A `spec-lite` body for the oneshot candidate: the scout stops at the footprint, runs
  no `docs-probe` or `doc-deps`, and cites `grounding-protocol.md` by section, not
  whole. Select it with the same probe as F2, before the interview.
- Every SessionStart injection except `rules-inject.sh` stands down in headless
  sessions, using the F1 probe.
- Add a new probe under `lib/`, `context-load.sh`, that sums the lines of every file a
  phase skill cites transitively, and a test that fails when the oneshot path exceeds
  600 lines.

Done when: that test is green and the bug-fix run is at or under 0.25 USD.

### F4. Zero format rounds on the short route

Evidence: six REDO rounds on the dda2cca bug fix. SPEC: artifact unreadable, misplaced
copy, H1 title missing on the oneshot shape. ONESHOT: footprint named
`tests/test_slugify.py` twice, then a grounding-line format flag. Each round is a full
lead turn with the whole context.

Fix:

- The driver writes the skeletons. `driver.py` emits `SPEC.md` and `VERIFICATION.md`
  with the frontmatter, headings, and grounding rows already in the shape the gates
  accept, and the lead fills values. A gate that flags a shape the driver wrote is a
  driver bug with a test, not a REDO.
- The footprint excludes any file the task marks protected or the SPEC marks read-only,
  and the probe reads `footprint` from the scout's evidence file, not from prose the
  lead retypes. A footprint entry that is not in the diff is dropped with a note by the
  gate, not bounced to the lead, when the file is unchanged and tests pass.
- `tests/fixtures/oneshot-SPEC.md` is the exact text the skill shows the lead, inline,
  and `tests/lib/artifact-lint.test.sh` runs that fixture through both the spec lint
  and `lib/oneshot-spec-lint.sh`.

Done when: a bug-fix run records zero REDO rounds whose flags are format flags
(`artifact-lint`, `verification-grounding`, `misplaced`).

### F5. The spec is written where the gate reads it, by construction

Evidence: the same `SPEC.md` misplacement as the 9 September run recurred on dda2cca.
The WP0 deny covers subagent roles. On the short route the lead writes the spec itself.

Fix: SPEC writes through the driver, `driver.py spec write --file <path>`, which resolves
the feature dir from the ref and refuses any other target. The path deny in
`hooks/restrict-agent-paths.sh` extends to the main agent while a feature is active,
for `docs/loop-spec/features/**` outside the feature's checkout. Both are needed: the
driver path is the happy path, the hook is the guard.

Done when: the test the plan asked for exists. It runs the SPEC exit gate from a
worktree whose parent checkout holds a stale feature directory and asserts the gate
reads the worktree copy.

### F6. Close the two fail-open paths in the oneshot gate

Evidence: `lib/oneshot-exit-gate.sh` line 26 exits 0 on any `route=full`, and the
probe answers `full` for every input it cannot read. The footprint check is skipped
whenever `ws_root` is set. Neither ships code unchecked today, because `full` routes to
DISCUSS, but a gate that passes on an unreadable input is the failure class the
determinism audit exists to remove.

Fix: on `route=full` the gate still runs the placeholder and tamper scans and the
verification lints, and skips only the footprint and intent checks. In workspace mode
the footprint check runs per repo. Add the second direction: the diff may not touch a
file outside the footprint, or the gate answers `route: full` with the file named.

Done when: `tests/lib/oneshot-exit-gate.test.sh` carries a case for each: unreadable
frontmatter, workspace mode, and a diff file outside the footprint.

### F7. Finish WP3

- Migrate the five raw readers named in the scorecard.
- Replace the coverage regex with a two-pass scan: collect every variable bound to a
  path ending in `feature.json`, then flag any `jq`, `python3 -c`, `cat`, `<`, `awk`,
  `sed`, or `grep` line that uses one of them. Cover `skills/` prose too.
- `feature_read.py --all` fails on a stray key with the key named. A dashboard that
  shows `null` for a key the writer set is the silent failure `failure-tells.sh` exists
  to catch.
- Pin the rewind rule: a test that runs `iterate` to `verify` through the driver and
  asserts `REWIND next=verify`, so the protocol change is on record.

### F8. Finish WP5

- Move the session spawn into `driver.py`: an agent node with `rung=session` is
  launched by the driver through `extensions/sessions/session_run.py`, and the lead
  never sees the command. The prose in `skills/shared/execute-rungs.md` becomes a
  description of what the driver does.
- `hooks/team/nested-session-guard.sh` allow-lists by exact launcher path, not by
  substring anywhere in the command, and the script scan stops skipping files that
  merely mention a launcher name.
- Record the vendoring decision in the plan: the adapters were not vendored because
  their import closure reaches bmad-loop's run and verify modules. The plan still says
  "vendor". Either is fine. The document must match the tree.
- The `LOOP_SPEC_NON_INTERACTIVE=1` done condition is unverified. Run both fixtures
  through the session rung on Claude Code and record it, or mark WP5 partial in the
  plan.

### F9. Finish WP2

- Derive the subsets in `lib/phase-mode.sh`, `lib/graph/driver.py` line 1377, and
  `hooks/team/placeholder-question-guard.sh` from node fields on the graph, or pin them
  with a test that reads the graph.
- `tests/lib/graph-phases.test.sh` runs `lib/graph/validate.py` on its graph copy with
  a stub SKILL.md and steps the driver through the new phase once.

### F10. Pin the couplings the port added

- `lib/iterate-judged.sh` and `lib/converged-floor.sh` share the literal `still FAIL`.
  Either the floor emits a `FLOOR result=fail-row|no-fail-row` token the judge reads,
  or a test asserts the string in both files.
- `lib/review-triage-lint.sh` scans the whole `## Code review` section regardless of
  subheadings, and the location regex requires a path separator or a known extension.
- The state-ref test counts commits on a branch that a driver-driven cycle delivered,
  as the plan asked, not on `main` in a synthetic repo.

### F11. Docs that the port made false

- `llms.txt` line 18 and `docs/loop-spec/configuration.md` line 197 still tell the
  reader to set `LOOP_SPEC_PHASE_HANDOFF=1`. The variable is gone.
- The marker string `LOOP_SPEC_PHASE_HANDOFF` printed by `skills/cycle/SKILL.md` and
  read by the nested-session guard now means something else than the removed variable.
  Rename the marker.
- `skills/cycle/SKILL.md` is 223 lines. The plan said launcher. Either cut steps 1 to 3
  into the driver's `begin` output or record why the skill keeps them.
- `lib/cycle-driver.sh` survives as a shim. Record that in the plan's WP4 as the
  chosen exception, with the reason (about forty callers keep one path).
- Amend the plan's non-goal: attribution files may name BMad.

### F12. One decision for the maintainer, not the agent

`lib/checkpoint-pr.sh` pushes `refs/loop-spec/state/<slug>` to `origin` on the
checkpoint push. That puts run state on a shared remote. It is documented in the 6.4.0
changelog, so it is a choice, not a defect. Confirm it is wanted, or make it opt-in.

## Pass bar, restated

Unchanged from the plan, measured with `evals/run.sh` on haiku, one round, delivered:

| task | cost USD | artifact lines | minutes |
|---|---|---|---|
| slugify-bug | 0.25 | 50 | 3 |
| wc-json | 0.60 | 100 | 5 |

F1 through F6 are the path to it. F2 and F3 are where the money is.

## Reproduce

From a checkout at dda2cca, with `claude` on PATH and signed in:

```bash
LOOP_SPEC_EVAL_LIVE=1 bash evals/run.sh --model haiku --tasks slugify-bug,wc-json \
    --parallel 2 --run-id port-haiku --confirm-spend
```

The two runs above cost 1.44 USD together. The full offline suite at dda2cca:

```bash
bash tests/run-all.sh
```

226 suites passed, 0 failed.
