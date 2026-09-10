# Orchestrator port: tactical plan

For the agent driving PR 94 and the work after it. This document has one job: turn the
9 September 2026 head-to-head against BMad into an ordered list of changes, each with
the file it lands in and the test or number that proves it landed. The evidence section
is short on purpose. It exists so you can check a claim, not so you can re-run the
argument.

The decision it carries: keep loop-spec as the tree, move the loop out of the lead model
into the graph engine, take BMad's right-sizing route as phase content, and vendor
bmad-loop's session layer for headless runs. Do not fork BMad Method. Its control plane
is prose, and a graph over its step files is this repository's graph with different
bodies.

## Evidence

Live head-to-head on Claude Code, model haiku, plugin at PR 94 head `c2fc8b9`, BMad
Method at `abe4eb1` (6.13.0-next), bmad-loop at `c47333d` (0.11.1). Fixtures and
acceptance scripts are `evals/tasks/slugify-bug` and `evals/tasks/wc-json`. The control
is a bare `claude -p` with the same tools and permission mode and no plugin. Every run
passed its acceptance script. Records are in the session that ran them and are not
committed, per `evals/README.md`.

| run | cost USD | minutes | turns | artifact lines | own process followed | delivered |
|---|---|---|---|---|---|---|
| bare CLI, bug fix | 0.06 | 0.5 | 9 | 0 | none | local commit |
| bare CLI, feature | 0.09 | 0.7 | 15 | 0 | none | local commit |
| BMad, bug fix, sample 1 | 0.10 | 0.6 | 14 | 0 | no: skipped spec, review, commit | driver committed |
| BMad, bug fix, sample 2 | 0.23 | 1.8 | 26 | 43 | yes | local commit |
| BMad, feature | 0.35 | 2.8 | 34 | 56 | yes | local commit |
| loop-spec, bug fix | 0.68 | 3.9 | 64 | 213 | no: escalated in SPEC | no |
| loop-spec, feature | 3.97 | 30.0 | 201 | 768 | no: VERIFY infra error | no |

Sample size is one or two runs per cell. Read it as a signal.

What the code looked like, from reading every diff:

- All four bug fixes are correct and two lines or fewer. BMad sample 2 is the best one:
  its reviewer proposed one regex instead of two, the triage applied that and rejected
  five noise findings with reasons.
- All three feature implementations are near-identical and correct. The control added no
  tests. BMad added two precise tests. loop-spec added three, including the error path,
  and its VERIFICATION.md maps eight criteria to file and line. That traceability is the
  best of the set.
- BMad's deferred-work file for the feature holds one false finding written as a durable
  backlog item: it calls newline counting an off-by-one, which is what `wc` does.
- loop-spec's SPEC.md for the two-line fix is 111 lines and carries a self-answered
  interview transcript and self-graded ambiguity scores.

Defects the PR 94 build showed in these two runs:

1. The spec-writer wrote `SPEC.md` under the main checkout's `docs/loop-spec/features/`
   while `lib/phase-exit.sh` ran in the feature worktree and reported the artifact
   unreadable. The lead spent four attempts and three chore commits on the path, then the
   cycle escalated. The code fix landed anyway.
2. The feature cycle passed ITERATE as converged, then `lib/converged-floor.sh` refused
   the verdict because it could not parse the acceptance table. The lead rewrote
   VERIFICATION.md to fit the parser, the driver rewound to EXECUTE with no tasks left,
   and VERIFY then failed with `baseline comparison requires clean candidate state`.
   Minutes 12 to 30 of that run were the process arguing with its own gates.
3. Ten of seventeen commits on the feature branch are state and docs commits
   (`state @ verify`, `update feature state`). They would land in the PR.
4. The cycle appended two negation lines for plugin-internal paths to the project's
   `.gitignore`.
5. `evals/tasks/wc-json/check.sh` greps `tests/` for the substring `json` after running
   the tests, so compiled bytecode in `__pycache__` satisfies it. The control's fourth
   check was a false pass.
6. The eval judge scored every run 3 of 3 on request match. It does not discriminate.

## Target architecture

Three layers. No single repository has all three today.

- **Control plane: this repository's graph and probes.** `graph/cycle.graph.json` is data:
  28 nodes of five kinds, 63 edges of five kinds, route conditions that name a probe and
  an expected token, validated by `graph/schema.json` and `lib/graph/validate.py`.
  `lib/graph/engine.py` already walks it. The probe corpus under `lib/` speaks one
  contract (FLAG lines, one ANSWER and REASON line, exit 0, 1, or 2) and
  `lib/converged-floor.sh` is the pattern every gate should follow: a script may veto a
  model verdict and may never assert one.
