# Changelog

All notable changes documented here. Format follows Keep a Changelog.

## [Unreleased]

## [6.5.0] - 2026-09-09

The orchestrator port's follow-up (`docs/loop-spec/orchestrator-port-followup.md`,
F1 to F11) and the rules behind it (`docs/loop-spec/orchestrator-port-principles.md`).
The landing record at the end of the follow-up says what each item became.

### Before you update

- **The micro directive is shorter and injected only when a person is proven present.**
  The two sentences about standing down inside a route or a cycle are gone; the guard
  and the probe enforce what they said.
  `lib/harness.sh attended` answers true for the Claude Code `cli` stamp, for opencode,
  ADK, and Codex sessions with no one-shot assertion, and for
  `LOOP_SPEC_EXECUTION_PROFILE=interactive`; a headless or unstamped launch (a `claude
  -p` run, Claude Code on the web or in the desktop app) gets nothing. `ENABLED=1` in
  `.loop-spec/micro.conf` restores it on an unstamped launch, never on a headless one.
  The grill, simplicity, human-code, and discipline directives stand down only when the
  launch is proven headless.
- **A `/loop-spec:cycle` session that never calls the driver cannot stop, and neither
  can one that walked out of an open phase.** `hooks/team/cycle-stamp-guard.sh` (Stop)
  denies while the prompt stamp `cycle-driver.sh start` consumes is still present and
  no newer `.loop-spec/last-result.json` exists, and while a feature's newest
  `phase_start` has no `phase_end` and no newer result (until the phase is older than
  `LOOP_SPEC_PHASE_TIMEOUT_MINS`). The deny names the driver call through the `DRV`
  the cycle skill binds, never a path to retype. It has no switch of its own;
  `LOOP_SPEC_INVOCATION_STAMP=0` stops the stamp and with it the first deny.
- **The driver observes what the lead used to assert** (`docs/loop-spec/orchestrator-port-followup-4.md`).
  Read-only is the task's word: the invocation token `protected:a,b` lands in
  `feature.json.protected`, `lib/footprint.sh list` honors a read-only mark only for a
  protected file (a mark on any other file is a plain cite, with a notice) and adds a
  cited source file's existing test module by construction, so a changed file's test
  is in the footprint unless the task protects it; the eval passes each task's
  protected list. The oneshot verification skeleton's Status cells are empty, and
  `cycle-driver.sh verification run` executes each criterion's command (the backticked
  span of its SPEC line) and `commands.test`, writing PASS or FAIL from the exit, the
  evidence, and the output; `next --returned-from oneshot` runs it before the exit
  gate, `artifact-lint` flags an empty Status cell and an empty fenced block, and
  `verification fill` takes no evidence, output, or review text any more.
  `verification review --report` writes the Code review section from the reviewer's
  report (`none` when it holds no finding; the boundary review does this itself) and
  `verification verdict` records the lead's answer per finding. The three remaining
  writers of a driver-owned file are closed: `spec write --file` refuses over the
  oneshot skeleton, `hooks/team/result-forgery-guard.sh` denies a shell write into a
  oneshot feature's SPEC.md or VERIFICATION.md, and the path hook's deny fails closed
  on an unreadable spec. `spec fill --json -` fills the whole spec in one call; a test
  module of a file that changed in the diff cannot be dropped; the eval records
  `first_turn_input_tokens` from the session transcript and reads `bar.rounds`.
- **A criterion is two fields, escalation is a gate's, and the four other fifth-audit
  items** (`docs/loop-spec/orchestrator-port-followup-5.md`). `spec fill --command
  <shell> --expect <text>` writes the Good Enough line and the command into the
  frontmatter `criteria:` map that `verification run` executes; a sentence is refused,
  `--row GE-NNN` replaces (a grounding bullet by index), a repeat is never appended,
  and `lib/oneshot-spec-lint.sh` flags a bare Good Enough line at SPEC's exit. `spec
  escalate` is gone from the lead's reach: the third identical REDO on ONESHOT writes
  `route: full` with the flag classes as the reason, sets the attempt's
  VERIFICATION.md aside, emits an `escalate` event, and hands the run to DISCUSS. A
  fresh session that enters the phase a handoff named answers from the record instead
  of stepping the graph again, so a phase is entered once. The reviewer session leaves
  `dispatch/oneshot.reviewer.log` and the REDO quotes stderr's last line. The shell
  guard denies on an unreadable spec like the path hook. The lite spec skill names the
  one drop call beside the footprint.
- **Three defects the first six-run reading exposed, fixed.** A criterion without a
  backticked command made the boundary's `verification run` die before it wrote any
  row, so every Status cell stayed empty and the run escalated; `spec fill
  --criterion` now refuses a bare criterion and never appends the same one twice,
  and `verification run` writes row by row, turns a bare criterion into a FAIL row
  that says so, and adds the row and block for a criterion the spec gained after the
  skeleton. The Claude session profile listed `--allowedTools` last, so with the
  reviewer model `inherit` (no `--model`) the CLI read the prompt as one more tool
  name and every driver-launched reviewer died on "no prompt"; the guarded list now
  ends with `--permission-mode acceptEdits`. A failed reviewer session is handed to
  the lead once, as the in-harness dispatch, instead of relaunched on every return.
  `cycle-driver.sh decline` refuses once a feature has begun in the checkout.
- **Live run 4** (`slugify-bug`, haiku, d17da82, this branch's run; the auditor's own run
  on the same head read 0.42 USD, 3.5 minutes, 68 lines, 47 turns): delivered in one
  round at 0.41 USD, 3.8 minutes, 74 artifact lines, 39 turns, zero REDO rounds; run 3 on the same fixture
  before this work was 0.80 USD, 79 turns, 124 lines. The bar (0.25 USD, 50 lines, 3
  minutes) is still missed; `docs/loop-spec/orchestrator-port-followup-3.md` records
  where the rest sits.
- **The small pins the third audit asked for.** A repeated handoff answer (`next` or
  `begin` in the session that handed off) adds no phase event pair, pinned in the
  driver test; each eval task's pass bar is checked against the plan's figures
  (`tests/eval-record-coverage.test.sh`); the four port findings documents under
  `evals/` leave the tree per the policy PR 93 set, and the changelog names the runs
  instead. The state-ref commit count on a driver-delivered branch was already pinned
  (`tests/lib/cycle-driver.test.sh`, "carries no state commit", in place and in a
  worktree). PR 93's four variables and three guards stay as merged, each recorded
  with its observed failure in `docs/loop-spec/orchestrator-port-followup-3.md`.
- **The short route's reading list is bounded as a path.** `skills/spec-lite/SKILL.md`
  is SPEC's entry on every cycle (the graph's `spec` node names it with the new node
  key `skill`, printed as `EXT skill=spec-lite` under `NEXT`): the scout, the oneshot
  candidate from the scout's record, and the short route's spec fills; it hands to
  `loop-spec:spec` on the full route, whose body lost the candidate section. The cycle
  skill is the launcher: `begin` answers `decisions` with the init and resume commands
  it wants next (`.next`), `finish` prints the completion `report`, and
  `cycle-driver.sh decline --reason` writes the protocol-mismatch result; the
  headless-run and team-dispatch sections, whose contracts belong to the docs and the
  phase skills, are gone. `tests/lib/context-load.test.sh` holds the cycle, lite spec,
  and oneshot bodies with their cites at or under 600 lines.
- **The lead never writes a shape on the short route.** `cycle-driver.sh spec fill`
  (`--intent`, `--file/--note`, `--criterion`, `--grounding`), `spec escalate
  --reason`, and `verification fill` (`--row` with `--implementation/--proof`,
  `--integration/--integration-proof`, `--evidence`, `--output`; `--review`; `--tests`)
  fill the driver-written skeletons one value per call and answer with the exit lints'
  flags over the file as it stands. `hooks/restrict-agent-paths.sh` denies a Write or
  Edit of SPEC.md or VERIFICATION.md while `lib/graph/probes/oneshot.sh` answers
  `route=oneshot` for the feature, naming the fill commands. The oneshot node's
  VERIFICATION.md skeleton is `VERIFICATION-oneshot.md.template`, the sections the
  gates read and nothing more (44 lines for two criteria against 99 filled from the
  full template on live run 3). Every REDO answer is a driver-observed `redo` event
  with the flag classes; `evals/eval_run.py` records `redo` and `format_redo` and the
  summary prints them (`tests/eval-record-coverage.test.sh`).
- **The footprint has no prose exit.** `lib/oneshot-exit-gate.sh` flags every
  footprint file the diff since `baseSha` never touched, whatever Implementation notes
  say; `cycle-driver.sh spec footprint drop --file --reason` is the one way out, a
  ruling in `decisions.jsonl` and a line in the spec, and it refuses the test module of
  a file that stays in the footprint. The gate's `unchanged`/`read-only` bullet reading
  and its silent drop of an untouched non-test file are gone.
- **A cycle never initializes the plugin's own repository.** `cycle-driver.sh init`
  exits 3 when the checkout carries this plugin's `.claude-plugin/plugin.json` and is
  not the project the harness opened, or when the driver runs from a copy inside that
  checkout (the eval's layout). `tests/run-all.sh` refuses to start while an active
  cycle lives in another worktree of the repository, naming it, so a leaked feature
  cannot turn a guard suite green or red by accident; the ad-hoc verify guard's suite
  runs from its fixture directory for the same reason.
- **The short route is one session end to end.** The graph's `human.after-spec` to
  `oneshot` edge and its `oneshot` to `deliver` edge carry `"sameSession": true`;
  `cycle-driver.sh next` answers `NEXT` across them instead of `HANDOFF`, and
  `hooks/team/phase-handoff-guard.sh` allows the calls. A supervisor counting rounds
  sees one round for a oneshot fix; the escalated route (`oneshot` to `discuss`) still
  hands off.
- **The footprint is the scout's ledger.** `lib/footprint.sh cite <path>:<line>`
  (with `--read-only`) writes `<featureDir>/footprint.jsonl`; `lib/graph/probes/oneshot.sh
  --candidate` and `cycle-driver.sh spec skeleton` read it and take no file argument.
  The oneshot spec template keeps only `gate_passed` and `unresolved_dimensions` in
  its frontmatter.
- **`lib/feature-read.sh --all` fails on a key the schema does not declare**, naming
  it. `--drop-strays` projects without them; the driver passes it in its one
  stray-dropping rewrite. A dashboard that called `--all` on a feature with legacy keys
  now sees exit 1 until the driver's next phase activation drops them.
- **The oneshot exit gate escalates on its own.** A changed file outside the footprint
  writes `route: full` into SPEC.md with the file named and routes the run to DISCUSS;
  an untouched non-test footprint file is dropped from the footprint with a note; a
  test module named and untouched stays a flag. `route: full` still runs the scans
  and the verification lints.
- **The handoff marker is `LOOP_SPEC_HANDOFF`.** `LOOP_SPEC_PHASE_HANDOFF` was the
  removed variable's name; the marker the cycle skill prints and the nested-session
  guard names is renamed. A supervisor grepping the old marker updates its pattern.
- **`lib/review-triage-lint.sh` reads every bullet under `## Code review`**, under
  any subheading, and a location needs a path separator or a known source extension
  (`Makefile`, `Dockerfile`, and the like count). A finding parked under
  `### Resolution` is linted now.

### Added

- `lib/context-load.sh sum|cites`: the lines a phase skill makes the lead read, with
  `path.md#Heading` counting one section; `tests/lib/context-load.test.sh` holds the
  oneshot path under 600 lines and the spec skill body under 260.
- `skills/spec/SKILL.md` "1a. The oneshot candidate": the lite path, one driver call,
  no score, no transcript, intent gaps asked once.
