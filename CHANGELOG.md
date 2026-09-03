# Changelog

All notable changes documented here. Format follows Keep a Changelog.

## [Unreleased]

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