- **Session layer: bmad-loop's adapters and plugin bus, vendored under MIT.** Six coding
  CLIs sit behind one eight-method abstract class with TOML profiles and entry-point
  registries (`src/bmad_loop/adapters/`, about 8,600 lines), plus a plugin bus with 36
  lifecycle stages that can veto (`src/bmad_loop/plugins/`, about 1,700 lines). A session
  takes an opaque prompt, so a session can run any phase body. This layer is what
  loop-spec lacks: today every agent node is dispatched by the lead model through the
  harness's agent tool.
- **Phase content: the skills, plus BMad's right-sizing route.** `skills/*/SKILL.md`
  bodies are phase prompts and survive unchanged. BMad's `bmad-build/step-02-plan.md`
  decides ceremony after a short investigation, not before: no intent gaps, nothing
  irreversible, small footprint, then one short spec and straight to implement. That
  route is why BMad's bug fix cost 0.23 USD and 43 artifact lines.

What this deletes from loop-spec: `lib/cycle-driver.sh` (1,080 lines of bash that exist
because a bash driver was cheaper to call from a skill than a Python one), the 61 `lib/`
scripts that hand-parse `feature.json` with their own `jq` paths, and most of the 194
`LOOP_SPEC_*` variables. `skills/cycle/SKILL.md` shrinks to a launcher.

What this keeps of bmad-loop: nothing above its session layer. Its engine is one class
of 171 methods across 7,900 lines, its pipeline is encoded four separate times, and it
has no push or pull-request code. That is why the fork target is not bmad-loop either.

Why loop-spec stays the base: only its shape runs both ways. In-harness for a person at
the keyboard in Claude Code, Codex, opencode, or ADK, stepping one phase per session
through phase-handoff (`cycle-driver.sh` line 76). Headless through the vendored session
layer. bmad-loop is headless-only by construction: it spawns CLIs under tmux and cannot
mount in ADK.

## Work packages, in order

Each package names its done condition. Do not start the next until the previous one's
condition holds. Packages 0 and 1 are the ones that move the pass bar; the rest make the
result durable.

### WP0: fix what the run showed

- **Spec path.** The spec-writer resolves `docs/loop-spec/features/{slug}` against the
  feature worktree, never the session cwd. Pin it: a test under `tests/` that runs the
  SPEC exit gate from a worktree whose parent checkout also holds a stale feature dir,
  and asserts the gate reads the worktree copy. Defect 1.
- **Converged-floor parse.** `lib/converged-floor.sh` accepts the table shape
  `lib/artifact-lint.sh` already accepts, or `artifact-lint` refuses the shape the floor
  cannot read. One of the two, and a fixture for each shape in
  `tests/lib/converged-floor.test.sh`. A floor refusal must route to VERIFY, not to
  EXECUTE, when `tasksRemaining` is empty: add that condition to the ITERATE gap edge in
  `graph/cycle.graph.json` with a probe under `lib/graph/probes/`. Defect 2.