- `cycle-driver.sh spec skeleton` (the candidate's route and SPEC.md skeleton), `spec
  write --file` (the one target a draft lands at), `task run --role
  implementer|reviewer` (the session rung's launch, in the driver), and `oneshot
  review` (ONESHOT's one review pass as a driver-launched session where the session
  layer answers, with the dispatch event driver-observed).
- The eval tasks `slugify-bug` and `wc-json` carry `bar` figures (cost, artifact lines,
  minutes); the record carries `bar.met` and the summary says "at the bar" or "over the
  bar" per task, so the pass bar is read, not argued.
- A phase node's ingress may list `skeletons` ({path, template}); `phase-begin` writes
  each absent one. The oneshot node lists VERIFICATION.md with one grounding row and
  one acceptance row per Good Enough criterion.
- `lib/graph/phases.sh same-session <from> <to>` and the edge key `sameSession` in
  `graph/schema.json`.
- `lib/harness.sh attended` and `attended-reason`.
- `evals/eval_run.py` records `cycle_begun`; the summary reports a run with no
  feature.json as "no cycle".
- `tests/graph-phase-subsets.test.sh` reads every literal phase subset in the driver,
  `lib/phase-mode.sh`, and the placeholder guard back against the graph.

### Changed

- `hooks/restrict-agent-paths.sh` applies the feature-checkout deny to every caller,
  the main thread included: a feature artifact lands in the checkout that holds its
  feature.json.
- `hooks/team/nested-session-guard.sh` allow-lists the bundled launchers by path
  token, never by substring, and scans a script that merely mentions one.
- `skills/oneshot/SKILL.md` cites the compact directives and the telemetry section by
  heading, not the whole contracts; the driver's skeleton is what it fills.
- `skills/shared/execute-rungs.md` describes the session rung as the driver's launch.
- `lib/pause-snapshot.sh`, `lib/ralph-remediation.sh`, `hooks/team/task-completed.sh`,
  `lib/cycle-reconcile.sh`, `skills/pause/SKILL.md`, and
  `skills/shared/execute-loop-fleet.md` read feature.json through the typed reader;
  `tests/feature-read-coverage.test.sh` is a two-pass scan with a reasoned allow-list.
- `docs/loop-spec/orchestrator-port-plan.md` records the WP4 shim and the cycle
  skill's launcher steps, the WP5 vendoring decision and its partial state, and the
  attribution exception to the BMad non-goal.

### Merged from 6.3.0 (PR 93)

The 6.3.0 fixes are combined here. Where the two branches collided the port's version
stands, and what 6.3.0 had that the port lacked is adopted: the BLOCKED acceptance
status and the veto of a PASS whose evidence says the check never ran
(`lib/converged-floor.sh`); the ITERATE `escalate` route for a gap only an operator can
close (`lib/iterate-judged.sh`, ended by the driver as `DONE status=escalated`); a
headless or gitfile checkout works in place on the feature branch (`lib/graph/driver.py`);
the dispatch contract's "dispatch, then stop" holds under `claude -p`; the critic reads
only the EVID rows the artifact cites; PLAN adds the `blockedBy` edges its prose states
(`lib/plan-conflicts.sh edges`); accepted `[minor]` items are applied before a critique
gate closes at its ceiling. Not adopted: `plan-render.sh` as the source of PLAN.md's task
sections (the port derives tasks.json from PLAN.md), and the fix-list `@file` form (the
port's `critique fail` takes a path or stdin). 6.3.0's `dispatch-prompt-guard.sh` and
`artifact-lint-feedback.sh` hooks and its `plan-render.sh`, `task-batch.sh`, and
environment probe come along unchanged.

### Fixed

- The oneshot VERIFICATION.md skeleton escapes a `|` inside a Good Enough criterion (a
  shell pipeline is a common criterion); the bare pipe split the table row and
  `lib/converged-floor.sh` read the status from the wrong cell, one REDO and ten edits
  on a live run.

- The oneshot exit gate passed on a frontmatter the probe could not read, skipped the
  footprint check in workspace mode, and never checked the diff against the footprint
  in the other direction.
- `llms.txt` and `docs/loop-spec/configuration.md` told the reader to set a variable
  that no longer exists.

## [6.4.0] - 2026-09-09

### Before you update

For the operator who runs the plugin and the engineer who embeds it
(`docs/loop-spec/supervisor-interface.md`). Each item names what changed, who it
touches, and what to do.

- **The `autonomous` token counts only at the edges of the arguments.** A prompt builder
  that puts the word inside the description (`/loop-spec:cycle fix the autonomous chain`)
  no longer arms autonomous mode. Put it first (`/loop-spec:cycle autonomous <task>`),
  last, or set `LOOP_SPEC_AUTONOMOUS=1`. `/loop-spec:auto <task>` is unchanged.
- **The challenger runs on `sonnet` under Claude Code.** A `CLAUDE.md` alias allow-list
  built from `bash lib/feature-init.sh all-models` now needs `sonnet`; re-run the command
  and copy the list. `LOOP_SPEC_MODEL_CHALLENGER=inherit` restores the old default. Under
  implicit agent teams an alias selector makes the challenger a nameless one-shot Agent
  instead of a named teammate (`skills/shared/dispatch.md`); nothing to do unless a
  hook keys on the teammate name `challenger-1`.
- **The `plan-feasibility` gate is gone.** `feature.json.currentGate.gate` and
  `gateHistory[].gate` carry `plan-critique` for the whole PLAN review; the paused
  reason `plan-feasibility-cap` is gone with it (a mechanical FLAG that survives the
  review round now reaches the driver's bounded `REDO`, then escalation). A sink or a
  dashboard that matches either string needs the new names.
- **One delta round per critique gate.** `graph/critique.graph.json` declares a ceiling
  of 1. `LOOP_SPEC_CRITIQUE_ROUNDS=2` restores the old bound; `0` is still unbounded.
- **`tasks.json` is derived from PLAN.md.** A custom planner agent (an OpenCode or Codex
  agent generated from `agents/planner.md`, or an ADK role) must write every field in
  the task block: `**Files:**`, `**Verify:**`, `**Acceptance criteria:**`, and
  `**BlockedBy:**` (the Task DAG table is the fallback), plus `**Repo:**` in workspace
  mode. A `tasks[]` array in the completion message is no longer read. `lib/phase-exit.sh
  plan` refuses a sidecar whose ids differ from PLAN.md; `bash lib/plan-tasks.sh extract
  PLAN.md` is the recovery for a feature paused mid-PLAN on 6.2.0.
- **New gate-log files.** `gate-logs/<gate>-state.json`, `gate-logs/<gate>-delta.diff`,
  and a `## delta-findings-lint` section in every delta round log. A mirror store that
  copies `gate-logs/` picks them up; nothing else reads them.
- **Every one-shot `Agent` call carries `run_in_background: false`, and headless
  launchers need `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1`.** Claude Code's fork mode
  backgrounds every Agent regardless of the key (a headless run saw the stub on all eight
  calls), and the variable is the documented switch that forces the foreground. The eval
  driver and the cloud profile docs set it; an SDK embedding sets it in
  `ClaudeAgentOptions.env`. An SDK `can_use_tool` hook that inspects `Agent` tool input
  sees the new key. The peer harnesses drop it.
- **Longer challenger replies.** The "top 5-7, under 500 words" caps are gone; a sink
  that stores `gate_round` payloads or gate-logs sees the full findings pass.
- **One phase per invocation is the only mode.** `/loop-spec:cycle` runs one phase
  and returns with a paused `phase-handoff` result; the next invocation enters the next
  phase in a fresh context. A caller that ran a whole cycle in one `claude -p` now loops
  until `.loop-spec/last-result.json` is not `paused`/`phase-handoff`
  (`docs/loop-spec/cloud-run-autonomous.md` is the bounded controller; the eval driver
  does the same). `LOOP_SPEC_PHASE_HANDOFF`, `LOOP_SPEC_ITERATE_FRESH`, and the
  `phaseHandoff` state key are gone; `phase:fresh` is accepted and changes nothing;
  `phase:continuous` is reported as a legacy token and ignored. The driver answers
  `HANDOFF next=<p> model=<m>` at every phase boundary and `REWIND next=<p>` when the
  graph lists the next phase before the one that returned; both mean relaunch.
  `hooks/team/phase-handoff-guard.sh` enforces the one-phase rule whenever a feature is
  active, with no switch. `hooks/team/stop-deflection-guard.sh` is removed with its
  three variables: it denied a stop that said "fresh session", which is now the
  designed ending of every phase.
- **The cycle driver is Python.** `lib/cycle-driver.sh` is a launcher for
  `lib/graph/driver.py`, which runs the graph engine (`lib/graph/engine.py`) in
  process; every subcommand, answer line, and exit code is unchanged. A test or a
  supervisor that grepped the Bash driver for a contract string reads the module now.

- **Feature state never lands on the feature branch.** `feature.json` and `PROGRESS.md`
  are snapshotted onto `refs/loop-spec/state/<slug>` at every phase transition
  (`lib/state-ref.sh commit|restore|show`); the checkpoint push carries that ref; a
  recreated worktree restores from it. The driver no longer commits `chore: <slug> state
  @ <phase>` and never writes the project's `.gitignore`. `LOOP_SPEC_SQUASH_STATE_COMMITS`
  is gone (`lib/state-commit-policy.sh` with it). A supervisor that read state from the
  branch reads `git show refs/loop-spec/state/<slug>:feature.json` instead, and a
  checkout whose `.gitignore` still carries the two `!/.loop-spec/features/*/...`
  negations can delete them: every dirt check now goes through `git-ops.sh dirt`, which
  skips the state paths, and `runtime-ignore.sh ensure` removes the same negations
  from `info/exclude`.
- **One feature per checkout is a guard, not a side effect.** `cycle-driver.sh init`
  refuses a second feature while another is active in the same checkout; before, the
  clean guard tripped on state dirt that no longer exists.
- **A converged-floor veto with no FAIL row rewinds to VERIFY.** `iterate-gap.sh` answers
  `gap=verify`, the graph routes `iterate -> verify`, and the verifier completes the
  record; no implementer runs. A FAIL row still rewinds to EXECUTE.
- **A small change takes the oneshot route.** `lib/graph/probes/oneshot.sh` reads
  SPEC.md's new frontmatter `footprint:` (the files the change touches): at most three,
  `unresolved_dimensions` empty, and no security signal in SPEC.md or those files routes
  `human.after-spec` to the new ONESHOT phase (`skills/oneshot/SKILL.md`: implement on
  the main thread, one `loop-spec:code-reviewer` pass, verify, write VERIFICATION.md),
  then DELIVER. DISCUSS, PLAN, EXECUTE, VERIFY, and ITERATE do not run. Escalation is
  `route: full` in the frontmatter, written by SPEC or by ONESHOT, and routes to
  DISCUSS; `LOOP_SPEC_ROUTE=full` is the operator's override, and nothing demotes a
  full run. SPEC writes the oneshot spec shape
  (`skills/shared/artifact-templates/SPEC-oneshot.md.template`, at most 60 lines) when
  the same facts hold, and the autonomous paths write no interview transcript. That
  shape opens with the ask inside a frozen `## Intent` block (`<!-- intent: frozen -->`
  to `<!-- /intent -->`) that ONESHOT's exit proves unchanged since SPEC committed it;
  `lib/artifact-lint.sh spec` accepts both shapes (`tests/fixtures/real-SPEC.md`,
  `tests/fixtures/oneshot-SPEC.md`). A spec writer of your own that omits `footprint:`
  gets the full path, unchanged.
  `checkpoint.sh tag post-oneshot`, `LOOP_SPEC_PHASE_MODEL_ONESHOT`, and
  `phaseModels.oneshot` follow from the graph.
- **The phase vocabulary, and each phase's door and exit, are the graph's.**
  `lib/graph/phases.sh list|regex|validate|suffix` derives the phase ids from
  `graph/cycle.graph.json`; `feature-init.sh`, `phase-entry.sh`, `phase-exit.sh`,
  `checkpoint.sh`, the driver, the engine, and the team hooks read it, and
  `LOOP_SPEC_GRAPH` names another graph for all of them. Each phase agent node now
  carries `ingress` (the entry packet) and `egress` (the exit gates, pointers, commit,
  checkpoint, and the egress guard's allow-list); `phase-entry.sh` and `phase-exit.sh`
  are loops over those blocks (`skills/shared/graph-contract.md`, Phase ingress and
  egress). PLAN's and EXECUTE's multi-step checks are `lib/plan-exit-gate.sh` and
  `lib/execute-exit-gate.sh`, listed as gates. A graph of your own that adds a phase
  gives its node both blocks; `lib/graph/validate.sh --strict` flags a phase node
  without `ingress`. `checkpoint.sh tag` accepts `post-<phase>` for every phase of the
  graph; the four-name list is gone.
- **The eval driver has no judge model.** `evals/eval_run.py` reports over-build as app
  lines added over `reference_app_lines`; the `judge` record key and the summary's
  `judge meets/over` column are gone.
- **VERIFICATION.md's acceptance table has a grammar, and VERIFY's exit enforces it.**
  One row per Good Enough criterion keyed `GE-NNN` or its number in the `#` column; the
  status in the `Status` or `Result` column begins with `PASS`, `FAIL`, or `N/A`. A
  verifier of your own that writes another shape gets `FLAG [acceptance-table]` at
  `phase-exit.sh verify` (a REDO) instead of a converged-floor veto in ITERATE. The
  parser also accepts what the bundled verifier already wrote (`PASS (12 passed)`, a
  `Result` column after the verify command, `\|` inside a cell), so existing records
  keep reading.
- **A feature artifact must be written in the feature's checkout.** When the feature
  lives in a worktree, `hooks/restrict-agent-paths.sh` denies a spec-writer or planner
  Write under `docs/loop-spec/features/<slug>/` that lands in another checkout and
  names the path to use; `phase-exit.sh` flags `[misplaced]` with the move when it finds
  the file elsewhere. Briefs of your own pass absolute artifact paths.
- **`lib/verification-baseline.sh` no longer counts `docs/loop-spec/` as candidate
  dirt.** An uncommitted cycle artifact never changes what test, lint, or typecheck see;
  any other uncommitted file still fails the compare with exit 21.
- **`docs-probe.sh latest <runtime>` has a mirror and a refusal.** When endoflife.date
  is unreachable the probe reads the endoflife project's release data on
  raw.githubusercontent.com; when neither answers, a bare lookup (no `--ecosystem`)
  answers `unverified` rather than a same-named package from a registry. Pass
  `--ecosystem pypi` (or npm, crates, rubygems, go) for a package on such a network.

### Changed

- The critique gate's bookkeeping is one driver call per step: `cycle-driver.sh
  critique open|findings|fail|revised|delta|pass` (`lib/critique-step.sh`) writes the
  gate-logs, counts the round, emits the event, appends the history entry, asks the
  probe, snapshots and diffs the artifact, runs `lib/delta-findings-lint.sh`, and closes
  the gate on a verified delta or a spent ceiling. The lead keeps adjudication, the
  teammate messages, and the probes; the reply no longer passes through its context
  twice (`tests/lib/critique-step.test.sh`).
- The challenger runs on `sonnet` by default under Claude Code. The critic reads and
  writes nothing, and an Opus session paid Opus for every round. A phase route or
  `LOOP_SPEC_MODEL_CHALLENGER` still outranks it; the peer harnesses keep `inherit`.
- PLAN is one review round. The mechanical gates (`lib/phase-exit.sh plan`) and the
  challenger's findings pass run in the same response, their FLAG lines and findings go
  to the planner as ONE fix-list, and the one revision gets one delta re-verify that
  counts surviving FLAGs with the delta survivors. The separate `plan-feasibility` gate
  is gone, a `REDO` from the driver is one planner dispatch with the FLAG lines and never
  re-opens the critique, and the pruning pass runs once. A field run spent an hour and
  fifty dollars on Opus bouncing PLAN.md through the feasibility loop, the critique
  loop, and the feasibility loop again. Worst case is now five planner dispatches and
  two challenger calls; the common case is two and two.
- The critique gate is one exhaustive findings pass, one revision, one delta re-verify.
  `agents/challenger.md` and `skills/shared/team-prompts/critic.md` drop the "top 5-7"
  and 500-word caps: a challenger capped at seven held findings back and raised them in
  the delta round as `introduced:` lines on rewritten text, so every revision bought
  another revision. `graph/critique.graph.json` allows one delta round instead of two
  (`LOOP_SPEC_CRITIQUE_ROUNDS` still overrides). `lib/delta-findings-lint.sh` applies
  the delta scope the prose already stated: only `unaddressed:` lines and `[major]`
  `introduced:` lines that quote a line the diff added reach the lead; every other line
  is dropped with a reason in the gate-log (`tests/lib/delta-findings-lint.test.sh`).

### Added

- `hooks/team/nested-session-guard.sh` (PreToolUse, Bash): a phase lead that launches a
  nested harness session (`claude -p`, `codex exec`, `opencode run`, `adk run`, in the
  command or in a script it runs) is denied while a feature is active. A live run had
  written its own round script after the DISCUSS handoff and spent its budget twice.
  The bundled launchers (`session_run.py`, the loop-runner scripts, the eval driver)
  pass. `LOOP_SPEC_NESTED_SESSION_GUARD=0` stands it down.
- `extensions/sessions/`: the headless session layer. `lib/harness.sh session-layer`
  answers `session` when the invocation is headless, a profile exists for the harness
  CLI (`profiles/claude.toml`, `codex.toml`, `opencode.toml`), the CLI is on PATH, and
  `python3` is 3.11 or newer; `lib/execute-rung.sh` then selects the new `session` rung,
  and each implementer and reviewer runs as its own `claude -p` / `codex exec` /
  `opencode run` process through `session_run.py` (one profile, one prompt file, one
  JSON result line; provider faults the profile names are `env-fault`, not an attempt).
  Every unknown leg answers `in-harness`; `LOOP_SPEC_SESSION_LAYER=1|0` is the operator's
  word. The profile shape and the fault patterns are vendored under MIT (`NOTICE`); the
  source project's adapters are not, because their import closure reaches the modules
  the port plan excludes (`tests/sessions-extension.test.sh`, `tests/lib/harness.test.sh`,
  `tests/lib/execute-rung.test.sh`).
- `lib/review-triage-lint.sh`: every code-review finding in VERIFICATION.md is one bullet
  with a `file:line`, a `verdict: true` with its commit or backlog id, or a `verdict:
  false` with a disproof sentence. The `verify` and `oneshot` exits run it; a finding
  nobody could place, or a rejection nobody could explain, is a FLAG instead of a
  backlog line (the false off-by-one a head-to-head run wrote to its backlog).
- `lib/docs-probe.sh`: the plugin's own current-version and current-docs lookup.
  `latest <name>` answers `version=<v> source=<url>` from the registry or the release
  tracker over the network; `docs <name> --topic <question>` returns the sections of the
  current documentation that match (`llms.txt` where the docs live, else the README at
  the version's tag, else the registry's readme, else the docs page). Sources are a
  table in `lib/docs-probe.py`, one row per ecosystem (runtime via endoflife.date, PyPI,
  npm, crates.io, RubyGems, the Go proxy); the ecosystem comes from `--ecosystem`, else
  the manifest in the directory, else every row. Nothing answers: `unverified`, exit 1.
  The grounding protocol, the version directive, and SPEC's greenfield lookup call it
  before any web tool. `LOOP_SPEC_DOCS_CACHE_DIR`, `LOOP_SPEC_DOCS_CACHE_TTL_SECS`,
  `LOOP_SPEC_DOCS_FIXTURES` (`tests/lib/docs-probe.test.sh`).

### Fixed

- `lib/parse-invocation.sh` refuses a flag only while it leads the arguments; after the
  first description word a dash token is the description's own text (`python3 -m
  unittest`, `accepts --due YYYY-MM-DD`). Refusing those made a lead reword the task, the
  reworded slug matched no paused feature, and the next invocation started a second
  cycle in the wrong directory (`tests/lib/parse-invocation.test.sh`).
- `cycle-driver.sh start`: an autonomous invocation with exactly one paused feature
  resumes it even when the title differs; a different feature is a human decision
  (`tests/lib/cycle-driver.test.sh`).
- `evals/eval_run.py` and `extensions/sessions/session_run.py` drop the parent's
  session identity (`CLAUDE_CODE_SESSION_ID` and the remote-session plumbing next to it)
  from the child's environment: a nested `claude -p` that inherits it appends every
  round to the parent's transcript, and the handoff guard then reads an earlier round's
  phase as this invocation's. Both drop the parent's launch stamp
  (`CLAUDE_CODE_ENTRYPOINT`) too: the CLI writes it only when it is unset, so a child
  under an attended session inherited `remote_mobile`, `lib/harness.sh session-layer`
  answered `attended`, and the session rung never ran (`tests/sessions-extension.test.sh`).
- `cycle-driver.sh` holds the handoff line itself: `next` answers `HANDOFF` or `REWIND`
  and records the session (`feature.json.handoffSession`); from that session `next`
  repeats the answer, and `begin` or `phase-begin` of the next phase exits 4. A lead
  denied by the Skill-tool guard had read the next phase's SKILL.md by hand and run it
  in the session that had handed off. Each of the three puts the paused result pointer
  back: a lead that re-invoked `/loop-spec:cycle` in the session that had handed off
  ran `begin`, whose preflight clears the pointer, and the caller then read no result
  and ended the run after SPEC (`tests/lib/cycle-driver.test.sh`).
- `lib/cycle-result.sh write --status completed` publishes nothing, whatever the phase,
  when the feature has no delivery record and no PR (the proven no-change path still
  names its reason): the check used to exempt `deliver`, and a lead whose `finish` was
  refused called the writer itself from that phase, so the eval read a finished run
  whose fix never left the worktree (`tests/lib/cycle-result.test.sh`, case A0).
- `hooks/team/phase-handoff-guard.sh` no longer counts a denied attempt as a prior
  phase: a lead denied once for the next phase invoked it again and passed as a
  same-phase retry, so the oneshot route ran SPEC, ONESHOT, and DELIVER in one session.
- `lib/oneshot-spec-lint.sh` flags a footprint file whose existing test module the spec
  never names: in the footprint when it changes, in Implementation notes as unchanged
  when it does not. A run shipped a flag without its test and the reviewer deferred it.
- Ten findings from the second and third live runs (the 2026-09-09 haiku runs, rounds two and three; the findings document stays out of the tree):
  the version directive and SPEC's greenfield lookup say a stale installer is upgraded
  before anything is installed, never worked around with an older build or a
  pre-release; `critique open` answers the challenger's model alias for the Agent call;
  `critique findings` snapshots the artifact the challenger read, so the author may edit
  before or after `fail`; `critique revised` keeps the diff in its file and the delta
  brief names the path; `lib/phase-exit.sh plan` flags a verify command that installs or
  creates an environment; `lib/integrate-task.sh` carries the verify output's last lines
  in a `verify-failed` refusal; `agents/implementer.md` commits a lockfile written next to
  a manifest the task changed; the pruning pass is a nameless Agent, never a cycle role;
  the eval driver's round timeout is 150 minutes (`--round-timeout-mins`) and
  `--phase-fresh` runs each phase in a fresh lead context, the largest cost lever
  measured: one lead's 569 calls re-read 277k tokens each, 71 percent of a run's cost.
- `lib/graph/probes/discuss-critique.sh` no longer skips the spec critique on a gate the
  autonomous run scored itself: with no supervisor, the interview self-answers and
  `gate_passed` is true by construction, so the challenger was the spec's only
  independent read and two live runs skipped it. A human-answered or supervisor-answered
  gate still skips. Costs one challenger pass per autonomous run.
- Five defects from the first live run on 6.3.0 (the first live run on 6.3.0; the findings document stays out of the tree):
  `lib/git-ops.sh slugify` bounds a slug at 64 characters on a word boundary (a
  whole-description title made a 470-character branch git could not lock);
  `lib/parse-invocation.sh` refuses a flag as a title (`begin --help` initialized a
  feature named "help"); `lib/execute-step.sh integrate` names a dirty feature worktree
  `dirty-worktree` with the paths instead of `rebase-conflict`; `task_start` and
  `task_end` are emitted once, by the driver steps, and `execute-subagent.md` no longer
  asks the lead to emit them too; the version directive sends a runtime version to the
  language's release page or a network registry, never a local catalog.
- `tasks.json` is derived from PLAN.md, never copied from the planner's completion
  message. `lib/plan-tasks.sh extract` reads every `### task-NNN:` block (files,
  read_first, verify command, acceptance criteria, `**BlockedBy:**` with the Task DAG
  table as the fallback, interfaces, and the optional repo, batch group, model tier, and
  spec path lines); `skills/plan/SKILL.md` runs it after every planner report and
  revision. A run wrote PLAN.md whole and saved an empty `tasks[]` from the message, and
  EXECUTE, which reads only the sidecar, finished with nothing built.
  `lib/phase-exit.sh plan` now also flags a sidecar whose task ids differ from PLAN.md's
  and names the extract command in both that flag and the missing-sidecar flag
  (`tests/lib/plan-tasks.test.sh`, `tests/lib/phase-exit.test.sh`). The PLAN template's
  task block carries the `**BlockedBy:**` line.
- Every one-shot `Agent` dispatch carries `run_in_background: false`. Claude Code now
  launches an Agent in the background by default, and a background launch answers with
  a launch stub instead of the report; a lead that read the stub as an empty report
  dispatched the SPEC pruner twice. `skills/shared/dispatch.md` says a stub is never a
  reason to re-dispatch, the three peer harness contracts drop the key, and
  `tests/lib/harness-call-shapes.test.sh` case 8 now requires the key on every one-shot
  template instead of forbidding it.
- `docs/loop-spec/orchestrator-port-plan.md` is the ordered plan from the head-to-head
  against BMad; this release lands its WP0 (the defects that run showed) and WP1 (the
  oneshot route).
- `lib/converged-floor.sh` reads the acceptance table the verifier writes: the header
  names the status column, `PASS (12 passed)` is PASS, `\|` inside a cell is a literal
  pipe, and `--shape` checks the grammar alone. `phase-exit.sh verify` runs `--shape`, so
  an unreadable table is VERIFY's REDO. A run whose judge said converged saw the floor
  veto a table it could not parse, the lead rewrote VERIFICATION.md to fit the parser,
  the driver rewound to an EXECUTE with nothing to do, and VERIFY then died on the
  uncommitted file; `skills/iterate/SKILL.md` says never to edit VERIFICATION.md there.
- `hooks/restrict-agent-paths.sh` denies a spec-writer or planner write under
  `docs/loop-spec/features/<slug>/` in a checkout other than the one holding that
  feature's `feature.json`, naming the path to write; `phase-exit.sh` names a
  `[misplaced]` copy in another worktree and the `mv` that fixes it. A bug-fix cycle's
  spec-writer wrote SPEC.md into the main checkout while the gate read the feature
  worktree, and the driver escalated after four identical REDO rounds.
- `lib/verification-baseline.sh` excludes `docs/loop-spec/` from the clean-candidate
  check (`tests/lib/verification-baseline.test.sh`).
- `lib/docs-probe.py` distinguishes an unreachable host from a definite miss, mirrors
  the runtime row through the endoflife project's release data on GitHub (newest final
  version by number, never map order or a pre-release), and refuses to let a registry
  answer a bare runtime lookup whose sources never answered: on a network that blocks
  endoflife.date, `latest python` had answered `0.0.4` from an npm package of that name,
  and the fourth live run pinned Python 3.14.0rc2 from a stale `uv` and escalated
  (the fourth live run; the findings document stays out of the tree). `agents/implementer.md` binds the
  stale-installer rule where installs happen.
