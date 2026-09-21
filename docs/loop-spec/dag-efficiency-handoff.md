# Further DAG token and latency savings

Continue reducing the context and coordination cost of the full DAG workflow without weakening its acceptance checks. This handoff records the September 20, 2026 live run and gives the next session a bounded investigation plan.

## Starting state

- Repository: `/Users/aztechead/Projects/loop-spec`.
- PR: [#108](https://github.com/aztechead/loop-spec/pull/108), branch `perf/efficiency-levers`.
- Reviewed implementation commit: `035ce65` (`perf: streamline planner handoff and task context with reviewed gate fixes`). Check current branch and remote state before editing; these identify the handoff baseline, not a promise that the PR remains open.
- The user wants lower token usage and faster movement between phases. The user approved the focused PLAN optimization in PR #108 and asked for this document so another session can pursue further savings.
- Previous working arrangement: Luna implements; the lead reviews actual diffs and runs validation. Retain that arrangement unless the user changes it.
- Read applicable repository instructions and `/Users/aztechead/.codex/RTK.md`. Shell commands must start with `rtk`.

## Continuation status — 2026-09-21

- The user authorized live testing and expanded this work to fix verification and recovery root causes. Changes harden the plugin across projects; application-specific acceptance probes remain in ignored evaluation fixtures.
- Shared README ownership is decided during authoring. PLAN critique entry and phase exit use the same structural check, including batching, file exclusions, cycle rejection, and the explicit small-plan width floor.
- Live planning comparisons completed. Both candidate runs passed their repository checks but failed independent contract acceptance. Preserve those failures alongside the exploratory planning measurements in `inbox/pr108-efficiency/ownership/VALIDATION.md`; do not count them as successful full deliveries.
- VERIFY now dispatches a frozen assignment containing the complete verifier and grounding contracts, exact validation results, and repository revisions. Verification checks observable contracts against SPEC and binding decisions, including generated artifacts and assertion adequacy. Non-API positive and negative live cases exercise this behavior.
- Recovery uses the current feature's canonical task sidecar. State restore rebases its locator; stale cached preparation is refused. Remediation shape and inline command integrity are validated before publication. Failed integration checks retain their evidence and use the bounded fix loop instead of immediately claiming retry exhaustion.
- The last live recovery run detected the missing contract, then exposed a faulty coordinator-authored check. It was stopped. The user ended live testing and requested publication; no further run is authorized. Final fixes preserve the verifier's reproducer, prevent adapting correct code to a faulty check, and support one evidence-backed generated-command repair with fresh review. End-to-end live acceptance of these final fixes is unproven. Failed and interrupted attempts, manifests, transcripts, costs, and offline results remain under `inbox/pr108-efficiency/verification-hardening/`.
- Final offline validation passes with unchanged read-set ceilings. The user requested publication and goal completion without another live attempt. Keep source snapshots immutable and preserve every attempt; detailed live findings and metrics belong in the ignored evidence directory.

At the September 20 checkpoint, the implementation passed 257 offline suites with zero failures or skips. Runtime was 216 seconds; the runner printed an aspirational 157-second ceiling. That ceiling was not raised. Three live Python 3.14 FastAPI scenarios passed their app tests, lint, and independent acceptance checks.

## What already changed

Do not count these improvements again as new work:

| Change | Before | After | Evidence type |
| --- | ---: | ---: | --- |
| PLAN coordinator preparation | 113.407 s / 12 tool calls | 24.723 s / 4 calls | Separate live PLAN comparison |
| Planner assignment, including referenced brief | 5,839 bytes | 2,426 bytes | Transcript and brief sizes |
| PLAN coordinator read set | 779 lines | 447 lines | Static read set |
| Code-task read set | 44,209 bytes | 36,114 bytes | Renderer regression fixture |
| Documentation-task read set | 31,174 bytes | 26,405 bytes | Renderer regression fixture |

`lib/graph/driver.py` now creates PLAN's dispatch packet after successful ingress. The lead passes its prompt file to the planner instead of rebuilding the assignment and rereading planning policies. The packet includes approved source paths, snapshot contracts, templates, model, budget, and reentry feedback.

`lib/dispatch-files.sh` renders selected normative sections from engineering-directives and laziness-ladder. It retains source pointers and fails when a required section is missing. Implementers read the bundle once. Version evidence, TDD, all seven laziness rungs, required probes, and safety exceptions remain binding.

Other completed fixes include width-aware resource defaults, batch-collapsed width with raw cycle validation, grouped reviewer contracts, compact classification persistence, critique precedence, jq-less handoff parity, atomic Python shim replacement, spec-lite grounding instructions and immediate linting, and interruption-safe subprocess cleanup. Inspect the commit before reopening these issues.

The full DAG run below used `plugin-run4`, which predates the final PLAN packet and bundle reductions. The packet received a separate live benchmark; the reduced bundles received semantic and size regression checks. Current live evidence and follow-up runs remain tracked with PR #108 and the ignored `inbox/pr108-efficiency/` evidence.

## Full DAG baseline

The fixture implemented GET and POST item endpoints against existing shared contracts and storage. GET required pagination and query validation; POST required trimmed names, duplicate rejection, and monotonic IDs. README examples and OpenAPI coverage were also required. Authentication, persistence, and external services were excluded.

Environment: Python 3.14.7, FastAPI 0.141.1, httpx 0.28.1, pytest 9.1.1, ruff 0.16.8, uvicorn 0.53.0. The CLI reported `claude-sonnet-5` for this run. The full route was forced, session layer disabled, and implementer and subagent bounds left unset so width defaults were exercised.

| Phase | Event elapsed | Corresponding CLI invocation | Reported invocation cost | CLI turns |
| --- | ---: | ---: | ---: | ---: |
| SPEC | 558 s | 672.165 s | $2.6822350 | 62 |
| PLAN | 904 s | 898.884 s | $2.2137566 | 43 |
| EXECUTE | 639 s | 640.736 s | $3.4345878 | 52 |
| VERIFY | 441 s | 438.932 s | $2.1769381 | 35 |
| ITERATE | 109 s | 108.423 s | $0.6594937 | 16 |
| DELIVER | 37 s | 47.063 s | $0.2864004 | 8 |

Invocation durations total **2,806.203 seconds (46.8 minutes)** and costs total **$11.4534116**. Event durations and CLI durations have different boundaries: phase transitions can be recorded by the preceding invocation, and CLI time includes startup and final output. Do not subtract their individual rows to infer precise handoff cost. Event session identifiers can likewise name the transitioning session rather than the session doing the next phase's work.

Aggregated CLI usage:

| Field | Count |
| --- | ---: |
| Input tokens | 654 |
| Cache creation input tokens | 1,184,168 |
| Cache read input tokens | 25,093,343 |
| Output tokens | 259,907 |
| Thinking tokens, separately reported | 92,031 |

These are provider-reported counters. Cached reads aggregate repeated context processing, not unique text. Do not add thinking tokens to output without checking the provider's accounting. Root CLI usage includes in-process agents; summing those agent transcripts again would double-count usage. Costs exclude interrupted setup attempts and the separate PLAN benchmark.

### Concurrency and correctness

- The plan contained two ready endpoint tasks with disjoint file ownership, followed by documentation task-003.
- Prepare resolved width 2, implementer cap 2, subagent cap 2, and the subagent rung with lead-worktree isolation.
- Both implementer calls were in assistant message `msg_011CfFsyfGga5ndVZhm78LXu`.
- GET ran from `03:32:49.145` to `03:34:45.112` UTC; POST ran from `03:33:13.062` to `03:35:06.208`. They overlapped for approximately 92 seconds.
- One grouped reviewer covered task-001 and task-002. The documentation task used the supported singleton grouped-review format.
- Final checks: 13 tests passed, lint passed, independent API acceptance passed.
- Final app SHA: `ce58ff817c40572d695016f0f1cb4f5d15094d98`.
- Final result: `completed/pushed-no-pr`, `implementationConverged=true`, `converged=false`, `workDelivered=false`. The fixture used a local bare remote. GitHub PR creation and readiness were outside this test.

### Known noise and useful signals

SPEC recorded two delta critique rounds. PLAN recorded one single-critic round and one delta round. Inspect the findings and edits before treating any round as redundant: the counters alone do not establish waste.

Documentation verification hit `rg: command not found` in the curated child environment. The lead recovered with equivalent grep checks and synchronized the plan and sidecars. This recovery contributes to EXECUTE time. Ensure the executable, rather than merely a shell function, is available in future fixture PATHs.

Earlier attempts were stopped because of fixture problems: baseline tests forbade the requested endpoints, a shared model created a serial dependency, and a wide fixture pointed at the wrong origin. They are not successful runs or evidence of plugin speed. The valid `wide-final` fixture was cloned from the corrected origin with the shared model already present.

## Next investigation, in order

### 1. Attribute expensive work before changing policy

Build a compact trace analysis from the existing run before spending on another model run. For each phase, identify first tool call, ingress completion, first worker dispatch, worker completion, review, revision, exit, and next-session startup. Report unknown spans explicitly.

Group reads by resolved file and content digest. Count repeated reads within a role and shared context sent to multiple roles. Separate tool output, assignment text, artifact content, and model-generated output. Measure bytes where tokenizer counts are unavailable and label them accordingly.

Deliver a ranked table of avoidable candidates with the supporting transcript events. Avoid importing entire raw transcripts into model context; use a script to extract timestamps, tool names, paths, byte counts, and narrowly selected excerpts.

### 2. Inspect PLAN and critique first

PLAN consumed 904 event seconds and produced two critique rounds. The new packet addresses preparation; it does not establish that authoring or critique is efficient. Its separate optimized benchmark still took 858.734 seconds through normal planning and review, costing $2.2723554.

Inspect repeated policy/template reads, repeated serialization of the same plan, and whether delta review actually consumes the relevant changes plus necessary context. Determine whether avoidable format or contract corrections caused another round. Prefer deterministic validation at the authoring boundary when it can prevent a model retry.

Starting points: `skills/plan/SKILL.md`, `lib/graph/driver.py`, `lib/critique-step.sh`, `skills/shared/critique-gate-protocol.md`, and `lib/graph/probes/plan-critique.sh`.

### 3. Inspect EXECUTE coordination after accounting for recovery

EXECUTE was the most expensive invocation despite working concurrency. Separate endpoint implementation, grouped review, publication, documentation work, and the missing-rg recovery. Look for the lead rereading implementation contracts already supplied to workers, verbose worker returns, repeated status discovery, and task material repeated in reviewer packets.

Potential changes are hypotheses: smaller structured completion reports, source pointers instead of copied prose, or deterministic preparation for another role. Preserve per-task verdicts, evidence needed to review the change, and explicit failure handling. Do not increase concurrency blindly; this fixture already used both ready endpoint tasks.

Starting points: `lib/execute-prepare.sh`, `lib/dispatch-files.sh`, `skills/shared/execute-subagent.md`, `agents/implementer.md`, and `agents/spec-compliance-reviewer.md`.

### 4. Audit VERIFY and ITERATE evidence reuse

VERIFY used 441 event seconds and $2.18; ITERATE used another 109 seconds and $0.66. Determine which work found a real gap and which work repeated existing acceptance evidence or repository discovery. Inspect actual code changes between phase SHAs before proposing a shortcut.

Any reuse must bind evidence to the tested code revision, command, environment, and relevant inputs. A changed revision or missing evidence must trigger the required check. Do not replace independent review with an implementer's unsupported success statement.

Starting points: `lib/verify-prepare.sh`, `lib/verify-passes.sh`, `skills/verify/SKILL.md`, `skills/iterate/SKILL.md`, and `lib/iterate-judged.sh`.

### 5. Measure context and session boundaries

The run accumulated 25.1 million cached input tokens across six CLI invocations. Investigate which repeated material is actually read or inserted into prompts. Snapshot directory size alone is not evidence of model-token cost.

Keep fresh-session isolation where required. Before combining phases, measure startup latency and identify the correctness contract the boundary enforces. Prefer shrinking the incoming packet over carrying an entire preceding conversation forward.

Starting points: `lib/context-load.sh`, `lib/phase_snapshot.py`, `extensions/sessions/session_run.py`, and `tests/dispatch-read-set.test.sh`.

## Efficient validation plan

1. Preserve the existing evidence before editing or rerunning. Local `/tmp` paths are ephemeral; copy required fixtures, raw results, and transcripts to a durable local directory if still present. Keep raw transcripts out of Git unless reviewed for sensitive content.
2. Analyze the old trace and choose one bounded change with a measurable mechanism. Do not launch several exploratory full runs.
3. Create a clean fixture from the correct shared-contract seed. Verify `HEAD == origin/main`, `ItemOut` exists, baseline tests are neutral, endpoint ownership is disjoint, and Python 3.14, Claude, Git, and required executables are available inside the child PATH.
4. Establish the current implementation's baseline before attributing new savings. Use identical fixture, prompt, model, bounds, and route for a candidate comparison. Record source commit or snapshot digest and cache conditions. If budget only permits one candidate run, label the comparison exploratory.
5. Run focused semantic and context-budget checks, then the required full offline suite after implementation stabilizes. Avoid repeatedly running the whole suite without a new change or concern.
6. Use a phase-only live comparison when it answers the question. After the change is stable, run one complete DAG scenario and verify actual overlap, grouped verdicts, app tests, lint, and independent acceptance.
7. Report phase and invocation timings separately, model-reported cost and token categories, context bytes, retry reasons, and correctness outcomes. Report all attempts and stop spending once the evidence answers the question.

Retain security/oracle critique requirements, explicit full-review overrides, dependency-cycle rejection, resource bounds, version evidence, TDD, required probes, and delivery-state truthfulness. Fixing duplicated work is within scope; removing these requirements is not an assumed optimization.

The next session should finish with a reviewed implementation, focused regression evidence, a before/after measurement with limitations, and an updated handoff if work remains. Do not claim a target percentage until the trace supports it.

## Evidence map

Primary local root: `/tmp/loop-spec-pr108-live` (also accessible as `/private/tmp/loop-spec-pr108-live` on this machine).

| Path under root | Contents |
| --- | --- |
| `VALIDATION.md` | Previous complete validation report |
| `wide-summary.json` | Raw extracted events, prepare packet, and session usage |
| `wide-final/.loop-spec/sessions/` | Six CLI stdout/stderr pairs with usage and results |
| `wide-final/.loop-spec/last-result.json` | Final delivery and verification state |
| `wide-final/.loop-spec/features/` | Feature state, events, dispatch packets, instruction snapshots |
| `full-wide.txt` | Exact wide-run request |
| `origins/full-wide.git` | Correct local fixture remote |
| `plugin-run4.patch` and `plugin-run4.base` | Full-run plugin changes and base |
| `plugin-plan-packet.patch` and adjacent base | Separate PLAN benchmark source |
| `plan-packet-bench/repo/` | Completed optimized PLAN benchmark |
| `acceptance.py` | Independent app acceptance checker |
| `summarize.py` | Extracts raw run evidence; does not infer success |
| `final-offline-tests.log` | 257-suite passing run |

Wide fixture seed: `fa91b47ee35e6bef2a94e1099475cb00f9534643`. Create a separate local remote at this seed for a rerun; the original bare remote also contains completed-run branches. Do not reset or overwrite the preserved run.

Raw full-run Claude transcripts are under `/Users/aztechead/.claude/projects/-private-tmp-loop-spec-pr108-live-wide-final/`. Match their content and CLI session results to phases; do not rely only on the event's session field. Known files include SPEC `996dc3c7-c91b-4feb-ac50-e113dba9fcff.jsonl`, PLAN `f865db81-9348-4029-aa1e-8cb9dc844afe.jsonl`, and EXECUTE `c3168543-3672-4d25-8912-1d3978d80b3f.jsonl`.

The PLAN preparation comparison used these transcripts:

- Baseline: `/Users/aztechead/.claude/projects/-private-tmp-loop-spec-pr108-live-full-run/e3e7dc02-a5b3-4932-a1ac-5f95901b408e.jsonl`.
- Optimized: `/Users/aztechead/.claude/projects/-private-tmp-loop-spec-pr108-live-plan-packet-bench-repo/6b433f4b-22fa-444e-a9cc-11086db4a84f.jsonl`.

If local evidence has expired, the measurements above remain the recorded baseline, but detailed attribution must be regenerated. Do not reconstruct missing transcript facts from the summary.

## Related research

The earlier session reviewed [Matt Pocock's handoff skill](https://github.com/mattpocock/skills/blob/main/skills/productivity/handoff/SKILL.md) and [writing-for-agents skill](https://github.com/mattpocock/skills/blob/main/skills/productivity/writing-for-agents/SKILL.md). The applicable ideas were artifact pointers, conditional references, and avoiding duplicate meaning. Recheck upstream content before adopting further instructions. Exhaustive interviewing is not assumed to save tokens.