- **Clean candidate state.** Find why VERIFY's baseline comparison saw a dirty tree after
  the rewind (the driver's own state commit is the first suspect) and make the baseline
  probe stage or ignore `.loop-spec/` before it compares. Reproduce offline first with a
  fixture that has an uncommitted `feature.json`. Defect 2.
- **State commits off the feature branch.** Either commit state to a `loop-spec/state`
  ref or squash state commits before DELIVER. The PR diff must contain only task commits.
  Pin with a test that counts commits on a delivered branch. Defect 3.
- **No writes to the project's `.gitignore`.** `lib/runtime-ignore.sh` owns
  `.git/info/exclude` already. Remove the `.gitignore` path and pin it. Defect 4.
- **Eval fixture.** In `evals/tasks/wc-json/check.sh`, grep only `*.py` under `tests/`,
  and run the grep before the tests. Defect 5. Replace the judge's 0 to 3 score with a
  diff-size-relative over-build number the driver already computes, and stop reporting
  `meets_request` as a grade. Defect 6.

Done when: `bash tests/run-all.sh` is green and a haiku run of `slugify-bug` reaches
DELIVER.

### WP1: the oneshot route

The single largest lever. Port the routing rule, not the prose.

- Add a new probe, `oneshot.sh`, under `lib/graph/probes/`. It answers `route=oneshot` or `route=full`
  from three deterministic inputs written by a short investigation step: number of files
  the plan expects to touch (at most 3), no security signal from
  `lib/security-signal.sh`, and no open question in the spec's unresolved list. The model
  may escalate a oneshot to full. It may never demote a full to oneshot. This is the
  determinism-audit rule (`docs/determinism-audit.md`, item 3) applied to the new branch.
- Add a `oneshot` agent node to `graph/cycle.graph.json` whose body is a new
  `skills/oneshot/SKILL.md`: write one spec of at most 60 lines with Intent and
  Implementation Notes only, implement, run one review pass with the existing
  code-review gate, verify with the existing acceptance gate, then DELIVER. Route edges:
  `human.after-spec` to `oneshot` when the probe says oneshot; `oneshot` to `deliver`.
  Extend `PHASE_NODE_IDS` in `lib/graph/engine.py` line 381 and the phase enums in
  `lib/phase-exit.sh`, `lib/cycle-driver.sh`, and `graph/schema.json`. WP2 removes this
  four-way edit for the next phase.
- In autonomous mode, SPEC writes no interview transcript. The ambiguity block stays.
- Update `tests/graph-conformance.test.sh` for the new node.

Done when: on `slugify-bug`, haiku, one round: delivered, at most 0.25 USD, at most 50
artifact lines, at most 3 minutes. On `wc-json`: delivered, at most 0.60 USD, at most
100 artifact lines, at most 5 minutes. These are BMad's measured numbers plus DELIVER.
Record the run in a findings file.

### WP2: phase vocabulary as data

- One source: the `nodes` array of `graph/cycle.graph.json`. Generate or read the phase
  list in `lib/graph/engine.py`, `lib/phase-exit.sh`, `lib/cycle-driver.sh`, and
  `graph/schema.json` from it. Delete the four literal lists.
- Move the `case "$phase"` block in `lib/phase-exit.sh` (lines 175 to 297) into per-node
  `gates` arrays on the graph. Each gate is a body path and args, the same shape as a
  `gate` node. `phase-exit` becomes a loop over that array.
- Pin: a test adds a phase to a copy of the graph and asserts nothing else needs editing.

Done when: adding a phase is one edit in `graph/cycle.graph.json` plus its SKILL.md.

### WP3: one typed state reader

- Add a new module, `feature_read.py`, next to `lib/feature_write.py`. It exposes the `stateKey`
  enum from `graph/schema.json` and nothing else. Replace every `jq ... feature.json`
  read in `lib/` with a call through it. There are 248 references in 61 scripts. Do it
  script by script, running that script's test each time.
- Pin: `tests/` grep that fails on any `feature.json` read outside the two Python files.

Done when: the grep test is green and `bash tests/run-all.sh` is green.

### WP4: the loop leaves the lead

- `lib/graph/engine.py` becomes the driver. Give it the `next` protocol
  `cycle-driver.sh` prints today (`NEXT`, `PAUSED`, `HANDOFF`, `REWIND`, `REDO`, `DONE`,
  `ABORT`), the phase-exit loop from WP2, the state commit, and the checkpoint. Delete
  `lib/cycle-driver.sh` when every `tests/lib/cycle-driver*.test.sh` case passes against
  the Python driver.
- Phase-handoff is the default. One phase per model session in-harness. The lead never
  carries context across phases. `skills/cycle/SKILL.md` becomes: call the driver, act on
  one answer line, stop.
- Keep `hooks/team/phase-handoff-guard.sh` and `hooks/restrict-agent-paths.sh` as
  enforcement. Drop hooks that only existed to police the lead's loop.

Done when: the eval driver runs a full cycle with `--phase-fresh` removed, because fresh
is the only mode, and the `fastapi-items` task delivers at less than half the 24.39 USD
recorded in the 9 September findings file on the PR 94 branch.

As landed (6.4.0 and the follow-up): the driver is `lib/graph/driver.py`, and
`lib/cycle-driver.sh` survives as a thirteen-line launcher that owns only the path.
About forty callers keep one entry point, and the plan's "delete" is answered by the
shim, not the file. `skills/cycle/SKILL.md` keeps its start, initialize, and resume
steps because each needs a harness tool the driver cannot call: `AskUserQuestion` for
the decisions `begin` hands back, `EnterWorktree` and `ExitWorktree` for the checkout.
Everything mechanical in those steps is one `begin` call. The one exception to one
phase per invocation is the graph's `sameSession` edge (SPEC to ONESHOT).

### WP5: headless session layer

- Vendor `src/bmad_loop/adapters/` and `src/bmad_loop/plugins/` from bmad-loop
  `c47333d` into `extensions/sessions/`, with their tests and the MIT notice. Do not
  vendor the engine, verify, runs, or sprint-status modules.
- Add a `session` dispatch rung to `lib/execute-rung.sh` and to the driver: when the
  harness probe answers headless and a CLI profile is present, an agent node runs as a
  disposable session with the SKILL.md as its prompt, observed through the vendored hook
  relay. When the probe answers in-harness, the node runs through phase-handoff as
  before. `lib/harness.sh` gains one question, `session-layer`, that fails safe to
  in-harness.
- Keep the runtime rule from `CLAUDE.md`: the vendored code is Python 3.11 and lives
  under `extensions/`, the same exception the ADK bridge already has. The base runtime
  floor does not move.

Done when: `LOOP_SPEC_NON_INTERACTIVE=1` runs of both fixtures deliver through the
session rung on Claude Code and Codex, and `tests/` pins the rung selection.

As landed, WP5 is partial. The adapters were not vendored: their import closure
reaches bmad-loop's run and verify modules, which the plan excludes, so
`extensions/sessions/session_run.py` is 216 lines written from scratch, with the
profile shape and the fault patterns taken under the MIT notice in
`extensions/sessions/NOTICE`. There is no hook relay; the process exit is the signal.
The driver launches the session rung (`cycle-driver.sh task run`), and
`tests/lib/execute-rung.test.sh` pins the selection. The live done condition, both
fixtures delivered through the rung on Claude Code and Codex, is unverified: the
9 September fastapi run on dda2cca inherited the lead's launch stamp and never took the
rung (fixed in 6.4.0), and no run since has been spent on it.

### WP6: phase content from BMad

- Spec template: replace the autonomous SPEC body with BMad's shape, Intent inside a
  frozen block plus Implementation Notes, for the oneshot route only. The full route
  keeps the current SPEC.
- Review triage: the code-review gate records one verdict per finding with evidence, and
  the `false` verdict requires a disproof sentence. Add a probe that rejects a finding
  with no `file:line`. This catches the false off-by-one the BMad run wrote to its
  backlog.
- Do not port personas, PRD, or product-brief skills. The readers here are agents, and
  humans audit the decision log.

Done when: `lib/artifact-lint.sh` accepts both spec shapes and a fixture of each is in
`tests/`.

## Non-goals

- No fork of BMad Method or bmad-loop, and no BMad names in this tree's code, skills,
  or product surface. The trademark terms allow "compatible with" and forbid derived
  names. An attribution file (`extensions/sessions/NOTICE`) and the evidence documents
  under `docs/loop-spec/` name BMad, because a license notice and a measurement must
  name their source.
- No tracking of BMad releases. The vendored session layer is pinned at `c47333d` and
  updated by hand when a profile for a new CLI is worth it.
- No new stored map, index, or codebase document. The rule in `CLAUDE.md` stands.
- No live eval in a session where the user did not ask for one.

## Reproduce the numbers

From a checkout at PR 94 head, with `claude` on PATH and signed in:

```bash
LOOP_SPEC_EVAL_LIVE=1 bash evals/run.sh --model haiku --tasks slugify-bug,wc-json \
    --parallel 2 --run-id pr94-haiku --confirm-spend
```

For the BMad and control rows, the driver used in the head-to-head reused
`evals/eval_run.py`'s workspace, diff, and check functions with a different prompt and no
plugin directory. It installed `skills/bmad` and `skills/bmad-build` from the BMad
checkout into the fixture's `.claude/skills/`, ran BMad's `setup.py` once, committed
that as the base, and prompted `Use the bmad-build skill for this work: <task prompt>`.
The control prompt was the task prompt plus "run the tests, then commit". If you rebuild
that driver, keep it out of the tree, or add it under `evals/` behind the same spend
guard as `evals/run.sh`.

## Where the port audits live

The five audits of this port ("port audit 1" through "port audit 5" in code comments,
the changelog, and the tests: items F1 to F12, N1 to N7, the fourth audit's five items,
and R1 to R7) are records on the branch `claude/loop-spec-bmad-eval-w7odpb`, under that branch's
`docs/loop-spec/` as the five `orchestrator-port-followup` files, with each audit's
landing record appended there. They are not in this tree: they change nothing the
plugin does, and the branch that judges outcomes carries only the plugin.