- `phase-exit.sh plan` also flags `uv sync`, `npm ci`, and `poetry install` in a verify
  command.
- `evals/tasks/wc-json/check.sh` and `evals/tasks/todo-due/check.sh` grep test sources
  only (`--include="*.py"`): after a test run, `tests/__pycache__/*.pyc` matched the
  word and passed a control that had added no test.
- `lib/parse-invocation.sh` honors the `autonomous` token only at the leading or trailing
  edge of the arguments. Inside the description it is prose: a feature described as "fix
  the autonomous chain bound" armed autonomous mode, stripped the word from the title,
  and ran the cycle without asking a question.

## [6.3.0] - 2026-09-07

### Fixed

- A live headless cycle on a real Terragrunt repository (the 2026-09-07 tf-meldn runs)
  lost about a third of its tool calls to twelve deterministic defects, each now fixed
  with a test: `git-ops.sh slugify` caps a prose-derived slug at 60 characters (a 400-char
  branch name failed `git worktree add`); `LOOP_SPEC_ANSWER_*` are honored under the inline
  `autonomous` token; a gitfile checkout (submodule or linked worktree) works in place
  because Claude Code's `EnterWorktree` refuses worktrees there; `.gitignore` exceptions
  land as one delimited block (`owned-gitignore.sh ensure`); `acceptance-lint.sh` no longer
  takes minutes on bash 3.2 (`${var//[[:space:]]/}` replaced by a regex test, four sibling
  sites swept); `evidence.sh add` refuses email addresses and credential paths; the
  preflight headless warning is dropped once the `autonomous` token is parsed; an
  autonomous `begin` auto-picks the single resumable feature and `.claude/agent-memory/` no
  longer counts as dirt. The plugin no longer refuses its own state as dirt: `execute-step
  integrate` commits tracked `.loop-spec` changes before publishing, the verification
  baseline ignores `.loop-spec`, `finalize-delivery-candidate` stages feature.json,
  PROGRESS.md, and the artifact directory in every state-commit mode, `task dispatch`
  refuses a task whose blockers are not done, `task package` names the task worktree
  for the reviewer, and `phase-exit` records a re-entered phase once.
- Subagent dispatches carry absolute template paths (a pattern-mapper searched the whole
  disk for a plugin-relative one) and the planner brief names `PLAN.md.template` and the
  three labels the artifact lint parses; DISCUSS names the exact `feature-write.sh`
  command and the forgery guard's deny text carries its usage.

- EXECUTE spends fewer seats and less context per seat, all of it deterministic. On the
  live run eleven tasks cost twenty-two subagents, each re-reading four artifacts (about
  100 KB) and re-probing the toolchain, and each reviewer re-ran the implementer's verify
  including live `terragrunt plan`. `lib/task-batch.sh` now merges a linear chain of
  local-verify tasks into one dispatch and tiers a doc/config-only task with a local
  verify as `mechanical` (`LOOP_SPEC_TASK_BATCH_AUTO`, `LOOP_SPEC_TASK_BATCH_CHAIN_FILES`);
  `execute-step` dispatches the collapsed task and marks every member done (the
  `batchGroup` collapse never reached the dispatch before). The brief carries PLAN.md's
  Global constraints verbatim, the EVIDENCE rows the task cites, and `dispatch/environment.txt`
  (tool versions `execute-prepare` probes once), and both prompts tell the subagent not to
  open the artifacts. The reviewer packet names the verify command so the reviewer can be
  told not to run it.

- A second observed run on the same repository (the 2026-09-07 tf-meldn runs,
  round 4) ended with the lead asking an absent operator a question after the ITERATE
  judge found the only gap was an expired gcloud token, and with two plan-dependent
  criteria marked PASS because PASS was the only cell that converged. ITERATE now routes
  `escalate` when the judge marks a gap `needs_operator` or the same `fix_first` survives
  a remediation round, and the cycle's `next` ends the run `DONE status=escalated` with
  the operator action as the reason; `VERIFICATION.md` has a `BLOCKED` status that the
  converged floor refuses to converge on, and a PASS row whose evidence says the check
  did not run is a floor violation. Also from that run: `grounding-lint` lints the
  backticked command of an ASSUMPTION, not the prose after it (two false flags);
  `acceptance-lint` accepts a whole-line or key = value grep against a declarative file
  (HCL, YAML, TOML, INI, JSON); `task-batch` and the environment probe split pipelines
  outside quotes (a quoted `a|b` pattern was probed as two programs) and treat
  `terragrunt hcl format` and `tofu fmt` as local; `execute-step` labels a failed
  integrate with its real reason instead of `rebase-conflict`; `.claude/agent-memory` is
  not dirt for the dirty checks, and `pattern-mapper` and `code-reviewer` no longer keep
  a per-repository memory (a one-shot reviewer's notes have no reader and were landing
  in the user's PR); the execute contract says to pass the packet's `.model`, to issue a
  wave's Agent calls in one message, and that a subagent's final message is its result
  (three `SendMessage` failures per reviewer); the cycle skill says `begin` already
  initialized the feature.

- PLAN was 42 of round 4's 110 minutes: five planner round trips (two lint rounds, three
  critique rounds), each a fresh planner context re-reading everything to change one
  field, plus a prose pruner over a plan that was mostly rendered task blocks.
  `plan-conflicts.sh edges` adds the `blockedBy` edges the task prose
  already states before the challenger reads the plan (a live round was spent on one such
  omission); the delta re-verify hands the challenger the diff path instead of inlining
  it into the lead's context; the prose-pruning pass runs only when
  `plan-render.sh prose-lines` counts 120 or more prose lines.

- Round 5 (the PLAN wave measured live) spent a lint round on seven SPEC decisions the
  planner paraphrased instead of copying; `plan-render.sh decisions` copies the missing
  statements verbatim before the gate.
  Also from round 5: headless runs work in place instead of entering a session worktree
  (Claude Code's worktree guard refused four plugin calls whose quoted text it could not
  prove git-free); the dispatch-prompt guard denies a brief with a line that is
  only a `$(...)` substitution (a pruner was dispatched twice for one); the critic reads
  only the EVIDENCE rows the artifact cites and never PATTERNS, transcripts, or gate logs;
  `plan-conflicts.sh edges` prints the updated array on stdout; the checkpoint PR of an
  escalated run carries the BLOCKED verification rows and the operator action; and a
  headless run never selects the team rung, because `claude -p` disables the harness
  task list that rung runs on (three teammates each failed on `TaskList`); `execute-step`
  commits new `.loop-spec` files (a pruner's BACKLOG.md) as state before integrating, and
  `integrate-task` no longer counts tool caches a verify leaves behind (`.terraform/`, a
  lock file, `node_modules/`, `__pycache__/`) as task dirt; the verify gate and the
  critique gate read their JSON arrays from `@path` files (a `\.github` path inside inline
  JSON killed a live gate call on quoting); the write-time hook runs the verification
  grounding lint on VERIFICATION.md.

### Added

- `lib/plan-render.sh`: renders PLAN.md's `## Task DAG` and `## Tasks` from tasks.json,
  preserving every other section. tasks.json is the single source for task fields; the
  planner writes the prose sections and returns `tasks[]` with `goal`, `read_first`,
  `interfaces`, `steps`, and `expected`. The shape the artifact lint parses is produced,
  not checked, and a critique fix to a task is one edit plus a re-render.
- `hooks/team/artifact-lint-feedback.sh` (PostToolUse on Write/Edit): runs the matching
  artifact lint on SPEC.md, PLAN.md, PATTERNS.md, and tasks.json the moment they are
  written and returns the flags to the author, lead or subagent. On the live run every
  lint ran only at phase exit, so three 20-millisecond checks cost three planner
  round trips; the exit gate stays as the backstop.
- `hooks/team/dispatch-prompt-guard.sh` (PreToolUse on Agent): denies a prompt that is an
  unexpanded `$(...)` substitution or under 40 characters (a live lead dispatched both
  wave-one implementers with `$(cat /tmp/prompt.txt)` as their whole brief).
  `execute-step.sh dispatch` now refuses a task whose `blockedBy` are not done.
- `skills/shared/dispatch.md` and the critique protocol state that "dispatch, then stop"
  holds under `claude -p`, verified live (a lead ran 24 background sleep loops waiting for
  a reply the harness delivers by resuming the turn); the critique protocol applies
  accepted `[minor]` items before closing at the round ceiling.

## [6.2.0] - 2026-09-06

### Changed

- The per-phase bookkeeping the phase skills asked the lead to run one script at a
  time is folded into `lib/cycle-driver.sh` (eval finding 7: a two-line fix cost 186
  lead tool calls, 156 of them Bash). `begin` is start plus init or resume when no human
  decision is pending; `phase-begin <phase>` is the entry packet, the mode line, and for
  EXECUTE and VERIFY the whole pre-dispatch or pre-team work (`lib/execute-prepare.sh`,
  `lib/verify-prepare.sh`); `task dispatch|package|verdict|integrate`
  (`lib/execute-step.sh`) is one call per EXECUTE task step; `verify gate` and
  `verify passes` (`lib/verify-gate.sh`, `lib/verify-passes.sh`) apply the verdicts and
  run the advisory passes; `iterate limit|record|harvest` (`lib/iterate-judged.sh`)
  wraps the judge; `deliver` is the whole DELIVER phase. `next --returned-from <phase>`
  runs `lib/phase-exit.sh` itself and answers `REDO phase=<p> flags=<n>` with the FLAG
  lines when the artifact is not ready; phase skills no longer run the exit. Every phase
  skill and the execute contracts now name these calls; the coverage pins moved to the
  scripts that carry the behavior.

### Added

- `evals/`: a paid, live outcome eval (five fixture tasks, deterministic acceptance
  scripts, a driver that runs each through `claude -p "/loop-spec:cycle autonomous …"`
  against a snapshot of the plugin and records cost, time, diff shape, workarounds,
  and plugin tampering). Not registered by `tests/run-all.sh`; refuses to run without
  `LOOP_SPEC_EVAL_LIVE=1` and `--confirm-spend`.
- `feature.json.driverNext`: the phase the driver last answered with `NEXT`.
  `cycle-result.sh write` refuses `--status failed|terminal|escalated` over it unless
  `--reason` says what stopped the phase.
- `hooks/team/invocation-stamp.sh` (UserPromptSubmit, Claude Code and Codex): stamps the
  raw `/loop-spec:<skill>` arguments so `cycle-driver.sh start` can restore a token the
  skill's prose rewrite dropped. `LOOP_SPEC_INVOCATION_STAMP`, `LOOP_SPEC_STAMP_MAX_AGE_MIN`.
- `hooks/restrict-agent-paths.sh` denies Write and Edit under the installed plugin root
  for every caller, by real path; a feature worktree under the project and a plugin root
  inside the project (loop-spec developing itself) are unaffected.
- DELIVER without `gh`: `lib/pr-delivery.sh final` pushes the exact SHA and stops with
  outcome `pushed-no-pr`; `lib/deliver.sh` reports `status: pushed-no-pr`, the cycle
  completes, and `cycle-result.sh` publishes outcome `pushed-no-pr`. checkpoint and
  observe modes still require `gh`.
- `LOOP_SPEC_MICRO_GUARD_MAX_DENIALS` (default 3) and
  `LOOP_SPEC_MICRO_GUARD_STATE_DIR`: the ad-hoc verify guard stands down after that
  many denials for one transcript.
- `hooks/team/result-forgery-guard.sh` (PreToolUse Bash, Claude Code and Codex) denies a
  shell redirect, `tee`, `cp`, `mv`, `install`, `sed -i`, or Python `open(..., "w")`
  aimed at a `.loop-spec/` contract file (`last-result.json`, `result.json`,
  `active-run.json`, `feature.json`, `delivery.json`); `hooks/restrict-agent-paths.sh`
  denies Write and Edit on the same files. `cycle-result.sh state` reports a pointer
  without `schema` and `loopSpecVersion` as `unaccounted`, so the stop guard keeps
  refusing, and the eval marks the record `forged_result`. Two eval runs whose result the
  writer refused wrote the pointer by hand. `LOOP_SPEC_FORGERY_GUARD=0` disables the hook.
- `cycle-driver.sh next --returned-from <phase>` answers the same flag set at most
  `LOOP_SPEC_REDO_MAX` (default 3) times, then escalates with the flags as the reason.

### Fixed

- `cycle-result.sh write --status completed` refuses a feature that never reached
  DELIVER unless `delivery.json` or a PR URL says otherwise, and `write-terminal` refuses
  `completed` for a full cycle armed at an earlier phase.
- `lib/verify-gate.sh` routes `redo` for a VERIFICATION.md whose format flags carry no
  verifier FAIL, instead of dispatching the verifiers again; `lib/iterate-judged.sh
  record` is idempotent on the judge hash, so a repeated call no longer counts a second
  iteration.
- `lib/phase-exit.sh` keeps a gate's indented detail lines, so a REDO names the
  uncovered decisions instead of a bare heading.
- `lib/decision-coverage.sh` matches a decision's statement, not its `Rationale:` and
  `Alternatives considered:` clauses, and its heading says that only a verbatim copy in
  PLAN.md counts. `lib/verification-grounding-lint.sh` prints the row grammar with a
  malformed-row or empty-section flag. A haiku planner paraphrased every decision three
  times, and a haiku verifier wrote `- none` three times, because neither flag said what
  to write; each escalated at the REDO bound.
- `cycle-result.sh write-terminal` refuses `--outcome interrupted` without `--reason`
  while `feature.json.driverNext` names a phase the driver answered NEXT for, and the
  refusal prints the `cycle-driver.sh next --returned-from` call that continues the
  cycle; `hooks/team/route-terminal-guard.sh` leads its denial with that continuation
  instead of a menu of terminal results. Three haiku leads ended the turn after EXECUTE
  with the work done and recorded `interrupted`.
- `lib/deliver.sh` names the dirty paths in a `dirty_worktree` refusal; a lead refused
  over untracked `__pycache__/` could not tell residue from a forgotten file. The eval
  fixtures now carry the `.gitignore` a real Python repository has.
- `evals/eval_run.py` marks a round the CLI ended with the account's usage-limit text as
  `cut_off`, says so in the summary instead of scoring it as a plugin failure, and
  refuses at preflight while the limit is active.
- `lib/runtime-ignore.sh` ignores `.loop-spec/profile.json`, the policy file the
  supervisor contract tells embedders to write. Untracked, it made `cycle-driver.sh
  init` refuse every fresh checkout as dirty; the refusal now names the dirty paths.
- `lib/cycle-driver.sh` evaluates `.loop-spec/profile.json` itself, so a preset that
  names `autonomous` arms the run even when the prompt rewrite drops the token.
- The phase state commit runs in the feature's own repository, not the caller's
  working directory, and a failed commit is reported and recorded instead of hidden.
  Run from the project root with the feature in a worktree, it used to stage a
  `.gitignore` in the root and leave `feature.json` untracked for DELIVER to refuse.
- Workspace mode is the recorded mode, never the presence of a root: `lib/workspace.sh
  detect` reports `{root, mode: "single", repos: []}` for an ordinary repository, and
  every consumer (phase-entry, phase-mode, phase-exit, deliver, delivery-reconcile,
  feature-scan-each, finalize-delivery-candidate, cycle-driver, cycle-result, the
  plan-critique probe) now treats only an object whose mode is not `single` as a
  workspace. A record with a single-mode object used to skip every artifact commit and
  leave `plan.critique.gate` with no route; `plan.critique.gate` also gained a
  `routeDefault` to the critique, and the probe says why when it cannot answer.

## [6.1.0] - 2026-09-04

### Added

- Evidence-backed approach selection across SPEC, DISCUSS, PLAN, EXECUTE, and
  review: distinguish suggested methods from binding constraints, compare plausible
  alternatives against the same requirements, and carry the reasoning in existing
  artifacts. Local improvements stay within delegated scope; changes to settled
  designs use the existing decision and replanning paths.
- A coverage test pins the shared contract to phase and agent entry points.

### Fixed

- Prompt normalization preserves suggested methods and their rationale so design
  phases can evaluate them instead of losing them during the outcome rewrite.

## [6.0.0] - 2026-09-04

### Changed

- Direct graph callers acknowledge successful agent returns with
  `--step --completed-node ID`. Restarting without an acknowledgement retries the
  unfinished node. The cycle driver supplies acknowledgements through its existing
  `next --returned-from PHASE` interface. Legacy checkpoints remain readable.
- `tests/run-all.sh` runs the complete offline suite by default, including cycle,
  delivery, harness, and loop-runner integration tests. `RUN_ALL_PROFILE=unit`
  retains the shorter gate. Selected suites run even when marked integration;
  unknown selections fail rather than reporting success with zero tests.
- Convergence requires a readable specification, grounding for every Good Enough
  criterion, and exactly one PASS acceptance result per criterion. The ITERATE
  phase exit enforces this floor for converged verdicts.

### Fixed

- Concurrent state updates now lock before reading and preserve each other's field
  changes. Publication fsyncs unique temporary files and atomically replaces the
  destination while retaining the previous state as a backup. Invalid non-object
  or multiple-document state is rejected.
- Resume carries the selected feature slug through shared checkouts and rejects
  ambiguous or missing selections instead of modifying the first directory found.
- Graph checkpoints distinguish started, completed, and failed work. Failed gates
  and functions remain retryable; checkpoint and phase-state write failures stop
  advancement.
- Graph retry counts survive process restarts, and matching routes obey their
  declared loop ceilings instead of bypassing the retry limit.
- Profile exports preserve literal quotes, shell syntax, and multiline values;
  consumers evaluate the quoted export stream without splitting it.
- The workflow smoke test installs into a temporary package so an inherited plugin
  environment cannot modify an installed copy or the checkout under test.

### Documentation

- Added the September 4, 2026 primary-source review of specification, loop, and
  graph reliability, with implementation evidence and 5.x migration guidance in
  `docs/loop-spec/reliability.md`.

## [5.5.0] - 2026-09-03

### Added

- `docs/loop-spec/supervisor-interface.md`: the contract an autonomous embedding
  (Claude Agent SDK, Google ADK) programs against, as four ports the plugin owns
  the artifact side of and a supervisor owns the transport side of. Every port
  ships with today's behavior as its default adapter.
- `lib/profile.sh` and `.loop-spec/profile.json`: one named preset
  (`interactive`, `autonomous`, `supervised`, `cloud`) plus overrides, applied as
  env by `cycle-preflight.sh`, `phase-mode.sh`, and the supervisor probes. A
  variable already set in the environment wins over the file.
  `cycle-preflight.sh run` reports `profile:{preset,source}` and `store:{name}`.
- `lib/supervisor/store.sh`: the state-store port at the durability boundary.
  `feature-write.sh` and `phase-exit.sh` call `persist`; the preflight resume scan
  calls `list` and `open`. `store-local.sh` (the checkout is the store) is the
  default; `store-mirror.sh` mirrors to `LOOP_SPEC_STORE_DIR`. Any adapter must
  pass `tests/lib/supervisor-store-contract.test.sh`.
- `lib/events.sh sink` and `LOOP_SPEC_EVENT_SINK`: every emitted event line, and
  the terminal result as event `result`, is also written to a supervisor's
  executable. A failing sink is one warning, never an abort.
- `lib/supervisor/oracle.sh mode` and `LOOP_SPEC_ORACLE`: the middle mode between
  the interview and self-answer. `supervisor` makes SPEC and DISCUSS ask through
  the harness question tool first (Agent SDK `canUseTool`, ADK `get_user_choice`,
  opencode `question`, Codex `request_user_input`) and record answers as
  `decisions.sh` kind `supervised`; `halt` pauses with reason `oracle-halt`.
- `docs/loop-spec/cloud-run-autonomous.md` cites the `cloud` preset instead of
  carrying the export block.
- The native integration map: each port named against the Agent SDK seam
  (`env`, `plugins`, `session_store`, `PostToolUse`, `can_use_tool`, `resume`,
  `max_budget_usd`) and the ADK seam (`LocalEnvironment`, `BaseArtifactService`,
  `BasePlugin` callbacks, `LongRunningFunctionTool`, `Runner.run_async
  invocation_id`) it lands on, in the design doc and both harness contracts.
  `extensions/adk/loop_spec_adk/bridge.py` resolves the profile through its own
  environment seam. `examples/supervisor/` is a runnable reference supervisor on the
  Python Agent SDK that exercises every SDK-side row.
- `llms.txt` at the repository root: the entry map for an agent pointed at this
  repository (what to run, what to read, what not to invent). The supervisor
  interface doc opens with a six-step quick start for implementers and a checklist
  for the agent inside a supervised run; README, `docs/adopting.md`, and the
  architecture layout point at both.

## [5.4.0] - 2026-09-03

### Added

- `skills/shared/engineering-stances.md`: the five senior-engineer stances (build
  from scratch, system design, refactor, debug, performance), each a mindset plus
  the deliverables that prove it was held and the artifact section they fill.
  Bound by cite from SPEC's Foundations round, DISCUSS's design grill, the planner
  and pattern-mapper, the code-reviewer (a new `perf:` performance pass), the
  iterate-judge, the debug loop's `## Fix`, and quality-loop. PLAN.md gains a
  `## System design` section; VERIFICATION.md gains a `#### Performance` list.
  Pinned by `tests/engineering-stances-coverage.test.sh`.
- `lib/graph/gate.sh next`: the critique gate's delta-round probe. After each fail
  entry it answers `ANSWER=rerun|close REASON=...` from the loop ceiling
  `graph/critique.graph.json` declares and the rounds `feature.json` records,
  closing the gate when the ceiling is spent or, under a raised ceiling, when
  one finding survives two consecutive delta rounds. `LOOP_SPEC_CRITIQUE_ROUNDS`
  outranks the graph (`0` = unbounded). PLAN's feasibility FLAG loop, the
  critique's sibling, is counted through the same probe under gate
  `plan-feasibility`.

### Fixed

- Four hook suites (`done-criteria`, `deferral-guard`, `strategy-rotation`,
  `stop-deflection-guard`) failed in a fresh clone because each hook self-scopes
  to a project with a `.loop-spec/` directory and the suites relied on the
  checkout having one. Each suite now supplies its own project directory.
- `tests/configuration-coverage.test.sh` failed because the `settings` skill takes
  arguments and `docs/loop-spec/configuration.md` had no row for it.

### Changed

- The critique gate protocol no longer says retries are unbounded. Runs were
  spending over an hour bouncing PLAN.md between the challenger and the planner:
  the graph's ceiling sat inside a `contain` loop the engine never counts, and the
  prose kept every disputed finding alive forever. The gate now closes with
  `convergence: cap-reached` and the surviving findings in the gate log only; the
  critique graph's ceiling is lowered from 3 to 2 delta rounds.
- The challenger's delta re-verify is narrowed: every `DELTA-FINDINGS` line is
  `unaddressed:` (a fix-list item) or `introduced:` (a quoted added line); text the
  revision did not touch is out of scope.

## [5.3.0] - 2026-09-03

### Changed

- `tests/run-all.sh` is now a fast unit gate: by default it runs only
  `tests/lib/*.test.sh` suites, minus the ones tagged `integration`
  (subprocess-heavy or multi-file), instead of every registered suite.
  `RUN_ALL_PROFILE` gains a `unit` value (the new default) alongside
  `selected`; `full` is gone. Hook tests, validators, harness-coverage
  suites, and workflow syntax checks stay registered (so
  `tests/all-tests-registered.test.sh` still tracks them) but no longer run
  automatically — invoke a suite's own file directly to run one by hand.
  `tests/lib/detect-test-cmd.test.sh` also had a pre-existing `$ROOT`
  unbound-variable bug fixed so the new gate passes cleanly.

## [5.2.0] - 2026-09-02

### Added

- The dependency-idiom rule: design phases now consult a dependency's CURRENT
  documentation instead of model memory before asserting how a framework does
  something. `lib/doc-deps.sh scan` (with `lib/doc-deps.py`) deterministically
  names the dependencies in play — the imports of the touched files intersected
  with the repo's manifests (py/js-ts/go), never the whole manifest — and
  `LOOP_SPEC_DOC_DEPS` lets the operator override it. SPEC's scout and the
  planner brief carry the fetch mandate (any web search or URL-fetch tool the
  session provides; `curl` as the floor; policy-blocked native tools fall back
  to custom tools or the lead), findings land in the evidence ledger as
  `EVID-NNN` entries only, and `lib/doc-deps.sh gate` blocks PLAN's phase-exit
  when a named dependency has neither a doc-backed `EVID` nor an `ASSUMPTION`
  bullet in `## Grounding` — offline runs pass through the `ASSUMPTION` hatch.
  `agents/planner.md` and `agents/spec-writer.md` gain WebFetch/WebSearch, and
  `skills/shared/engineering-directives.md` gains the mid-EXECUTE row: unsure
  how an imported dependency does something, fetch its docs before writing the
  call.

## [5.1.0] - 2026-09-02

### Removed

- The generated 5-domain codebase map, by the same test that removed graphify in
  2.35: no consumption evidence, three of five domains trivially re-derivable
  live, and autonomous runs structurally unable to ratify the prose. Gone: the
  five `mapper-*` agents, the `map-codebase` skill, `lib/map-{audit,trust,
  refresh,policy,index-prune}.sh`, `lib/workflows/map-codebase.js`,
  `gsd-ingest`'s `codebase` subcommand, `bootstrapPendingDomains` /
  `artifacts.codebaseSource` feature state, the `MAPPER` model role, and the
  `LOOP_SPEC_MAP_*` knobs. DISCUSS no longer gates on a map join (phase-exit
  exit 3 is retired) and VERIFY no longer refreshes a map. PATTERNS.md plus
  live scout exploration carry the load; `pattern-mapper` survives because it
  is feature-scoped and regenerated per cycle, not a stored map. (PR #84)

## [5.0.0] - 2026-09-02

Breaking: the plugin's prose was cut by roughly two thirds so any model family can
follow it, and the mechanics that prose used to describe now live in scripts.

### Added

- **Engineering directives.** `skills/shared/engineering-directives.md` is the one file
  every code-producing dispatch names: simple over clever, idiomatic for the version the
  repo pins, versions and advisories from a tool (manifest, package manager, registry, or
  whatever lookup the harness offers) never from recall, the scaling input named before
  code, tests first with one test per break. The planner names each task's scaling input
  and version source; the code reviewer reports `recall:` for a version pinned without a
  tool source. Pinned by `tests/engineering-directives-coverage.test.sh`.
- **Phase ingress is a script.** `lib/phase-entry.sh <phase>` names the exact
  `feature.json` fields and files a phase consumes and `FLAG`s a missing one at the
  door, so a session resuming after a handoff reads the packet instead of re-deriving
  state. Each phase skill opens with it; `phase-exit.sh` remains the egress. The entry
  call also snapshots `feature.json`, and `phase-exit.sh` diffs the file against that
  snapshot: a key changed outside the phase's allow-list is state no later phase reads
  and is reported as `WARN [egress]` (a `FLAG` under `LOOP_SPEC_EGRESS_GUARD=deny`, silent
  under `off`).

### Changed

- **Startup.** `cycle-driver.sh start` validates model routing through
  `feature-init.sh validate` (every selector checked once, no subshells) instead of
  resolving nine effective maps, which was two thirds of the start time. The
  SessionStart simplicity directive is pointer-style: it names the ladder and the two
  probes instead of restating the rungs, about half its previous size.
- **One contract block per implementer prompt.** The subagent, loop-fleet, and Workflow
  rungs carried nine separate directive paragraphs per task, per attempt; each now
  carries one `ENGINEERING CONTRACT` block that names the contracts to read, the probes
  to run, and the rules that bind without a file read. The subagent stanza drops from
  4523 to 3579 bytes; every coverage pin on the directives still holds.
- **Lookup tools are the harness's call.** The cycle skill no longer declares
  `WebFetch`/`WebSearch` off limits and the implementer role no longer disallows them;
  a version or advisory lookup uses whatever the host program provides.
- **Cycle orchestration is a script.** `lib/cycle-driver.sh` (`start`, `init`,
  `resume`, `map`, `next`, `finish`, `escalate`) owns preflight, invocation parsing,
  feature init, resume adoption, the graph step, model-map activation, journaling,
  state commits, checkpoint PRs, completion, and escalation, answering each call with
  one JSON object or one line. `skills/cycle/SKILL.md` keeps only what needs a harness
  tool or a human; its ten reference files are gone.
- **Phases open and close through scripts.** `lib/phase-mode.sh` decides a phase's path
  (interview, self-answer, synthesize, ingest; which critique gates run) from state, and
  `lib/phase-exit.sh` closes a phase in one call: every deterministic gate, artifact
  pointers, commit, checkpoint tag, team teardown, with `FLAG` lines the phase repairs.
  The seven phase skills drop from 2983 to about 1050 lines; their eleven reference
  files are absorbed. Phase skills no longer write `currentPhase`; the graph engine
  owns it.
- **Shared contracts consolidated.** Six dispatch docs merge into
  `skills/shared/dispatch.md`; the inline, team, Workflow, and foreign execute rungs
  merge into `execute-rungs.md`; `autonomous-mode.md` and `tier-matrix.md` are trimmed
  to their rules; `cycle-resume-escalation.md`, `model-policy.md`, `execute-inline.md`,
  and `execute-loops.md` are removed.
- **Session-mode toggles are one skill.** `/loop-spec:settings <grill|discipline|simplicity|human-code> ...`
  replaces the four toggle skills. The hooks and conf files are unchanged.
- **Graph engine.** In `--step` mode a nested subgraph's traversal lines go to stderr
  so the descriptor is alone on stdout.
- **Tests.** The two coverage sweeps no longer need ripgrep; the suite needs only bash,
  git, jq, and python3. Pins on the removed prose now point at the scripts.

### Removed

- The startup model probe (a bad selector fails loudly at the first dispatch instead)
  and its `LOOP_SPEC_SKIP_HEALTHCHECK`; the ignored `LOOP_SPEC_ANSWER_TIER` and
  `LOOP_SPEC_ANSWER_PRESET` compatibility inputs.
- Historical documents: the scan proposals, audits, conciseness plan, roadmap, design
  snapshot, the self-hosted feature directories under `docs/loop-spec/features/`, the
  self-hosted codebase map, and changelog entries before 4.0.0 (git history keeps them).
  `docs/loop-spec/graph-remediation-contract.md` is the engine contract that used to
  live under the gdd feature directory.

## [4.9.1] - 2026-09-02

### Changed

- **Fable 5.1 prompt alignment.** Shared phase contracts now ask for concise progress
  updates, independent-tool batching, literal prose, useful chat structure, marked source
  quotations, and search verification for fast-moving names. Autonomous runs finish
  already-authorized work and retain goals, constraints, decisions, evidence, and resume
  details through compaction.
- **Execution boundaries.** Implementers keep unrelated defects and tests outside the
  requested change, prefer targeted edits, and leads continue independent work while
  bounded subagent waves run before joining their results.
- **Offline test isolation.** Test suites now ignore injected harness state, canonicalize
  temporary paths, retain required runtime binaries in missing-tool fixtures, and skip
  nested runtime worktrees when checking test registration.

## [4.9.0] - 2026-08-31

The critique-gate transition is a program rather than a procedure a model
performs, an unresolved human-gate admit can no longer be mistaken for a skip,
and the command output that accumulates in the lead's context across a cycle is
bounded without losing the output itself.

### Added

- **`lib/graph/gate.sh`** — the sole writer of `feature.json` `currentGate` and
  `gateHistory`. It derives each attempt number from the entries already
  recorded for that phase and gate, appends the history entry before closing a
  gate, resets to a whole object and never to `null`, and refuses every
  subcommand when no gate is open. `lib/feature-write.sh` refuses both keys to
  any other caller.
- **`lib/output-digest.sh`** — bounded command output: the complete result goes
  to a log file, a fixed head/tail excerpt goes to the agent's context, and the
  wrapped command's own exit code is propagated so no caller's branch changes.
  `run` executes and logs; `print` digests a log another runner already wrote,
  so `lib/run-with-watchdog.sh` composes with it. New operator input
  `LOOP_SPEC_DIGEST_MAX_LINES` (default 40; `0` is refused).

### Fixed

- **The critique gate no longer dead-ends the engine.** `currentGate` had two
  drivers — graph nodes that declare it in `writes[]`, and prose ordered against
  phase-skill step numbers — and the two shipped readings of its reset (a zeroed
  object, or `null`) disagreed. A `null` reset fails `lib/graph/state.sh
  assert-reads` at the critique nodes that declare it in `reads[]`. The
  transition is now code and the contradiction is gone from the docs.
- **An unresolved human-gate admit aborts instead of skipping.** The engine
  treated an admit that could not answer — unreadable `feature.json`, an
  `execStyle` outside the enum, a missing probe, no `admit` declared — the same
  as an answered `gate=skip`, so damaged state silently dropped every human gate
  in a run. Autonomous behavior is unchanged: `auto` and `review-only` resolve
  to `gate=skip`.
- **`feature-init.sh` seeded `currentGate` with two of its six documented keys.**
- **`tests/lib/graph-run.test.sh` no longer writes a fixture into the repo root**,
  which raced `tests/lib/surface.test.sh`'s working-tree snapshot under the
  concurrent runner and failed that suite intermittently.

### Changed

- **The lead's unbounded command output is bounded at its three sites.** EXECUTE's
  per-task `verifyCommand` re-run on both lead-thread rungs, and the grounding
  protocol's lead-runs-probes rule — where output stays on the main thread by
  design, because teammates have no Bash for write-scope containment, and so is
  bounded rather than delegated.


## [4.8.0] - 2026-08-30

Autonomous routing now has a compact path for bounded features and refactors,
without making delivery or terminal observability conditional on that shorter
path.

### Added

- **Auditable compact routing.** `/loop-spec:auto` can select `compact` only
  from a validated, classifier-authored per-gate run/skip plan. Every skipped
  gate records its reason. The plan covers the adaptive quality gates while
  destructive, malformed, uncertain, and unbounded proposals fail upward to
  the full cycle. The public compact-profile contract is shared by Claude
  Code, Codex, OpenCode, and ADK.
- **Terminal compact evidence.** `result.json` and the stable terminal pointer
  retain the persisted classification and gate plan when available. Legacy
  result records remain unchanged when no compact context exists.

### Changed

- **4.8.0 release.** README, configuration reference, harness contracts, and
  plugin manifests describe compact routing while retaining exact-SHA delivery
  and terminal-result publication as invariants.

## [4.7.2] - 2026-08-29

Placeholder `AskUserQuestion` waits still fired in EXECUTE, VERIFY, ITERATE,
and DELIVER after 4.6.1's instruction-only forbid. The lead invented
`wait` / `n/a` / "Type something" / "not a real question" while a background
Agent or the DELIVER check wait ran.

The introducing commit is `8adeb32` (conciseness stage 5): it replaced the
only valid ITERATE `AskUserQuestion({ questions: [...] })` with prose
shorthand and flattened the SPEC gate prompts the same way. Without an
in-phase call-contract example, the model emits the invalid dummy flat
shape. EXECUTE's plan-adherence gate was never a structured call.

### Fixed

- **Call contracts restored, not just filtered.** ITERATE's Re-open SPEC
  gate, SPEC's Spec gate / Max rounds prompts, and EXECUTE's plan-adherence
  re-queue/abort are `AskUserQuestion({ questions: [...] })` again. VERIFY
  drops `AskUserQuestion` from `allowed-tools` (it has no real question).
- **Dummy wait questions are denied at the tool boundary.**
  `hooks/team/placeholder-question-guard.sh` (matcher `AskUserQuestion`) blocks
  the live dummy tells, any question while an Agent is still running, every
  question during VERIFY/DELIVER, ITERATE questions other than the
  Re-open SPEC gate, and EXECUTE questions other than Plan gap /
  specifying-gates. Every question in a batch must be allowed, so one valid
  header cannot mask another question; allowed headers must also match their
  published single-select question and option contracts. Gate specification now
  records executable commands, exact pass/fail rules, and the canonical
  `dispatchBrief` field. Real questions about a product's
  ping or keepalive behavior are not mistaken for agent keep-alives. Phase
  restrictions follow the active skill in the harness transcript, so persisted
  state cannot block the cycle entrypoint's resume/new-feature question. Kill switch:
  `LOOP_SPEC_PLACEHOLDER_QUESTION_GUARD=0`.
  ITERATE, DELIVER, the EXECUTE subagent/loop-fleet rungs, VERIFY workspace
  joins, and cycle phase dispatch now say dispatch-then-stop instead of
  "lead waits". Pinned by `hooks/team/placeholder-question-guard.test.sh`
  and `tests/lib/harness-call-shapes.test.sh`.

## [4.7.0] - 2026-08-28

SPEC and PLAN get shorter without dropping the DISCUSS grill or the
challenger. DISCUSS no longer re-authors and re-debates an already-gated
spec. PLAN does not pay opus for PATTERNS.md or a challenger-before-lints.
The advocate debate round is gone. Phase joins no longer `sleep`-poll
background Agents (up to 120s for PATTERNS, 600s for codebase maps).

### Changed

- **Advocate dropped; challenger stays.** Critique is one critic plus lead
  adjudication. A disputed `[major]` stays on the fix-list (stricter bias).
  Deadlock keeps the finding and continues the delta loop. A security signal
  still runs the challenger — it does not spawn a second critic.
  `graph/critique.graph.json` no longer has a debate node.
  `agents/advocate.md` is retained for schema/validation and is not dispatched.

- **DISCUSS skips spec-writer and spec-critique when SPEC.md is already gated.**
  The grill still runs (`execStyle: auto` included). The lead Edits SPEC.md
  from the transcript when the file exists. `lib/graph/probes/discuss-critique.sh`
  answers `gate=skip` only when `gate_passed` is true, `unresolved_dimensions`
  is empty, there is no security signal, and this is not an ITERATE re-entry.
  Fail closed to `gate=run`. Log line:
  `discuss critique skipped (spec already gated: ...)`. Format and grounding
  lints still run.

- **PLAN runs cheap gates before the challenger.** Feasibility, decision
  coverage, criteria coverage, and grounding run first; coverage-only failures
  still do not re-enter critique. Then the challenger (unless structural
  fast-path or maintenance). If critique changed PLAN.md, those gates re-run.

- **PATTERNS.md is a one-shot pattern-mapper**, not the opus planner, when the
  file is missing after cache/GSD. Prefetch join checks once (never `sleep`).
  Planner last-resort fallback remains if the mapper produces nothing.

### Fixed

- **No `sleep` to join a background Agent.** DISCUSS Step 5.8 and PLAN Step 0
  check once, then proceed or fall back (`Skill(map-codebase)` / pattern-mapper).
  `skills/shared/harness-call-contracts.md` forbids sleep-poll joins. Happy path
  is unchanged (the file is usually already on disk after the overlapping phase).

Pinned by `tests/lib/graph-probes.test.sh`,
`tests/spec-plan-speed-coverage.test.sh`,
`tests/discuss-grill-coverage.test.sh`, and
`tests/lib/harness-call-shapes.test.sh`.

Live contracts that still described an advocate debate (challenger charter,
`team-prompts/challenger.md` / `advocate.md`, architecture diagrams) now match
the challenger-only protocol. PLAN's procedure lists Steps 4b and 5.5 before
Step 3 in the file, not only in prose.

## [4.6.1] - 2026-08-28

AskUserQuestion is not a wait. A live `/cycle` run showed the same
placeholder question (`n/a` / "Type something" / "not a real question")
several times through SPEC and PLAN, not once at pruning. Claude Code
backgrounds Agent calls by default; the lead invented a fake question at
every join: SPEC scout fan-out, PLAN/DISCUSS `TeammateIdle`, the critique
gate, and the fresh-eyes pass. The wait is: dispatch, then stop. The
harness resumes this turn. Dummy wait questions are forbidden.

### Fixed

- **AskUserQuestion is never a wait, on every Agent join.**
  `output-styles/loop-spec.md` (Claude chat slot) and
  `skills/shared/report-style.md` (peer harnesses) forbid placeholder /
  keep-alive questions. The recorded contract in
  `skills/shared/harness-call-contracts.md` says dispatch-then-stop.
  SPEC scout fan-out, PLAN/DISCUSS teammate joins, the shared critique
  gate, VERIFY, EXECUTE, map-codebase, cycle startup probes, and the
  no-teams fallback (one-shot Agents are not synchronous on modern CC)
  all carry that line. Lead-facing `Wait for TeammateIdle` is gone;
  second-idle escalation stays a real stuck-teammate question. Still
  never emit `run_in_background`. Pinned by
  `tests/output-style-coverage.test.sh`,
  `tests/lib/harness-call-shapes.test.sh`, and
  `tests/bmad-import-coverage.test.sh`.

## [4.6.0] - 2026-08-28

### Added

- **The design gate is now four questions.** Every code-producing dispatch asks, before
  implementing and again before DONE: more modular? more extensible? least code? and
  **does this hold at production scale?** (memory and work bounded against
  deployment-sized input, not the fixture). The canonical text lives in
  `skills/shared/implementer-contract.md`; the challenger critiques scale at design time
  and the code-reviewer's design-for-change pass gained a blocking `scale:` finding tag.
  Pinned by `tests/implementer-contract-coverage.test.sh`.
- **`skills/shared/critique-gate-protocol.md`** — the shared critique/adjudication
  procedure DISCUSS and PLAN previously each restated; each skill now states only its
  deltas.
- **`skills/cycle/references/`** (`feature-init.md`, `phase-loop.md`, `completion.md`,
  `startup-health.md`, `phase-activate.md`),
  **`skills/execute/references/`** (`workspace-mode.md`, `conflicts.md`,
  `rung-workflow-foreign.md`),
  **`skills/verify/references/`** (`pre-team-gates.md`, `post-hard-gate.md`), and
  **`skills/spec/references/interview-prompts.md`** — heavy procedure extracted from
  always-loaded skill bodies into on-demand references
  (`skills/cycle/SKILL.md` 1327 → 498 lines; `skills/execute/SKILL.md` 791 → 446;
  `skills/spec/SKILL.md` 426 → 344; `skills/verify/SKILL.md` 594 → 409). Pinned under
  500 lines for every `skills/*/SKILL.md` by `tests/human-docs-coverage.test.sh`.

- **`lib/feature-bootstrap.sh`** — the deterministic tail of cycle Step 5 (environment
  prep, opt-in baseline, feature.json skeleton write) now runs as one script whose
  source never enters context; `skills/cycle/references/feature-init.md` keeps only the
  judgment half (PR adoption, execution root, `EnterWorktree`). `prepare-repo` is the
  per-repo half workspace Step 5 calls (same prepare, pytest upgrade, opt-in baseline,
  and `write-terminal` on failure as single-repo `finalize`). Unit suite:
  `tests/lib/feature-bootstrap.test.sh` (happy path plus prepare/baseline/finalize
  failure, greenfield skip, and split-root publication).

- **`tests/lib/run-with-watchdog.test.sh`** — instant success-path, non-zero exit,
  and usage-refusal coverage for the watchdog (including `--timeout-secs 0`, which
  used to disable the deadline). Idle/wall expiry cases stay out: they wait out
  real seconds and the suite is offline-and-instant by policy.

### Changed

- **Skill frontmatter descriptions trimmed to trigger + not-for.** Descriptions load at
  every session start; the six phase skills shared a 26-word cycle-internal boilerplate
  and several entry skills restated body procedure.
- **Reference files over 100 lines open with a contents line**, so a partial read sees
  the file's scope.
- **Charter/team-prompt dedupe.** `agents/challenger.md` cites `team-prompts/critic.md`
  for the finding taxonomy instead of restating it; `team-prompts/reviewer.md` cites the
  spec-compliance-reviewer charter (already in the teammate's context via
  `subagent_type`) for the review procedure and keeps only the task-metadata mapping.
  The implementer team prompt keeps loop mechanics and a compact charter-cite +
  path-delta stanza (`${CLAUDE_SKILL_DIR}/../../lib/` rather than `{probe_dir}`) so dual
  pins still fire without restating the charter; the advocate pair shares no real text
  (one-shot critique vs debate rounds). The challenger charter keeps the exact
  `UNGROUNDED:` emit line so a one-shot `Agent({subagent_type: loop-spec:challenger})`
  has the format without loading the team prompt.
- **Conciseness pass across the shipped markdown** (`docs/loop-spec/conciseness-plan-2026-08.md`):
  the two EXECUTE implementer prompt templates share one contract stanza; VERIFY's
  remediation teardown is one named sub-procedure; ITERATE/DELIVER cite their shared
  contracts instead of restating them; simplicity/human-code/discipline aux skills cite
  their canonical text (the ladder, the probes, the inject) instead of holding copies;
  `harness-call-contracts.md`'s per-harness appendices are pointers at each adapter's own
  dispatch section. No contract text was dropped — every pinned needle moved with its
  text or its suite was updated in the same commit.
- **The test suite is offline-only and fast.** `tests/e2e/` and all timing-dependent
  cases are removed; suites run under a hermetic git config so a machine's global
  fsmonitor/commit-signing settings cannot hang test commits. Full run: ~11 min → under
  2 min, 193 suites.

### Added (landed before this release cut, previously under Unreleased)

- **Red-then-green TDD is required on every code-producing task.** Omitting a
  TDD label in the plan does not exempt the implementer. Skill/config/docs
  tasks stay excluded. Every implementer dispatch (named agent, team prompt,
  subagent, loop-fleet, workflow, inline) names the force.

- **`detect-test-cmd.sh` joins every matching language.** A Makefile `test:`
  target, a justfile `test:` recipe, or a Taskfile task named `test` is the
  exclusive project override. Otherwise the probe emits every matching family
  command joined with ` && ` (bun, deno, .NET, Swift, Dart/Flutter, Scala,
  Haskell, Zig, Julia, Crystal, OCaml, Elm, Nim, D, Perl, R, plus the
  markers it already knew). CMake, Meson, and Bazel are fallbacks only when
  no language marker matched. Cycle Step 4 cites the probe rather than a
  one-language list.

### Fixed

- **Test-command detection does not stack build files onto language suites.**
  `package.json` + `CMakeLists.txt` is `npm test`, not `npm test && ctest`.
  Nested Taskfile keys named `test` are not a test task. Cycle rewrites a
  polyglot command that contains `python -m pytest` after venv prepare.
  `interactive` still pauses before every agent dispatch; it is not a
  duplicate of `step`.

- **DISCUSS grill restored for non-autonomous runs.** `execStyle: auto` is not
  autonomous mode: auto still asks (5 Q-round cap); step/interactive stay
  uncapped. The leftover "skip Step 1 when style is auto" example, the optional
  "you may run" iterate wording, and the output-style "ask only when blocked"
  exception had taught models to skip the design-shape loop after SPEC. Autonomous
  mode (`autonomous` token / `LOOP_SPEC_AUTONOMOUS=1`) is unchanged.

## [4.5.0] - 2026-08-26

Draft-PR completion is a first-class terminal result. `cycle-result.sh` classifies a
SHA-bound green draft as `outcome: delivered-draft` with `workDelivered: true`
instead of `completed-with-gaps`. `lib/delivery-reconcile.sh` observes PRs created
outside `lib/deliver.sh` and writes the canonical sidecar. Bash helpers in
`lib/pr-delivery.sh` return snapshot fields instead of mutating `is_draft`.

### Added

- **`outcome: delivered-draft` and `workDelivered`.** Full-cycle `result.json`
  distinguishes an intentional draft PR (human sign-off, safety gates) from
  iterate gaps and aborted runs. `converged` stays false until the PR is marked
  ready; `workDelivered` is the enterprise "did work ship?" gate. Additive on
  schema 1.

- **`lib/delivery-reconcile.sh`.** Terminal result publication and
  `cycle-reconcile.sh` observe an open PR created via `gh`, read required checks
  once, and write `delivery.json` (`delivered-draft` or `ready-for-review`).
  Checkpoint-only PRs stay interrupted unless the agent claimed completion
  (`--accept-checkpoint`). Kill switch: `LOOP_SPEC_DELIVERY_RECONCILE=0`.

- **`pr-delivery.sh observe`.** No push, create, metadata edit, or ready flip.
  Binds `--sha` to the existing PR head and remote branch, then classifies a
  one-shot check observation.

- **Claude Code output style `loop-spec`.** The working contract binds in
  `output-styles/loop-spec.md` (`force-for-plugin: true`,
  `keep-coding-instructions: true`): name the phase when it changes, one
  thought per action, then one outcome-first close. Total mid-turn silence is
  not the contract. The manifest names `"outputStyles": "./output-styles/"`.
  The same text in a hook or CLAUDE.md does not shape chat. Durable reports
  stay in `skills/shared/report-style.md`. Contributor rules in CLAUDE.md now
  name a moment, an artifact, and what to do instead of a bare forbid. The
  ponytail compact directive is a stop-at-first-rung nudge. Skill and agent
  `description:` lines name a recognizable moment and when not to fire.

### Fixed

- **`validate_pr_snapshot` no longer mutates `is_draft`.** Temps are local; the
  caller assigns script-level identity fields through `apply_pr_snapshot`.
  `refresh_remote_sha` and readiness observation refresh their output files in
  the caller's shell and expose the value through a reader helper, so the auth
  outcome `run_gh` records still reaches `fail_delivery`: an expired credential
  is reported as `authentication_failed`, not as a generic `remote_query_failed`.

- **`observe` reports the base branch the PR actually has.** It never edits
  metadata, so it no longer echoes the requested `--base` into the delivery
  record. An explicit `--base` is now an assertion: a PR retargeted away from
  the feature base is `pr_identity_mismatch`, and `delivery-reconcile.sh` passes
  `--base` only when `feature.json` records one.

- **A checkpoint PR is not `workDelivered`.** `write-terminal` matched the
  full-cycle contract only for the delivery URL; a result whose `prUrl` is the
  checkpoint salvage URL now reports `workDelivered: false`.

- **Hook suites no longer race SIGPIPE.** A hook that exits before draining
  stdin (kill switch, out-of-scope project) closed the pipe while the writer was
  still queued, and `set -o pipefail` reported the pipeline as 141 even though
  the hook exited 0 — reproducible at 17% under CPU contention, which is what
  `run-all.sh` creates by running suites in parallel. Every hook suite now feeds
  its payload by here-string, and `tests/hook-payload-stdin.test.sh` keeps the
  pipe from coming back.

- **VERIFY marker/tamper gates in workspace mode.** `verify.marker` and
  `verify.tamper` took `{baseSha}` and `{featureRepoRoot}`, which resolve empty
  when `baseSha` is per-repo and the workspace root is not a git repository. The
  engine treated that as a gate failure and published a premature `FAILED`
  result. Both nodes now pass `--feature-dir {featureDir}`; `lib/feature-scan-each.sh`
  runs the scan once per repo.

## [4.4.1] - 2026-08-26

Graph routing after EXECUTE and DELIVER. The deliver-next probe reads
ignored `delivery.json` so a successful DELIVER reaches `completed`
instead of publishing `failed`. Workspace features no longer fail
`assert-reads` on a null top-level `branch`. After a rung that finishes
the DAG inside the execute node, the engine skips `execute.worker`
instead of dispatching `loop-spec:implementer` against an empty
`mergeQueue`.

### Fixed

- **Deliver-next probe reads the sidecar.** A successful DELIVER writes
  `nextPhase=completed` only to ignored `delivery.json` (tracked
  `feature.json.delivery.nextPhase` stays null, or stale `execute` after
  an earlier CI remediation). The graph probe read the tracked field, so
  no post-delivery route satisfied and the engine published a spurious
  `failed` terminal result. Prefer the sidecar; fall back to tracked
  state for dry-run fixtures and durable execute-remediation. This also
  makes the CI-remediation ceiling reachable: at the limit `lib/deliver.sh`
  writes `nextPhase=deliver` to the sidecar only and leaves tracked
  `execute` in place, so the tracked read routed back to EXECUTE forever
  instead of stopping at DELIVER.

- **Workspace execute no longer fails assert-reads on a null top-level
  `branch`.** `graph/cycle.graph.json`'s execute node (and
  `execute.worker`, `verify.code-review`, `deliver`) declare a `branch`
  read. Workspace-mode features keep top-level `branch`/`baseSha`/
  `baseBranch` null by design. `state.sh assert-reads` treated that as a
  missing key. It now takes `workspace.repos[]` as authoritative for
  those identity keys, and only those: every other key, `worktreePath`
  included, still fails when null in either mode, with `optionalReads[]`
  the way to declare one the schema lets be null.

- **Execute fanout is skipped when `mergeQueue` is empty.** The execute
  node had one outgoing edge: an unconditional fanout to `execute.worker`
  (per-task `loop-spec:implementer` for the workflow/loop-fleet mergeQueue
  path). The subagent rung — hard-pinned by workspace mode — dispatches
  and merges inline and never touches `mergeQueue`, so the engine walked
  to the worker anyway. `lib/graph/probes/execute-fanout.sh` admits the
  fanout only when the queue still has work; otherwise the path goes to
  `human.after-execute`. An unresolved probe takes that same skip as
  `routeDefault`, so EXECUTE cannot abort the cycle the way a missing
  DELIVER sidecar used to.

## [4.4.0] - 2026-08-25

Superpowers EXECUTE dispatch contracts. loop-spec ports the session-level
mechanics Superpowers measured on live evals into the cycle's four peer
harnesses: file-handoff briefs, resume/fresh-upgrade/breaker fix-loop, no
nested subagents, `unverified[]` the lead must resolve, rulings vs four stop
reasons, and fail-closed `batchGroup`. S8 and the skip list were not ported.

### Added

- **Superpowers EXECUTE ports** (`docs/loop-spec/superpowers-scan-proposals.md`).
  File-handoff briefs and review packages (S1); resume/fresh-upgrade/breaker
  fix-loop with scoped re-review (S2); no nested subagents on named roles (S3);
  prejudge-lint on templates (S4); `unverified[]` the lead must resolve (S5);
  conflict table + rulings vs four stop reasons (S6); fail-closed `batchGroup`
  collapse (S7); writing-good-tests catalog on implementer prompts (S9);
  `mechanical` → `haiku` on Claude Code only (S10); task-worktree remove never
  `--force` (S11). S8 and the skip list were not ported.

  Audit follow-ups on the same ports: a reviewer `pass` carrying `unverified[]`
  is downgraded to `rework` so the items cannot merge on the last attempt (S5);
  `batchGroup` collapse also refuses when a task outside the group waits on a
  member id the collapse would erase (S7); `lib/fix-loop.sh action` takes the
  effective `maxRetriesPerTask`, and EXECUTE reads that cap from
  `lib/tuning.sh get executeMaxRetriesPerTask` so a tuned overlay actually
  moves Workflow retries, team `{maxRetriesPerTask}`, and the breaker (S2);
  `lib/execute-stop.sh` delegates its security tier to `lib/security-signal.sh`
  instead of re-listing the terms, so "must not modify the auth middleware" is a
  ruling rather than a stop (S6); worktree-removal refusals print git's own
  reason instead of asserting a cause (S11).

### Fixed

- **Codex interactive SPEC/DISCUSS/PLAN now wait for the user.** The Codex
  contract treated `AskUserQuestion` as "ask in the transcript", which Default
  mode does not block on, so those phases ran as if autonomous. They now map
  onto `request_user_input`, SessionStart tells the lead to wait, and
  `lib/codex-install.sh` writes `[features] default_mode_request_user_input =
  true` so Default mode exposes the tool. Headless `$loop-spec-auto` /
  `codex exec` is unchanged.

## [4.3.0] - 2026-08-19

First-party OpenAI Codex harness. loop-spec now ships four peer contracts from
one source tree: Claude Code, OpenCode, Google ADK, and Codex
(https://developers.openai.com/codex). Codex is not a port of Claude Code —
it expresses the same cycle through plugins, skills, `codex exec --json`,
`spawn_agent`, and lifecycle hooks.

### Added

- **Native Codex plugin.** `.codex-plugin/plugin.json` (skills +
  `hooks/codex-hooks.json`) and `.agents/plugins/marketplace.json`
  (`source.path: "./"`). Codex looks for `hooks/hooks.json` by default; this
  plugin points at `codex-hooks.json` so Claude-only Stop polarity is never
  loaded. Plugin-bundled hooks stay skipped until `/hooks` trusts them.
- **`lib/codex-install.sh`.** Generates `$loop-spec-<name>` skill adapters and
  `agents/openai.yaml` invocation policy under `.agents/skills` (user or
  `--project`), custom agent TOML under
  `~/.codex/agents/` / `.codex/agents/` for `spawn_agent`, a marked
  `[shell_environment_policy.set]` block so Bash subprocesses receive
  `LOOP_SPEC_HARNESS=codex` without waiting on hook trust, and a merged
  `.codex/hooks.json`. Merged config and hook state stays separate from
  fully-owned manifest artifacts, so uninstall removes only loop-spec entries
  and preserves user settings. `--model role=slug` (and `adversarial=`) pins
  generated agents. Marketplace is written only when `--project` is this clone.
- **Codex adaptation contract** `skills/shared/codex-harness.md`. Detection is
  `LOOP_SPEC_HARNESS=codex` (Codex stamps no `CLAUDECODE` equivalent).
  `executionRootMode: "in-place"`. Teams/Workflow stay fail-safe `none`/`false`.
  One-shot `Agent` maps onto `spawn_agent` (`agent_type: loop-spec-<role>`,
  `message`, `task_name`, `fork_turns: "none"` when those fields exist).
- **Headless backend.** `loop.py --agent-cli codex` drives
  `codex exec --json --sandbox workspace-write` (work) / `read-only` (plan).
  It stamps both `LOOP_SPEC_HARNESS=codex` and the non-interactive profile into
  the child environment.
  Cost is `None` (tokens, not USD); `--max-budget-usd` is rejected like ADK.
  Resume is `codex exec resume <thread_id> --json`. Issue intake uses the same
  seam.
- **Codex-specific hooks.** SessionStart injects the micro protocol; PreToolUse
  Bash prefixes the env contract (`hooks/codex-shell-env.sh`); UserPromptSubmit
  runs `done-criteria.sh`. Claude Stop guards are **not** bridged: on Codex,
  `decision: "block"` continues the turn and `continue: false` allows stop
  (https://developers.openai.com/codex/hooks).

### Changed

- `lib/harness.sh` detect/cli/subagents include `codex`. `lib/bump-version.sh`
  and `tests/validate-manifest.test.sh` keep `.codex-plugin/plugin.json` in
  lockstep with the Claude manifests and the README line.
- Cycle, no-teams, model-matrix, loop-fleet, autonomous, sentinel, adopting,
  and configuration docs grow a Codex branch. Contributor guidelines name four
  peer harnesses.

## [4.2.2] - 2026-08-19

Named implicit-team spawns inherit the lead session model. `LOOP_SPEC_PHASE_MODEL_EXECUTE=sonnet` and per-role aliases were documented as binding on every teammate; on Claude Code >= 2.1.178 they were a no-op (`task_type: in_process_teammate`). OpenCode `task` still has no per-call model. ADK can now forward a native id on `dispatch_subagent`.

### Fixed

- **Implicit-team role routing binds on nameless Agents.** `lib/implicit-team-model.sh` is the probe: `inherit` keeps a named teammate; a Claude alias omits `name` so `Agent({model})` is honored, and rework follows the no-teams fallback. EXECUTE skips the team rung for an implementer alias and uses loop-fleet or subagent instead. `skills/shared/implicit-team-mode.md` no longer tells the lead to "add the model key per teammate."
- **ADK `dispatch_subagent` takes optional `model`.** A native `gemini-*` or `provider/model` id from `feature.models.<role>` is forwarded; `inherit` and Claude aliases still use the mounted agent. `feature-init.sh` accepts native role ids under ADK for every role, not only IMPLEMENTER.
- **OpenCode phase env is not a `task` parameter.** The contract now says so: pin task roles with `opencode-install.sh install --model` or a project agent override; `LOOP_SPEC_MODEL_IMPLEMENTER` still routes loop-fleet `--model`.

### Changed

- Harness call contracts, model-matrix, cycle/phase skills, and configuration docs record in-process teammate inheritance as harness behavior, not a loop-spec bug.

## [4.2.1] - 2026-08-19

`protocol-mismatch` stopped the v3.0.1 freelance path (leave the routed protocol, do
the work by hand, publish nothing). It then over-applied: `/loop-spec:auto` would
correctly send a merge-conflict resolution, PR sync, or re-review into the full cycle,
and the cycle would decline it because the seven-phase shape looked like a poor fit.
Headless callers gating on `converged` still failed, and nothing was delivered.

### Changed

- **`protocol-mismatch` is a genuine non-task only.** A pure question, or work that
  needs a different product, still publishes `escalated` / `protocol-mismatch` /
  `converged: false` on an unmodified tree. A rebase, branch sync, merge-conflict
  resolution, PR re-review, or one-command chore is repository work: micro when the
  bounds hold, full with the maintenance profile / graph short path when they do not.
  The router having accepted the task is decisive — the cycle executes it.
  `skills/shared/route-exit-contract.md`, the cycle/micro/debug/auto skills, the
  agent-output contract, and the route-terminal-guard message all say so. The
  maintenance short path still walks PLAN → EXECUTE → VERIFY → ITERATE → DELIVER and
  still publishes `write --status completed` (or `--outcome delivered`) on the
  `completed` node; skipping DELIVER to save ceremony is the same unaccounted ending.
- **Empty ITERATE summary still publishes.** `cycle-result.sh write --status completed`
  used to refuse a blank `--summary`, so a delivered PR with no ITERATE verdict looked
  like a failed run to a headless caller. It now falls back to the iterate summary when
  present, else `Cycle completed; PR delivered.` when delivery is `ready-for-review`.
  Cycle On completion does the same instead of aborting.
- **Classification survives `begin`.** `/loop-spec:auto` persists the validated
  classification on `.loop-spec/active-run.json`. Cycle Step 3 reads it when no
  `profile:` token is on the invocation, so `profile=maintenance` still selects if the
  token is dropped. A later `begin` without `--classification` keeps the armed object;
  fail-closed routing still arms without one.
- **Named open PRs are adopted, not re-minted.** `lib/adopt-pr.sh` is the probe: a
  GitHub pull URL, `PR #N`, or "this/the PR" on a branch that already has one checks
  out that OPEN, same-repo head instead of `feat/{slug}` / `micro/<slug>`. DELIVER
  updates the named PR. Workspace mode still mints per repo. Dirt on the adopted
  branch is the work; dirt anywhere else still aborts.

## [4.2.0] - 2026-08-18

Everything this plugin emits is written for a person who has to maintain and operate it.
Two halves were missing. The code directive covered only how a diff READS — nothing asked
what the code SAYS when it breaks, which is the half a person meets at 03:00 holding
whatever the software chose to tell them. And nothing at all governed the documents, though
a cycle writes plenty: SPEC, PLAN, VERIFICATION, the reviewer's guide, a PR body, and
whatever README, guide, or runbook the change makes true or false. Defaults change only in
that both directives ride the existing code-for-humans switch and VERIFY gains one fixable
pass.

### Added

- **`lib/failure-tells.sh` — the operate half of code-for-humans.** Three silences that are
  decidable from the text: `swallowed` (a caught error whose handler does nothing —
  the error-hiding anti-pattern, which erases the only record of what happened),
  `silent-exit` (a non-zero exit with nothing said in the five code lines above it), and
  `contextless-error` (a message whose every word is a synonym for "it broke", so the
  reader learns nothing the crash had not already told them). `scan <file>` reads whole
  files; `diff <base> [head]` reports only what a change introduced. Python, shell, and
  js/ts; any other language is skipped and counted, never guessed at.
  It is quiet wherever the code already says why: a narrow exception type (`except
  FileNotFoundError` names the case), a comment inside the handler, an exit guarded by a
  command that reports its own failure (`resolve_root "$1" || exit 2`), and any message
  naming a real noun. Measured across this repository's 352 shell, python, and TypeScript
  files: **1 finding** — a `sys.exit(4)` whose status code is itself the documented
  contract, which is the known false-positive class. The four `except Exception: pass`
  handlers it found in `lib/graph/engine.py` were real, and each now carries the reason it
  always had.
- **`skills/shared/human-code.md` gained its second half.** Three principles — fail loudly
  or say why you did not; an error message names what broke and the next move; a non-zero
  exit says why before it exits — plus a section stating exactly what the probe checks and
  what stays a judgment (whether an error should have been retried, whether a log line is
  at the right level, whether the handling is correct at all).
- **`tests/lib/failure-tells.test.sh`** — 25 cases pinning the three silences and the four
  deliberate shapes the probe must stay quiet on.

- **`skills/shared/human-docs.md` — the docs-for-humans contract.** The fourth member of
  the set beside the laziness ladder, design-for-change, and code-for-humans. Eight
  principles: name the reader and what they can do when they finish; one job per document
  (Diátaxis — a how-to gets a task done, a reference states facts, an explanation says
  why, and blending them serves neither reader); a procedure states its prerequisites,
  then the exact copy-pasteable command, then what success looks like, then what to do
  when the step fails; cite, never copy; the document ships in the diff that changes the
  behavior; write the document the project will maintain; ground every claim; write for a
  reader in a hurry. The contract states per rule which ones a script checks and which
  stay judgments, rather than claiming enforcement it does not have.
- **`lib/doc-tells.sh` — the deterministic corner of it.** Three checks decidable from the
  text and the tree: `dead-link` (a relative link whose target is not on disk),
  `stale-ref` (an inline-code path the tree no longer holds), and
  `undefined-placeholder` (a shell command holding a placeholder the document's prose
  never explains). `scan <file.md>` reads whole documents; `diff <base> [head]` reports
  only what a change introduced. `stale-ref` fires only where git tracks files of that
  kind in that directory, which is what keeps runtime state (`.loop-spec/runtime.json`),
  foreign examples (`app/models/user.rb` in a project with no `app/`), and a path named
  because it is gone from being reported as rot. Measured over this repository's own 170
  documents: 181 findings, 149 of them in delivered feature artifacts (frozen records) and
  32 in live documents; the live ones were sampled and were real.
- **VERIFY Step 7.66 — the docs-for-humans pass.** Runs `doc-tells.sh diff` over the
  change. Findings are fixable rather than advisory: each names a file, a line, and a
  one-line edit. The escape hatch is narrow and recorded — a documented misfire is written
  into VERIFICATION.md with its reason and does not block.
- **A docs pass in `agents/code-reviewer.md` (8.5).** The judgment half: `doc:` from the
  probe and `stale-doc:` (a sentence in a document the diff makes false, quoted) are
  Important and block; `unusable-doc:` (a procedure with no prerequisites, no expected
  output, or no failure branch) is Minor unless the SPEC asked for that document. Evidence
  blocks, taste does not — the same split the code-for-humans pass makes.
- **`tests/human-docs-coverage.test.sh` and `tests/lib/doc-tells.test.sh`.** The coverage
  suite pins the directive into every document-producing dispatch path and fails when one
  loses it; the unit suite pins the three checks and the four look-alikes they must stay
  quiet on.

### Changed

- **The test loop is split by feedback speed.** `tests/run-unit.sh` maps the current
  worktree diff (or an explicit base ref) to same-name unit suites and registered coupling
  tests, including coverage pins for executable Markdown under the plugin's skill, agent,
  command, and rule surfaces. `--list <path>...` explains the mapping without running it.
  The gate then runs just that set plus syntax checks and diff-scoped code/document tells,
  so existing findings elsewhere in a touched file do not poison the edit loop. `tests/run-all.sh`
  remains the complete offline gate, now runs independent suites concurrently, moves the
  graph mutation proofs into a temporary copy, prints concise timing by default, and
  accepts `RUN_ALL_JOBS` / `RUN_ALL_VERBOSE` for diagnosis.
- **The code-for-humans switch now carries all three halves.** `hooks/team/human-code-inject.sh`
  injects the failure-path directive and the docs directive beside the house-style one,
  `/loop-spec:human-code off` and `LOOP_SPEC_HUMAN_CODE=0` disable all of it, and
  `human-code probe` reports `failure-tells.sh` and (for markdown paths) `doc-tells.sh`
  alongside the conventions. One switch, not three: the opencode and ADK bridges replay the
  same hook, so all three harnesses gain the directives without a per-harness change.
- **The code-reviewer's code-for-humans pass runs the failure-path probe too**, and reports
  what it finds as `silent:` — an error swallowed with no reason given, an exit that says
  nothing, a message a person cannot act on. Measured findings are Important and block,
  the same rule the `house:` and `noise:` tags already follow.
- **PLAN carries the documentation task.** `agents/planner.md` asks of every task which
  README, help text, runbook, or configuration table the change makes wrong, names that
  file in the task's `files[]`, and refuses to plan a documentation fix as a follow-up —
  that is the deferred scope the cycle already rejects. The EXECUTE rungs (team, subagent,
  loop-fleet, Workflow) each name the contract and the probes rather than pasting the
  essay, since a SessionStart hook does not reach a dispatched agent.
- **Dispatch, inject, and CLAUDE.md point at the contracts.** `skills/shared/human-code.md`,
  `skills/shared/human-docs.md`, `skills/shared/laziness-ladder.md`, and
  `skills/shared/design-for-change.md` stay the source of truth. Path-scoped
  `.claude/rules/` remind contributors when matching files are opened; they wrap those
  paths in backticks so Claude Code does not `@import` them at launch.
- **VERIFY Step 7.66 no longer swallows the probe.** `doc-tells.sh diff` is a gate:
  exit 1 is a finding to fix, not an advisory list hidden behind `|| true`.
- **`human-docs` is a protected gate id** in `lib/extension-points.sh`: a project layer
  answering to that name would be indistinguishable from the built-in pass in the logs.
- **Two live documents corrected**, found by the new probe on this repository: a
  `tests/smoke.sh` reference in `docs/loop-spec/PREREQUISITES.md` (the file was renamed
  long ago) and a relative link in `docs/loop-spec/architecture.md` written as if from the
  repository root.

### Fixed

- **Workflow implementers resolve the design-for-change contract from the installed
  plugin.** The execute DAG previously handed target-repository agents the relative path
  `skills/shared/design-for-change.md`, which does not exist in the project being changed.
- **Failure-path checks distinguish executable code from examples and comments.** Quoted
  `exit`/`throw` examples and inline comments no longer produce findings or count as a
  diagnostic for a real exit, while heredoc markers inside data cannot hide later code.
- **The surface index suite is portable across BSD and GNU `wc`.** Line-count assertions
  now normalize `wc -l` padding, and `lib/surface.py` uses the keyword form of
  `re.split(maxsplit=...)` required by newer Python versions without deprecation warnings.
- **`/loop-spec:revise` no longer blanket-skips `[bot]` authors.** That discarded
  GitHub's code-review agent `CHANGES_REQUESTED` (processed:0) and silently killed
  the review→revise loop. `lib/pr-comments.sh` now keeps a REVIEW with
  `CHANGES_REQUESTED` (even an empty body) and every inline `review_comment`,
  including bots. Still skipped: self `<!-- loop-spec:revise -->` comments, bare
  LGTM/Approved bodies, and CI/dependabot issue-comment chatter.
  `LOOP_SPEC_REVIEW_BOT_ALLOWLIST` force-keeps named bot issue comments.
- **`revise-branch.sh` no longer tries to `worktree add` a branch that is already
  checked out.** That failed with "already checked out", wasted steps, then fell
  back. If the branch is checked out in the source repo, revise goes in-place;
  if it is checked out in another worktree, that path is reused. JSON reports
  `isolation` and `owned` so Step 10 cannot `git worktree remove` the caller's
  checkout.
- **Headless subagent isolation is lead-created worktrees, not a hope that
  parallel Agents will `git worktree add`.** One-shot Agents share the session
  cwd even with `LOOP_SPEC_WORKTREES=1`. The lead creates each task worktree
  before dispatch (`subagentIsolation=lead-worktree`); wave width > 1 is allowed
  only when those worktrees exist; a failed add serializes. Raising the
  implementer cap is gated on this.
- **`detect-test-cmd.sh` is language-agnostic.** `project.clj` → `lein test`,
  `deps.edn` → `clojure -M:test`, plus Elixir, Maven, Gradle, Bundler, and
  Composer markers. The detector must not assume JS or Python.
- **Revise no longer hand-reconstructs a missing `feature.json`.**
  `lib/revise-state.sh ensure` reuses or writes a schema-7 skeleton via
  `feature-init.sh`; the skill does not author jq.

- **Full-cycle phase markers are emitted by the graph engine, not by cycle-skill
  prose the agent can skip.** A run that called `loop-spec:cycle` once, then
  implemented the feature inline, produced `cycleKind=full` with `phase=unknown`
  and a hidden progress bar: zero `LOOP_SPEC_PHASE_*` lines, zero `[PHASE]`
  tags, zero `events.sh` calls. `lib/graph/run.sh --step` now emits
  `phase_start` / `phase_end` at working-phase node transitions (markers on
  stderr so the `--step` JSON descriptor stays parseable). micro and debug
  still emit from their skills.
- **A delivered full cycle is no longer recorded as `interrupted`.** Three
  compliance gaps stacked: reconcile stamped `converged=false` before
  bookkeeping finished; `write-terminal --outcome delivered` hard-rejected
  (DELIVER's own word, exit 0, write nothing); the agent's turn ended, so
  `last-result.json` stayed failed and the supervisor marked the PR a draft.
  `--outcome delivered` now aliases `write --status completed`. Reconcile
  writes completed when a PR was actually delivered. A success-shaped
  write-terminal that we still refuse exits 3, not 0. The engine publishes
  the terminal result when it enters the `completed` node.

## [4.1.0] - 2026-08-18

Fixes and controls from headless, autonomous, graph-driven runs. Two changes alter
default behavior — the repository-wide suite now runs once per cycle rather than per
EXECUTE wave, and the `skippable` node field is gone. Everything else defaults to 4.0.0
behavior unless a new flag, token, or node field is set.

### Removed

- **The `skippable` node field.** 4.0.0 declared it on one shipped node
  (`plan.critique.gate`), whose body is a fast-path token rather than a script.
  The engine never evaluated the field, so it skipped nothing, invisibly, while
  reading like a live control. A `route` skips the NODE, works for every node
  kind, and shows up in a dry run. One mechanism for "do not run this", not two.

### Changed

- **The repository-wide test/lint/typecheck comparison runs ONCE per cycle, at
  VERIFY.** Every EXECUTE rung — inline, one-shot subagent, agent team, Workflow,
  and the loop-fleet supervisor — ran `lib/feature-validation.sh compare` again at
  each wave or merge-queue boundary, so a run paid a full suite per wave PLUS the
  one VERIFY Step 1.75 runs against the same integrated tree moments later. On a
  single-wave change those two runs were the same commands over the same working
  tree. EXECUTE now runs each task's focused `verifyCommand` after any rebase and
  nothing else. Cycle resume does not run the comparison: it reads
  `tasks.json` for which ids are already `status=done` and continues the
  remaining work (`lib/task-progress.sh`). EXECUTE seeds `mergedSet` from those
  ids and persists `status=done` after each successful publication. VERIFY Step 1.75
  is the suite that
  sees the fully integrated tree. `tests/execution-validation-coverage.test.sh`
  inverts: it now asserts NO rung names `feature-validation.sh`, that cycle
  resume does not either, and that VERIFY does.
- The loop-fleet supervisor's `--feature-dir` flag is removed with the behaviour
  it existed for; it had no other consumer.

### Fixed

- **Graph-driven VERIFY is no longer blocked on sound changes.** The engine
  dispatched every gate body with no arguments, so the placeholder scan, the
  test-tamper scan, and the acceptance lint each exited 2 — a usage error the
  gate node then read as a finding. Node bodies now declare their argument
  vector (`bodyArgs`, a closed placeholder set the engine substitutes), and
  `tests/lib/graph-gate-dispatch.test.sh` runs each shipped VERIFY gate THROUGH
  the dispatch path on the declarations read out of `graph/cycle.graph.json`, so
  standalone-only coverage can no longer hide the class. A gate body's own
  diagnostic now reaches stderr instead of `/dev/null`.
- **The VERIFY node honors the documented opt-out on `verificationBaseline`.** A
  node may declare `optionalReads[]` for keys the schema documents as nullable;
  entering it no longer asserts them. With `LOOP_SPEC_STARTUP_BASELINE` unset the
  baseline is null by design, and the run no longer stops to capture one
  mid-VERIFY. Failures observed later in the cycle still block.
- **The security signal reads context, not bare keywords.** A boundary or
  non-goal mention — `do NOT touch the auth middleware`, `must never modify the
  permissions table`, anything under a `## Non-Goals` heading — no longer buys a
  full advocate/challenger debate on a mechanical change. Suppression is
  structural and auditable: the no-signal answer names what it skipped and why.
  Negated ACTIONS on a security surface (`must never log the credential`) still
  fire, as does every unqualified mention.
- **In-place EXECUTE never attempts a worktree first.** The one-shot subagent
  rung now reads `worktreesEnabled` from the `lib/execute-rung.sh` result before
  composing any prompt, so `LOOP_SPEC_WORKTREES=0` stops paying a denied tool
  call and an error line per task. `tests/cycle-worktree-policy.test.sh` pins the
  ordering.
- **Gate and bookkeeping scripts treat malformed input as a defined state.**
  `lib/acceptance-lint.sh` separates a bad invocation (exit 2) from a criterion
  finding (exit 1) and accepts a tasks path as well as stdin; the graph
  checkpoint ledger skips a record truncated by a killed run rather than handing
  the engine a fragment to parse.

### Added

- **`lib/surface.sh` — one call to locate any bundled script, shared contract,
  or agent role.** `find <term>` narrows by path or purpose, `show <name>` prints
  the header block (usage, exit codes, tool allow-list) so the file usually need
  not be opened, `covers <path>` names the suites `tests/run-all.sh` registers
  that name a path, and `list` prints the whole surface. The index spans `lib/`
  (including the graph route probes), `hooks/`, the shared contracts, and the
  agent role charters; a bare name two files share is refused with both
  candidates named rather than resolved to one of them. Measured on mocked sessions:
  answering "which script does X, what does it exit, and what must I run after
  changing it" fell from 13 opened files to 6. It is derived, never stored — no
  cache, no artifact, nothing to rot — and each purpose line is that file's own
  header, so `tests/lib/surface.test.sh` now fails when a bundled file's header
  does not say what the file is for.
- **A short path through the cycle graph.** Run length was a fixed property: every
  run walked all seven phases plus the full spec-critique protocol, so an hour was
  the FLOOR even for a dependency bump, and the only escape was routing to a
  different protocol (micro/debug) and giving up the cycle's continuity.
  `lib/graph/probes/short-path.sh` answers `path=short` for a maintenance-profile
  run with no security signal in the artifacts it has written so far, and
  `graph/cycle.graph.json` routes around three nodes on that answer: `discuss`,
  the spec-critique subgraph, and the `verify.code-review` agent. PLAN critique
  is still decided by `lib/graph/probes/plan-critique.sh` (security terms in the
  git diff), not by this probe — a short path still visits `plan.critique.gate`.
  Same graph, same checkpoint ledger, same state contract, same terminal result —
  a shorter declared path, visible in a dry run, not a different protocol. Every
  bypass is paired with a route to the long path and a `routeDefault` to it, so an
  unresolved probe lengthens the run rather than stranding it, and the signal is
  re-read from the artifacts that exist NOW so a change that turns out to touch a
  security surface lengthens its own path mid-run. The deterministic VERIFY gates
  (placeholder, tamper, acceptance) and the no-new-failures comparison run on
  both paths. Code review is the one quality gate the short path drops.
- **A maintenance execution profile** (`lib/cycle-profile.sh`, opt-in). Earned
  only by a validated low-risk classification — maintenance-shaped task kind, low
  ambiguity, at most five reviewable files and three criteria, and no seam,
  interface, security, migration, dependency-edge, multi-repo, or destructive
  flag — or by an explicit `LOOP_SPEC_CYCLE_PROFILE` / `profile:` override. SPEC
  synthesizes its spec instead of interviewing. The graph short path then skips
  DISCUSS, spec-critique, and code review when no security signal fires. PLAN
  critique skip is the existing `plan-critique.sh` / skill fast-path, not a
  short-path bypass. The ambiguity gate, the feasibility check, and the
  deterministic VERIFY gates stay; code review is dropped only behind this
  classification. The answer is persisted as `feature.json.executionProfile`, so
  a resume keeps the same ladder.

## [4.0.0] - 2026-08-17

Three peer harness contracts, no reference harness: Claude Code (including the
Claude Agent SDK), OpenCode, and an experimental Google ADK adapter. pi is
removed.

### Removed

- **The pi harness, in full.** `extensions/pi/loop-spec.ts`,
  `skills/shared/pi-harness.md`, `package.json` (which existed only as the pi
  manifest), `tests/pi-extension.test.sh`,
  `tests/pi-harness-coverage.test.sh`, `tests/validate-pi-manifest.test.sh`, the
  `--agent-cli pi` backend and its `fakepi` fixture, and every branch keyed on
  it. An explicit `LOOP_SPEC_HARNESS=pi` now exits with migration guidance
  instead of silently running Claude Code. A stale `PI_CODING_AGENT_DIR` remains
  ignored so it cannot disable agent teams for a Claude Code user.
- `bash lib/bump-version.sh` now has three declaration sites, not four.

### Added

- **Operator controls for low-overhead maintenance runs.** Existing dependency
  version updates can take the micro lane without treating generated lockfiles as
  reviewable source files. Operators can store feature documents outside the PR,
  collapse run metadata in PR bodies, skip automatic map work, set the cycle
  iteration ceiling, and consolidate pure phase-state commits at DELIVER.
- **Google ADK as an experimental first-party adapter.** `extensions/adk/loop_spec_adk/` is the
  bridge: a `LocalEnvironment` carries the static harness/project paths, while
  session state carries `CLAUDE_SKILL_DIR` into each Execute call without
  cross-session leakage. `SkillToolset` serves all 33 skills, and
  `dispatch_subagent` maps Claude Code's `{subagent_type, description, prompt}`
  onto `AgentTool` over the 17 agent charters, so `harness.sh subagents` answers
  `true` on all three harnesses and the full EXECUTE ladder survives.
- **`lib/adk-install.sh`** mounts a working agent and a read-only judge agent
  into an ADK project. Both expose an ADK `App` (which `adk run` loads before
  `root_agent`, and which is the only form carrying the lifecycle plugin) and
  reference the clone by path, so `git pull` updates behavior instead of forking
  it. `check` catches a mount whose package root moved.
- **`--agent-cli adk`** in the loop-runner: `adk run <agent-dir> "<prompt>"
  --jsonl`, normalized onto the same `result.json` contract. Read-only ticks
  select the `_readonly` sibling agent and fail closed when it is missing.
- **`skills/shared/adk-harness.md`** and **`skills/shared/claude-harness.md`** —
  every harness now has an adaptation contract, including Claude Code, which
  previously served as an unstated norm the other contracts read as deviations
  from.
- `tests/adk-extension.test.sh` (against the REAL `google-adk`; skips cleanly
  when absent) and `tests/adk-harness-coverage.test.sh`.

### Fixed

- **17 files had invalid YAML frontmatter.** Unquoted `description:` scalars
  containing `": "` parse under Claude Code's lenient reader but raise under
  strict YAML — which is what ADK's skill loader uses, so `skills/cycle` and 16
  of 17 agent charters failed to load at all. The scalars are now quoted, with
  the parsed values proven byte-identical to what was read before.
- The bridge now uses ADK 2.x's public `load_skill_from_dir` API, exposes the
  documented `get_user_choice` HITL tool, keeps persistent sessions isolated,
  and reaps timed-out lifecycle hooks. The compatibility suite runs against
  `google-adk>=2.7,<3` (Python >=3.10) and reports driver tracebacks instead of
  swallowing them.
- Continue-mode fleet ticks restore ADK sessions through `--session_id`; direct
  `--adk-agent-dir` now reaches compiler, supervisor, and judge paths. A monetary
  budget is rejected under ADK because its JSONL reports tokens but no cost.
- `lib/adk-install.sh` rejects mount traversal and user-file collisions, quotes
  generated Python values safely, enforces and records `google-adk>=2.7,<3`,
  validates both shims, and uninstalls only its marked files. Unrelated mount
  content is preserved.
- Removing the pi-only root manifest no longer leaves OpenCode install metadata
  with an empty version; it now reads `.claude-plugin/plugin.json`.
- Active skills and runtime comments no longer retain pi branches. The removal
  guard scans tracked files, so local bytecode cannot create a false failure.
- ADK and OpenCode now carry Claude Code's full ordered SessionStart injection
  list, including `human-code-inject.sh`. A cross-harness parity test derives the
  canonical list from `hooks/hooks.json`, so adapter tests can no longer bless
  matching stale copies.

### Changed

- Full-cycle terminal-result rejections now name the `write <feature_dir>` success
  contract and list the outcomes accepted by `write-terminal`. The cycle's
  `LOOP_SPEC_WORKTREES=0` branch remains a direct in-place checkout and never
  attempts a guarded worktree first.

- **No harness is the reference implementation.** Claude Code-only capabilities
  (agent teams, `Workflow`, harness task lists, worktree execution roots) are
  kept, not deleted — but each is selected by a deterministic probe that answers
  for every harness and fails safe, and an operator override may turn a
  capability off anywhere while never conjuring one a harness lacks. Docs,
  README, and `CLAUDE.md` lead multi-harness.
- `CLAUDE.md`'s lean-deps carve-out now covers `extensions/adk/loop_spec_adk/*.py`
  importing `google-adk` — the tree's only third-party import, confined to that
  directory, adding no dependency to any other harness.

### Known follow-up

- `docs/loop-spec/codebase/{ARCH,TECH}.md` still describe pi. They are
  `trust: generated` maps whose `file:line` citations this change invalidated
  wholesale; they are left for the next `map-codebase` refresh rather than
  hand-patched with citations nobody re-verified.

## [3.4.0] - 2026-08-13

### Added

- **`house-style.sh compare`: the code-for-humans directive can now demonstrate a
  deviation.** `probe` folds the target into its own sample, so a file that breaks every
  convention around it reports AS the convention — its deviation averages into the baseline
  it is being measured against. Probing only a hand-written offender returned output
  identical to probing its neighbors. The severity rule ("a deviation the probe measured is
  Important and blocks; taste is Minor") had nothing behind it. `compare` holds each file
  out of its own baseline and names where it deviates, both sides measured. Two rules keep
  it honest: the baseline is per-target and same-extension (judging a `.js` file against the
  `.sh` files beside it reports camelCase as a deviation from snake_case, which is two
  languages rather than a violation), and the definition regex is per-language so another
  language's keyword is not read as this file's — jq's `def name(g):` embedded in a shell
  script is jq, not a snake_case-violating shell definition. A shell heredoc's body is
  skipped for the same reason. (An earlier draft tracked shell single-quote state across
  lines to skip embedded `'...'` programs; that was removed after audit — an apostrophe in
  a comment or a double-quoted literal defeated it and silently swallowed the rest of the
  file, turning a false positive into a worse false negative. The per-language regex fixes
  the naming hazard at its source without that fragility.)
- **Two new style axes, and a naming rule that does not fire on correct code.**
  `semicolons` and `module_style` (CommonJS vs ESM) join the measured set — both are loud
  tells that a file was written somewhere else. Naming is checked name by name against the
  neighbors' convention rather than by the file's own majority, since a file holding one
  definition can never form one; and a single-word name like `checkout` is valid camelCase
  and valid snake_case alike, so only the unambiguous crossover is reported.
- **`lib/indirection-scan.sh`: rung 1 (YAGNI) is counted instead of exhorted.** "No
  abstraction with one caller" has been in the ladder from the start, and one-caller
  wrappers keep landing, because at the moment of writing a wrapper always looks like good
  decomposition — the cost is only visible, and only countable, afterwards. The probe names
  each small, private definition a change added that is referenced exactly once. All four
  conditions are load-bearing: it is silent on a long single-caller function (decomposition,
  which is what functions are for), on exported symbols (callers it cannot see), on dead
  code (zero callers is a different finding), and on wrappers that predate the diff. The
  reviewer's `yagni:` tag now rests on that count.

### Changed

- Both probes reach every code-producing dispatch path — implementer, code-reviewer,
  team prompt, both subagent prompts, loop-fleet, workflow, and the SessionStart hooks —
  each resolving the probe path by its own mechanism. Enforced by
  `tests/human-code-coverage.test.sh` and `tests/ponytail-coverage.test.sh`, including the
  carve-outs: a dispatch copy that omits "decomposition is not indirection" would order
  every helper inlined, which is the opposite of the design-for-change companion.

## [3.3.0] - 2026-08-13

### Added

- **Rung 2 of the ponytail ladder (DRY) is now measured instead of exhorted.**
  `lib/duplication-scan.sh` compares the code a run just wrote against the rest of the
  tree and names the file each duplicated block already lives in. `scan <files>` answers
  "does this already exist?" before DONE; `diff <base> [head]` reports only the clones a
  change introduced, so a reviewer sees this author's duplication rather than the
  repository's standing debt. Findings carry `file:line` and are therefore blocking at
  VERIFY under the existing severity rule; the reviewer's over-engineering pass gains a
  `dry:` tag grounded in the probe.
- **The probe matches at two tiers, because the second is the one produced code trips.**
  `duplicate=` is the same lines verbatim; `similar=` is the same lines with every
  identifier and literal replaced. Writing `orders.ts` beside `users.ts` yields the same
  twelve lines with one noun swapped throughout — a verbatim matcher reports that clean, so
  a probe with only the first tier would pass exactly the diffs it exists to catch. The
  shape tier carries its own fences to stay usable: a wider window, rejection of windows
  whose lines are mostly identical to each other (a table of uniform rows otherwise matches
  a shifted copy of itself at every offset), and suppression of any shape finding
  overlapping a verbatim one. Both tiers reach every dispatch prompt, enforced by
  `tests/ponytail-coverage.test.sh`.
- **The directive reaches every code-producing dispatch, not just the canonical doc.**
  Rung 2 now names DRY and the probe in `agents/implementer.md`, `agents/code-reviewer.md`,
  `agents/planner.md` (which records the existing file in `readFirst` rather than running a
  probe it has no Bash for), `skills/shared/team-prompts/implementer.md`, both
  `skills/shared/execute-subagent.md` prompts, `lib/plan-to-loop.sh`,
  `lib/workflows/execute-dag.js`, and `hooks/team/simplicity-inject.sh` — each resolving the
  probe path by its own mechanism, since a dispatched agent's cwd is the target repository
  and a bare `lib/...` path resolves to nothing there.
  `tests/ponytail-coverage.test.sh` enforces the wiring, mirroring the code-for-humans suite.

### Changed

- **The ladder, design-for-change, and code-for-humans are documented as one set of three.**
  `CLAUDE.md` gained the ponytail bullet it was missing while carrying the other two, and
  `docs/loop-spec/architecture.md` states the position: six of the seven rungs are decidable
  from the task alone, and the one that is not gets a probe rather than a firmer instruction.
- **Duplication stays a judgment where it should be.** The probe locates candidates; it never
  orders a merge. Two blocks that resemble each other but change for different reasons are
  not duplication, and every dispatch copy carries that carve-out so `dry:` cannot become an
  instruction to couple unrelated code. The probe reads code only (prose and data repeat by
  nature) and skips generated files and marked generated regions. Its `similar=` tier
  deliberately replaces identifiers and literals, then uses the wider-window and
  uniform-block fences above to preserve the signal.

## [3.2.0] - 2026-08-12

### Changed

- **Cycle startup no longer runs the repository-wide test/lint/typecheck baseline.** A
  fresh checkout paid for a full suite on the untouched base before a single line of the
  feature existed, and the cycle runs that suite again at the integrated-wave boundary and
  in VERIFY Step 1.75 anyway. Startup now only prepares the environment;
  `verificationBaseline` stays `null` and the end-of-cycle comparison blocks on every
  repository-wide failure it observes.
- **The exact-base capture survives as an opt-in.** `LOOP_SPEC_STARTUP_BASELINE=1`
  restores the old startup capture for repositories whose base commit is already red,
  where the known-failure oracle is what stops EXECUTE and VERIFY from chasing failures
  the feature did not cause. Single-repo and workspace mode share the gate; greenfield
  never captures a baseline either way.

## [3.1.0] - 2026-08-11

### Changed

- **Every role now inherits the active session model by default.** Agent frontmatter,
  feature initialization, phase routing, standalone skills, and legacy task tiers no
  longer require a particular provider family or premium tier. Claude role agents may
  still receive an explicit alias, fresh phase launchers may receive a full model ID,
  OpenCode keeps native `provider/model` routes, and pi/unrouted OpenCode agents inherit
  their session model.
- **Graph effort is model-independent.** `system1` and `system2` change work guidance,
  not model selection, and the graph step descriptor no longer carries a model field.
  The same declared topology can therefore run unchanged in Claude Code, pi, and
  OpenCode.
- **The GDD implementation is easier to inspect.** Large embedded Python programs moved
  from `run.sh` and `validate.sh` into named `engine.py` and `validate.py` modules, while
  the shell files remain small launchers. Shipped graph nodes now carry human-facing
  labels shown by dry runs and step descriptors.

### Fixed

- Loop-fleet workers and completion judges omit `--model` for the portable `inherit`
  selector, preventing pi or OpenCode from receiving a Claude-specific value. The
  completion judge no longer defaults to a fixed Claude model ID.
- Claude Agent calls now omit the `model` key for inheritance, because that tool
  accepts only its four aliases and rejects the literal `inherit`. Startup performs
  zero Agent probes for an inherit-only configuration, dynamic call templates are
  linted, and unsupported role pins fail before dispatch.
- Graph trace emission now handles an omitted phase on Bash with nounset enabled, and
  the graph mutation tests no longer rely on platform-specific `sed -i` behavior.

## Earlier releases

Releases before 4.0.0 (0.1.0 through 3.0.1, May to August 2026) are recorded in git
history: `git log --oneline v3.0.1` and the tagged releases on GitHub. The 4.x line
starts at 4.0.0 above.
