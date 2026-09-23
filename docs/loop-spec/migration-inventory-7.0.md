# loop-spec 6.9 to 7.x migration inventory

Reference for two readers: the maintainer signing off M0, and whoever runs the M7
cutover and needs to know what may be deleted. Every surface the 6.9 tree ships has a
row. [ROADMAP-7.0.md](ROADMAP-7.0.md) section 17 makes deletion conditional on this
document: M7 cannot remove a surface whose row is missing or still `open`. No row is
`open`: the maintainer took every decision on 2026-09-22 and the answers are recorded at
the end.

Enumerated from the `v7` branch at `e831b77` (identical to `main` at 6.9.0 for these
paths) on 2026-09-22.

## How to read a row

| Disposition | Meaning |
|---|---|
| `kept` | The surface survives into 7.x with the same name and meaning. |
| `replaced` | A named 7.x surface carries the behavior. The old file, variable, or command goes away. |
| `removed` | The behavior goes away. Each removal cites the roadmap decision that covers it, or is listed under [Removals accepted](#removals-accepted-2026-09-22). |
| `open` | No decision covers it yet. No row carries this value after 2026-09-22; a future row that does blocks M7 until it is answered under [Decisions recorded](#decisions-recorded-2026-09-22). |

Roadmap citations are by section number: R§4 is the phase table, R§5 the
implementation contract, R§7 the defaults, R§8 role binding, R§10 convergence, R§11
baseline, R§12 state, R§13 workspace, R§14 entry points, R§15 output and result, R§16
packaging, R§17 cutover, R§20 decisions.

7.x names used in the tables: the *program* is the Python entry `loop-spec` with its
modules (state, repo, baseline, events, dag, integration, evidence, deliver, result);
a *default role* is `skills/loop-spec/roles/<role>/` per R§8; *config* is
`.loop-spec/config.json` per R§5 and R§12; the *state home* is R§12's data directory.

## Entry points

The 30 skills under `skills/*/SKILL.md`, plus `commands/loop-debug.md`. R§14 fixes the
7.x entries: `cycle`, the six phase names, `debug`, `micro`, `status`.

| 6.9 skill | Disposition | 7.x home |
|---|---|---|
| `cycle` | replaced | `cycle` entry; SPEC through DELIVER, program-run (R§14) |
| `spec` | replaced | `spec` entry; SPEC default in the lead (R§7) |
| `spec-lite` | removed | oneshot route dropped (R§20 scope decision); `micro` is the small-change preset |
| `plan` | replaced | `plan` entry; PLAN default in the lead (R§7) |
| `execute` | replaced | `execute` entry; EXECUTE default, program-run (R§7) |
| `oneshot` | removed | oneshot route dropped (R§20); `micro` preset |
| `verify` | replaced | `verify` entry; VERIFY default (R§7) |
| `iterate` | replaced | `iterate` entry; ITERATE default (R§7) |
| `deliver` | replaced | `deliver` entry; DELIVER program code (R§7) |
| `debug` | replaced | `debug` entry (R§4 debug row, R§7) |
| `micro` | replaced | `micro` preset; cannot drop a required phase (R§14). The `on`/`off`/`status` modes and the ad-hoc ledger go |
| `status` | replaced | `status` entry, read-only over state and outstanding decisions (R§14) |
| `intake` | replaced | `cycle` takes request text or a spec file directly (R§4 SPEC precondition) |
| `pause` | replaced | every run is resumable from state; a pending question is `status: paused` (R§15). `HANDOFF.json` and `.continue-here.md` go |
| `auto` | removed | accepted 2026-09-22; the caller names the entry, and the route judge is gone with oneshot |
| `revise` | replaced | `revise` entry: PR comments become remediation gaps, EXECUTE onward on the adopted PR branch, DELIVER updates the PR by identity (R§7, R§14) |
| `rollback` | removed | accepted 2026-09-22; state is off-branch (R§12) and the program never resets a branch (R§7). Git history is the user's |
| `assess` | removed | accepted 2026-09-22; outside the seven-phase scope (R§20) |
| `forensics` | removed | accepted 2026-09-22; `status` plus `events.jsonl` in the state home cover the read side |
| `walkthrough` | removed | accepted 2026-09-22; the PR body carries the rendered summary (R§12) |
| `quality-loop` | removed | accepted 2026-09-22; review is a role inside EXECUTE and VERIFY |
| `checking-gates` | removed | accepted 2026-09-22; user-gate tasks depend on the host task list, which 7.x does not use |
| `specifying-gates` | removed | accepted 2026-09-22; same reason |
| `onboard` | replaced | config; `grill.conf`, `discipline.conf`, `workflow.json`, `RULES.md` seed go |
| `settings` | replaced | config; per-mode `.loop-spec/<mode>.conf` files go |
| `rules` | removed | accepted 2026-09-22; self-learning `RULES.md` loop |
| `retro` | removed | accepted 2026-09-22; outside scope |
| `sentinel` | removed | accepted 2026-09-22; outside scope |
| `watch` | removed | accepted 2026-09-22; outside scope |
| `loop-runner` | removed | accepted 2026-09-22; the bundled loop runner and its offline suite |
| `commands/loop-debug.md` | replaced | `debug` entry |

## Agents

`agents/*.md`, 12 charters and a README. R§8: six become default roles; a role is a
prompt plus an output schema, and the port drops script references and report formats.

| 6.9 agent | Disposition | 7.x home |
|---|---|---|
| `spec-writer` | replaced | `roles/spec-writer/` |
| `planner` | replaced | `roles/planner/` |
| `implementer` | replaced | `roles/implementer/` |
| `code-reviewer` | replaced | `roles/code-reviewer/` |
| `verifier` | replaced | `roles/verifier/` |
| `iterate-judge` | replaced | `roles/iterate-judge/` |
| `security-reviewer` | replaced | folded into the `code-reviewer` role body; the review contract names security as a required dimension |
| `spec-compliance-reviewer` | replaced | folded into the `code-reviewer` role; the review record per task is checked against the task (R§4 EXECUTE) |
| `pattern-mapper` | replaced | folded into the `planner` role method; PATTERNS.md is no longer a product |
| `challenger` | replaced | light critic pass on the PLAN product, Critical misses only (R§7); route matrix P7 |
| `advocate` | removed | already not dispatched in 6.9; kept only for a stable role id the 7.x state does not need |
| `route-judge` | removed | oneshot route dropped (R§20) |
| `agents/README.md` | replaced | `skills/loop-spec/roles/README.md` |

## Shared contracts

`skills/shared/*`. R§8 folds the contracts the charters cite into the default role
bodies. R§16: nothing per harness travels.

| 6.9 contract | Disposition | 7.x home |
|---|---|---|
| `claude-harness.md` | replaced | host probes (R§19) and the runner decision; one host family |
| `opencode-harness.md` | removed | harness trees dropped (R§20) |
| `adk-harness.md` | removed | R§20 |
| `codex-harness.md` | removed | R§20 |
| `report-style.md` | kept | R§15 names it as the phase-line contract |
| `engineering-stances.md` | replaced | folded into role bodies (R§8) |
| `engineering-directives.md` | replaced | folded into role bodies |
| `execution-discipline.md` | replaced | folded into `implementer` |
| `implementer-contract.md` | replaced | `implementer` role plus the program's implement-step contract section |
| `grounding-protocol.md` | replaced | postconditions replace the lint; evidence records carry command, SHA, exit, identities (R§4 VERIFY) |
| `verification-grounding.md` | replaced | same |
| `writing-good-tests.md` | replaced | folded into `implementer` and `verifier` |
| `review-prompts/*` (4) | replaced | `code-reviewer` role body and the review contract section |
| `team-prompts/*` (5) | removed | teams rung dropped; role bodies replace the prompts |
| `artifact-templates/*` (6) | replaced | renderers from product JSON (R§3) |
| `feature-state-schema.md` | replaced | `state.json` schema, program-owned (R§5, R§12) |
| `graph-contract.md` | removed | graph driver dropped (R§17) |
| `handoff-port.md` | removed | with the graph |
| `route-exit-contract.md` | replaced | route matrix page (`phase-interface-7.0.md`, M0) |
| `review-routing.md` | replaced | R§10 ledger, delta, and severity rules |
| `critique-gate-protocol.md` | replaced | the critic pass in R§7; one pass, Critical only, no restyling |
| `dispatch.md` | replaced | `step.json` and program-composed prompts (R§5, R§8) |
| `execute-rungs.md` | removed | one step seam, two runners (R§9) |
| `execute-subagent.md` | replaced | native runner (R§9) |
| `execute-loop-fleet.md` | removed | with `loop-runner` |
| `tier-matrix.md` | removed | only `LOOP_SPEC_MODEL_<ROLE>` overrides the host model (R§3) |
| `model-matrix.md` | removed | same |
| `dual-process.md` | removed | accepted 2026-09-22; effort routing |
| `compact-profile.md` | replaced | `micro` preset |
| `autonomous-mode.md` | replaced | SDK runner and the supervisor's question policy (R§7, R§9) |
| `approach-selection.md` | replaced | folded into `planner` |
| `prompt-normalize.md` | removed | accepted 2026-09-22; request text is taken as given |
| `pr-feedback-check.md` | replaced | `revise` entry comment mapping |
| `no-deferral.md` | replaced | ledger `deferred` disposition and result `outstanding` (R§10, R§15); the 6.9 ban becomes a recorded disposition |
| `plain-language.md` | replaced | folded into `spec-writer` |
| `laziness-ladder.md`, `human-code.md`, `human-docs.md`, `design-for-change.md` | replaced | folded into the `implementer` and `code-reviewer` role bodies; the probes they cite become program inputs (see the probe rows) |

## Library scripts

`lib/*.sh` (153, of which 2 are test files), `lib/*.py` (19), `lib/graph/`,
`lib/supervisor/`, `lib/workflows/`.
R§17 deletes every `lib/*.sh` and the graph driver; the rows say where each behavior
lands.

### `lib/*.sh`

| 6.9 script | Disposition | 7.x home |
|---|---|---|
| `acceptance-lint.sh` | replaced | SPEC product schema validation |
| `active-cycle.sh` | replaced | state module: run lookup by repository identity and slug |
| `adhoc-ledger.sh` | removed | with `micro` modes; `events.jsonl` is the ledger |
| `adk-install.sh` | removed | R§20 |
| `adopt-pr.sh` | replaced | repo module input at SPEC entry; adopted branch and PR identity recorded in state (R§7) |
| `artifact-lint.sh` | removed | artifacts are rendered, never authored (R§3) |
| `artifact-sink.sh` | replaced | state home holds rendered artifacts; `commitArtifacts` config (R§12) |
| `autonomous-chain.sh` | replaced | `run` is resumable from state; the harness continues it (R§7) |
| `backlog.sh` | replaced | ledger `deferred` disposition; `BACKLOG.md` goes |
| `bounded-run.sh` | replaced | program command runner (baseline and evidence re-run) |
| `bump-version.sh` | kept | release tooling, retargeted at the 7.x manifest set |
| `checkpoint-pr.sh` | replaced | DELIVER draft PR on `escalated` under operator policy (R§4 DELIVER, R§10) |
| `checkpoint.sh` | removed | checkpoint tags on the branch; rewinds are counted in state (R§10) |
| `codex-install.sh` | removed | R§20 |
| `comment-tells.sh` | replaced | program probe, diff mode per task before review; whole range at VERIFY (R§7) |
| `conflict-monitor.sh` | removed | graph deliberation |
| `context-load.sh` | removed | measured phase prose, which 7.x has none of |
| `converged-floor.sh` | replaced | ITERATE postconditions (R§4) |
| `credential-refresh.sh` | removed | accepted 2026-09-22; DELIVER checks credentials and attempts the host's own refresh before its first remote write, never a configured command (R§7); route matrix D7 |
| `criteria-coverage.sh` | replaced | PLAN postcondition: every criterion id covered (R§4) |
| `critique-step.sh` | replaced | the critic pass at PLAN (R§7) |
| `cycle-driver.sh` | replaced | program `cycle` entry |
| `cycle-launch.sh` | replaced | program `cycle` entry |
| `cycle-preflight.sh` | replaced | program entry preflight |
| `cycle-profile.sh` | replaced | `micro` preset |
| `cycle-reconcile.sh` | replaced | result publication on interruption; live checklist case at M1 (R§15) |
| `cycle-result.sh` | replaced | result module, schema 1 plus `result` (R§15) |
| `dag-width.sh` | replaced | dag module, waves of at most three (R§7) |
| `debug-init.sh` | replaced | debug default (R§4) |
| `decision-coverage.sh` | replaced | requirements revision includes decisions; PLAN binds to it (R§4) |
| `decisions.sh` | replaced | SPEC product `decisions`; policy answers recorded against question ids (R§5) |
| `deferral-lint.sh` | replaced | ledger `deferred` disposition (R§10) |
| `deferred-baseline.sh` | replaced | baseline module (R§11) |
| `deliver.sh` | replaced | DELIVER program code (R§7) |
| `delivery-reconcile.sh` | replaced | DELIVER reconciles by PR identity (R§4) |
| `delta-findings-lint.sh` | replaced | ledger delta rule and `supersedes` schema requirement (R§10) |
| `design-budget.sh` | removed | design-phase budget; SPEC and PLAN run in the lead |
| `detect-test-cmd.sh` | replaced | baseline detects repo checks from manifests (R§11) |
| `dispatch-files.sh` | replaced | `step.json` (R§5) |
| `doc-deps.sh` | replaced | program probe at PLAN: dependencies the named files import (R§7) |
| `doc-tells.sh` | replaced | program probe, diff mode on touched markdown per task before review; whole range at VERIFY (R§7) |
| `docs-probe.sh` | replaced | program probe at PLAN: fetched documentation excerpts for those dependencies, handed to planner and implementer (R§7) |
| `duplication-scan.sh` | replaced | program probe: existing helpers near the named files at PLAN; diff mode per task before review; whole range at VERIFY (R§7) |
| `effort-probe.sh` | removed | accepted 2026-09-22; effort routing |
| `events.sh` | replaced | events module and `loop-spec emit`; console precedence kept (R§15) |
| `evidence.sh` | replaced | evidence records in the VERIFY product and the program re-run (R§4) |
| `execute-exit-gate.sh` | replaced | EXECUTE postconditions (R§4) |
| `execute-prepare.sh` | replaced | EXECUTE default (R§7) |
| `execute-rung.sh` | removed | one step seam, two runners (R§9) |
| `execute-step.sh` | replaced | EXECUTE default: implement step, review step, integrate (R§7) |
| `execute-stop.sh` | replaced | out-of-band change pauses for reconciliation (R§7) |
| `exit-gate-prelude.sh` | replaced | boundary check in the program (R§2) |
| `extension-points.sh` | replaced | config `phases`, `roles`, `prepare` |
| `failure-tells.sh` | replaced | program probe, diff mode per task before review; whole range at VERIFY (R§7) |
| `feature-bootstrap.sh` | replaced | state and repo modules |
| `feature-init.sh` | replaced | state module |
| `feature-read.sh` | replaced | state module |
| `feature-scan-each.sh` | replaced | repo module, per-repo in workspace mode (R§13) |
| `feature-validation.sh` | replaced | baseline module |
| `feature-write.sh` | replaced | state module, single writer with digest (R§5) |
| `finalize-delivery-candidate.sh` | replaced | DELIVER binds the verified SHA (R§4) |
| `fix-loop.sh` | replaced | per-step retry limit (R§7) |
| `footprint.sh` | removed | oneshot scout (R§20) |
| `fragility-scan.sh` | removed | with `assess` |
| `git-ops.sh` | replaced | repo module |
| `greenfield-bootstrap.sh` | replaced | repo module init-in-place with the nesting and workspace refusals (R§12); the backfill check is covered by `featureAdded` baselines (R§11) |
| `grounding-lint.sh` | replaced | postconditions (R§4) |
| `gsd-ingest.sh` | removed | accepted 2026-09-22; get-shit-done import |
| `harness.sh` | replaced | host probes (R§19); Claude Code and SDK only |
| `house-style.sh` | replaced | program probe: `probe` at PLAN on the named files; `compare` per task before review; whole range at VERIFY (R§7) |
| `implicit-team-model.sh` | removed | teams rung |
| `indirection-scan.sh` | replaced | program probe: layer count at base at PLAN; diff against it per task before review; whole range at VERIFY (R§7) |
| `integrate-task.sh` | replaced | integration module: fast-forward after checks (R§7) |
| `issue-intake.sh` | removed | accepted 2026-09-22; consumers wire issues to the SDK runner themselves |
| `iterate-judged.sh` | replaced | ITERATE default (R§7) |
| `model-tier.sh` | removed | only `LOOP_SPEC_MODEL_<ROLE>` (R§3) |
| `oneshot-exit-gate.sh` | removed | R§20 |
| `oneshot-spec-lint.sh` | removed | R§20 |
| `opencode-install.sh` | removed | R§20 |
| `output-digest.sh` | replaced | evidence record: parsed identities plus raw digest; logs in the state home (R§11) |
| `owned-gitignore.sh` | removed | the pointer moves to the state home (R§12); nothing is written to the consumer repo |
| `parse-invocation.sh` | replaced | program CLI argument parsing |
| `pause-snapshot.sh` | replaced | state is always resumable; `status` (R§14) |
| `phase-entry.sh` | replaced | `context.json` (R§5) |
| `phase-exit.sh` | replaced | boundary check; program writes transitions (R§5) |
| `phase-mode.sh` | removed | phase modes (R§14) |
| `phase-placeholders.sh` | replaced | `context.json` |
| `placeholder-scan.sh` | replaced | folded into the `code-reviewer` role method |
| `plain-language-lint.sh` | replaced | folded into `spec-writer` |
| `plan-adherence.sh` | replaced | PLAN product schema |
| `plan-conflicts.sh` | replaced | dag module |
| `plan-exit-gate.sh` | replaced | PLAN postconditions (R§4) |
| `plan-render.sh` | replaced | renderer from the PLAN product |
| `plan-structure.sh` | replaced | PLAN schema and postconditions |
| `plan-tasks.sh` | replaced | PLAN product `tasks` |
| `plan-to-loop.sh` | removed | with `loop-runner` |
| `plugin-version.sh` | replaced | result `loopSpecVersion` read from the manifest |
| `pr-body.sh` | replaced | DELIVER renders the PR body from products (R§12) |
| `pr-comments.sh` | replaced | `revise` entry: comment fetch in the program |
| `pr-delivery.sh` | replaced | DELIVER (R§4): exact SHA, required checks, identity reconciliation |
| `pr-feedback.sh` | replaced | `revise` entry: comment-to-gap mapping |
| `prejudge-lint.sh` | replaced | the program composes prompts; a test on the composer pins that the contract section cannot coach |
| `prepare-environment.sh` | replaced | config `prepare` before baseline (R§11) |
| `profile.sh` | removed | run profiles; `micro` preset |
| `project-commands.sh` | replaced | baseline detection plus config `prepare` |
| `python-path.sh` | replaced | program runtime check at entry |
| `quality-loop-state.sh` | removed | with `quality-loop` |
| `ralph-remediation.sh` | replaced | rewind budget and per-step retry limit (R§10) |
| `regression-scan.sh` | removed | accepted 2026-09-22; it reads committed VERIFICATION.md, which 7.x does not commit |
| `resolve-bin.sh` | replaced | program runtime check |
| `resource-bounds.sh` | replaced | dag module wave cap (R§7) |
| `retro.sh` | removed | with `retro` |
| `review-trail.sh` | replaced | ledger and the review contract inputs (R§10) |
| `review-triage-lint.sh` | replaced | review record schema: location and disposition required |
| `revise-branch.sh` | replaced | repo module PR adoption (`adopt-pr.sh` row) |
| `revise-state.sh` | replaced | state module: `revise` enters against the delivered run's state |
| `route-judgment.sh` | removed | R§20 |
| `rules.sh` | removed | with `rules` |
| `run-digest.sh` | removed | with `retro` and `watch` |
| `run-with-watchdog.sh` | replaced | program command runner timeouts |
| `runtime-ignore.sh` | removed | with `owned-gitignore.sh` |
| `runtime-preflight.sh` | replaced | program runtime check |
| `security-signal.sh` | replaced | program probe at PLAN on the planned file set; a required review input with a disposition per signal (R§7); route matrix E11 |
| `sentinel-run.sh`, `sentinel-sources.sh`, `sentinel-triage.sh` | removed | with `sentinel` |
| `state-ref.sh` | replaced | `loop-spec state push|pull` seam, built when a harness needs it (R§12) |
| `status.sh` | replaced | `status` entry |
| `surface.sh` | removed | accepted 2026-09-22; the 7.x tree is small enough to read |
| `task-batch.sh` | replaced | dag module |
| `task-progress.sh` | replaced | per-task disposition in state (R§4 EXECUTE) |
| `task-route.sh` | removed | R§20 |
| `team-ops.sh` | removed | teams rung |
| `teams-capability.sh` | removed | teams rung |
| `test-tamper-scan.sh` | replaced | self-inflicted regression route (R§10) and the review contract |
| `trust.sh` | removed | accepted 2026-09-22; outside scope |
| `tuning.sh` | removed | accepted 2026-09-22; outside scope |
| `validate-task-metadata.sh` | removed | host task list not used |
| `verification-baseline.sh` | replaced | baseline module (R§11) |
| `verification-gap-scan.sh` | replaced | folded into the `verifier` role method |
| `verification-grounding-lint.sh` | replaced | VERIFY postconditions and the program re-run (R§4) |
| `verify-gate.sh` | replaced | VERIFY postconditions |
| `verify-live.sh` | removed | accepted 2026-09-22; the live-run rung |
| `verify-passes.sh` | replaced | VERIFY default (R§7) |
| `verify-prepare.sh` | replaced | VERIFY default |
| `watch.sh` | removed | with `watch` |
| `workflow-availability.sh` | removed | Workflow rung (R§9) |
| `workflow-config.sh` | removed | Workflow rung |
| `workspace.sh` | replaced | repo module workspace resolution (R§13) |
| `worktree-base.sh` | replaced | program-owned worktrees in the state home (R§7, R§12) |
| `worktree-commit-check.sh` | replaced | integration module: commit on the task branch (R§7) |
| `pause-snapshot.test.sh`, `ralph-remediation.test.sh` | removed | with the 6.9 tests (R§17) |

### `lib/*.py`

| 6.9 module | Disposition | 7.x home |
|---|---|---|
| `critique_prompt.py` | replaced | the critic role's program-composed prompt (R§8) |
| `design_budget.py` | removed | with `design-budget.sh` |
| `diff-added-lines.py` | replaced | reviewed ranges in the ledger (R§10) |
| `doc-deps.py`, `docs-probe.py` | replaced | program probes at PLAN (see the `.sh` rows) |
| `doc-tells.py`, `failure-tells.py` | replaced | program probes (see the `.sh` rows) |
| `execute_remediation.py` | replaced | remediation entry mode (R§4 envelope) |
| `feature_read.py`, `feature_write.py` | replaced | state module |
| `phase_snapshot.py` | replaced | `context.json` |
| `repair_verify.py` | replaced | remediation tasks in the VERIFY product; regression route (R§10) |
| `review_routes.py` | replaced | R§10 routes and the route matrix |
| `session_identity.py` | replaced | run and attempt ids; submitted host id for attestation (R§5) |
| `spec_intent.py` | replaced | requirements revision digest and the intent guard (R§4, M2) |
| `spec_questions.py` | replaced | `question.json` with one-time ids (R§5) |
| `surface.py` | removed | with `surface.sh` |
| `verify_command.py` | replaced | evidence re-run in a clean checkout (R§4) |
| `verify_dispatch.py` | replaced | program-composed verifier prompt (R§8) |

### `lib/graph/`, `lib/supervisor/`, `lib/workflows/`

| 6.9 path | Disposition | 7.x home |
|---|---|---|
| `graph/driver.py`, `engine.py`, `paths.py`, `state_reads.py`, `validate.py` | removed | graph driver (R§17) |
| `graph/*.sh` (10) | removed | with the graph; `gate.sh` and `checkpoint.sh` behaviors land in the program's transition and ledger records |
| `graph/probes/*.sh` (13) | replaced | the route matrix page; each probe's decision becomes a named exit or precondition (R§4) |
| `graph/cycle.graph.json`, `critique.graph.json`, `schema.json` (top-level `graph/`) | removed | with the graph |
| `supervisor/oracle.sh` | replaced | SDK supervisor `can_use_tool` policy (R§7) |
| `supervisor/store.sh`, `store-local.sh`, `store-mirror.sh` | replaced | state home (R§12); the store port goes |
| `workflows/*.js`, `workflows/templates/*` | removed | Workflow rung (R§9) |

## Hooks

`hooks/` holds 45 hook scripts, `hooks.json`, `codex-hooks.json`, `pre-tool-guard.py`,
and 27 test files. R§16: 7.x ships no hook and depends on none for correctness
(decided 2026-09-22). The whole directory is deleted in M1's first commit, not at M7,
so no 6.9 hook fires during a 7.x live run (R§18).

| 6.9 hook | Event | Disposition | 7.x home |
|---|---|---|---|
| `team/skill-paths-inject.sh` | SessionStart | removed | skills reach the program by relative path (R§16) |
| `team/discipline-inject.sh` | SessionStart | removed | folded into role bodies |
| `team/grill-inject.sh` | SessionStart | removed | `spec-writer` interview method |
| `team/simplicity-inject.sh` | SessionStart | removed | folded into role bodies |
| `team/human-code-inject.sh` | SessionStart | removed | folded into role bodies |
| `team/rules-inject.sh` | SessionStart | removed | with `rules` |
| `team/micro-inject.sh` | SessionStart | removed | `micro` preset |
| `team/placeholder-question-guard.sh` | PreToolUse AskUserQuestion | removed | questions are `question.json` with ids (R§5) |
| `team/phase-handoff-guard.sh` | PreToolUse | replaced | the program is the only writer of transitions (R§3) |
| `team/no-worktrees-guard.sh` | PreToolUse | removed | the program owns worktrees (R§7) |
| `team/result-forgery-guard.sh` | PreToolUse | replaced | program single writer; retired-attempt rejection; evidence levels (R§5) |
| `team/dispatch-prompt-guard.sh` | PreToolUse Agent | replaced | the program composes every prompt (R§8) |
| `team/session-env-inject.sh` | PreToolUse Bash | replaced | the lead submits the host dispatch id with `submit` (R§5) |
| `team/nested-session-guard.sh` | PreToolUse Bash | removed | the SDK runner spawns on purpose; the native lead uses the Agent tool |
| `restrict-agent-paths.sh`, `pre-tool-guard.py` | PreToolUse Write/Edit | removed | trust model detects rather than prevents (R§6) |
| `team/task-created.sh` | PreToolUse TaskCreate | removed | host task list not used |
| `team/pre-task-blockedby-enforce.sh` | PreToolUse TaskUpdate | replaced | dag module: dependencies complete before dependents (R§4) |
| `team/strategy-rotation.sh` | PostToolUse | replaced | rejected step re-issued with the reason, up to the retry limit (R§7) |
| `team/artifact-lint-feedback.sh` | PostToolUse | removed | no authored artifacts (R§3) |
| `team/oracle-record.sh` | PostToolUse AskUserQuestion | replaced | answers recorded against question ids (R§5) |
| `team/invocation-stamp.sh` | UserPromptSubmit | removed | program CLI parsing |
| `team/done-criteria.sh` | UserPromptSubmit | removed | accepted 2026-09-22 |
| `team/task-completed.sh` | TaskCompleted | removed | host task list not used |
| `team/post-task-complete-revalidate.sh` | TaskCompleted | removed | with `checking-gates` |
| `team/teammate-idle.sh` | TeammateIdle | removed | teams rung |
| `team/stop-revalidate-user-gates.sh` | Stop | removed | with `checking-gates` |
| `team/adhoc-verify-guard.sh` | Stop | replaced | `micro` runs VERIFY as a required phase (R§14) |
| `team/deferral-guard.sh` | Stop | replaced | ledger `deferred` disposition (R§10) |
| `team/route-terminal-guard.sh` | Stop | replaced | the program always writes a terminal result (R§15) |
| `team/cycle-stamp-guard.sh` | Stop | replaced | program transitions |
| `team/session-end-learnings.sh` | Stop | removed | accepted 2026-09-22; learnings JSONL |
| `codex-session-start.sh`, `codex-shell-env.sh`, `codex-user-prompt.sh`, `codex-hooks.json` | Codex | removed | R§20 |
| `install-bundled-workflows.sh` | manual | removed | Workflow rung |
| `pre-cycle-permission-check.sh` | manual | removed | Workflow rung |
| `team/inject-test-lib.sh`, `*.test.sh` (27) | tests | removed | with the hooks; 7.x unit-tests deterministic Python only (R§17) |
| `hooks.json` | manifest | removed | no hook ships (R§16) |
| `.gitkeep` (2) | none | removed | |

## Environment variables

209 distinct `LOOP_SPEC_*` names read or written under `lib/`, `hooks/`, `skills/`,
`agents/`, `extensions/`, and `.claude-plugin/`. Grouped by fate; every name appears
once. Names ending in `_` are prefixes.

| 6.9 variables | Disposition | 7.x home |
|---|---|---|
| `MODEL_`, `MODEL_IMPLEMENTER` | kept | the one operator model override (R§3) |
| `HANDOFF`, `RESULT`, `PHASE_START`, `PHASE_END`, `PHASE_` (marker prefix) | kept | stdout markers (R§15) |
| `CONSOLE_STREAM`, `CONSOLE_EVENTS` | kept | console precedence (R§15) |
| `MODEL_ROUTE_JUDGE` | removed | R§20 |
| `PHASE_MODEL_`, `PHASE_ALT`, `EFFORT`, `EFFORT_PHASE`, `EFFORT_NODE` | removed | only the role override survives (R§3) |
| `ROUTE`, `CYCLE_PROFILE`, `EXECUTION_PROFILE`, `PROFILE`, `PROFILE_PRESET`, `GRAPH`, `DESIGN_BUDGET_MINS`, `CRITIQUE_ROUNDS`, `TASK_BATCH_AUTO`, `TASK_BATCH_CHAIN_FILES`, `PLAN_MIN_WIDTH`, `PLAN_MULTI_ANGLE` | removed | phase modes, graph, profiles (R§14, R§17) |
| `HARNESS`, `SESSION_LAYER`, `SESSION_PROFILES`, `SESSION`, `SESSION_TIMEOUT_SECS`, `ADK_AGENT_DIR`, `ADK_MODEL`, `LOOP_RUNTIME`, `TEAMS_MODE`, `EXECUTE_WORKFLOW`, `WORKFLOWS_AVAILABLE`, `WORKFLOW_CONFIG`, `EXECUTE_LOOPS`, `LOOP_MAX_ITERATIONS`, `LOOP_MAX_BUDGET_USD`, `MAX_PARALLEL_`, `MAX_PARALLEL_SUBAGENTS`, `MAX_PARALLEL_IMPLEMENTERS` | removed | harness trees, teams, Workflow, loop-runner (R§9, R§20); the wave cap is fixed at three (R§7) |
| `SKILL_DIR`, `PROJECT_DIR`, `DIR`, `PWD`, `FEATURE_DIR`, `ARTIFACT_DIR`, `RESULT_ROOT`, `EVENTS`, `EVENT_SINK`, `STORE`, `STORE_DIR`, `PORT`, `PORT_ROOT`, `FOOTPRINT_ROOT`, `WORKTREES`, `WORKTREE_DIR` | replaced | state home (R§12); skills reach the program by relative path (R§16) |
| `LAST_RESULT_FILE` | removed | the pointer has one location, the state home (R§12) |
| `STATE_REPORT`, `STATE_FLAGS`, `STATE_FINGERPRINT`, `STATE_CURSOR`, `BASE_CURSOR`, `FEATURE_WRITE`, `GATE_WRITE`, `IDENTITY_INPUT`, `SESSION_ID`, `SAME_SESSION`, `INTEGRATION_CANDIDATE`, `INVOCATION_STAMP`, `STAMP_INPUT`, `STAMP_MAX_AGE_MIN`, `HOOK_INPUT`, `GUARD_INPUT`, `FOREIGN_CLAIMANTS`, `COMMIT_TELEMETRY`, `SHARE_DEPENDENCIES`, `VERSION` | replaced | internal program state and ids (R§5); not environment |
| `CYCLE_RESULT_BIN`, `ACTIVE_CYCLE_BIN`, `PR_DELIVERY_BIN`, `PR_COMMENTS_BIN`, `FINALIZE_CANDIDATE_BIN`, `DEFERRAL_LINT_BIN`, `PR_DELIVERY_CWD`, `BOUNDED_RUN_CWD`, `BOUNDED_RUN_STDIN` | removed | test seams for shell scripts; 7.x has no cycle-level suite to seam (R§17) |
| `NON_INTERACTIVE`, `AUTONOMOUS`, `PAUSE` | replaced | answer scope `question` or `run` and `--answer-policy default` at entry (R§5). `NON_INTERACTIVE` needs no successor: exit 3 hands the question to whoever runs the program. `AUTONOMOUS` is a `run`-scoped answer. `PAUSE` is a pending question, `status: paused` |
| `ORACLE`, `ORACLE_WRITE`, `ORACLE_RECORD`, `ANSWER_`, `ANSWER_TITLE`, `ANSWER_REPOS`, `ANSWER_STYLE`, `ANSWER_SPEC_CONFIRM`, `ANSWER_ITERATE_SPEC` | replaced | supervisor question policy answering `question.json` by id (R§5, R§7) |
| `CMD_`, `CMD_TEST`, `CMD_LINT`, `CMD_TYPECHECK`, `CMD_PREPARE`, `PROJ_VERIFY_CMD`, `STARTUP_BASELINE`, `EXTENSIONS` | replaced | config `prepare` and baseline detection (R§11) |
| `BASELINE_TIMEOUT_SECS`, `BASELINE_IDLE_TIMEOUT_SECS`, `PREPARE_TIMEOUT_SECS`, `PREPARE_IDLE_TIMEOUT_SECS`, `COMMAND_TIMEOUT_SECS`, `COMMAND_IDLE_TIMEOUT_SECS`, `PHASE_TIMEOUT_MINS`, `DISPATCH_WAIT_MINS`, `REGRESSION_CMD_TIMEOUT_SECONDS`, `LIVE_PROBE_TIMEOUT_SECONDS`, `LIVE_READY_PROBE_TIMEOUT_SECONDS`, `DIGEST_MAX_LINES` | replaced | command runner timeouts in config; the worker grace period is operator-set (R§5). Names fixed at M1 |
| `ITERATE_MAX_ITERATIONS` | replaced | rewind budget override (R§10) |
| `REDO_MAX`, `RALPH_THRESHOLD`, `STRATEGY_ROTATION`, `STRATEGY_ROTATION_THRESHOLD` | replaced | per-step retry limit (R§7) |
| `ARTIFACTS_IN_PR` | replaced | config `commitArtifacts` (R§12) |
| `CHECKPOINT_PR`, `CHECKPOINT_EACH_PHASE` | replaced | draft delivery under operator policy (R§4); per-phase checkpoints go |
| `CHECKS_TIMEOUT_SECONDS`, `CHECKS_INTERVAL_SECONDS`, `CHECKS_REGISTRATION_GRACE_SECONDS`, `GH_COMMAND_TIMEOUT_SECONDS` | replaced | DELIVER readiness policy in config, carrying 6.9 behavior (R§4) |
| `PR_BODY_VERBOSE`, `DELIVERY_RECONCILE`, `REVIEW_GROUP_BYTES` | removed | DELIVER renders one body and always reconciles |
| `PR_FEEDBACK_MODE`, `PR_FEEDBACK_OWNER`, `REVIEW_BOT_ALLOWLIST` | replaced | `revise` entry settings in config |
| `ISSUE_INTAKE_CLAUDE_FLAGS`, `MAX_FEATURES`, `ROLLBACK_CONFIRMED` | removed | with `issue-intake.sh` and `rollback` |
| `CREDENTIAL_REFRESH_CMD`, `CREDENTIAL_REFRESH_TIMEOUT_SECONDS`, `CREDENTIAL_REFRESH_STAGE`, `CREDENTIAL_REFRESH_REPO`, `CREDENTIAL_REFRESH_REASON`, `CREDENTIAL_REFRESH_HOST`, `CREDENTIAL_PREPARED_STAGES`, `AUTH_ERROR_CODE`, `AUTH_ERROR_MESSAGE` | removed | with `credential-refresh.sh`; DELIVER's own check replaces them (R§7) |
| `TASK_GUARD`, `PATH_GUARD`, `PATH_GUARD_FORCE`, `ROUTE_GUARD`, `ROUTE_GUARD_MAX_AGE_MIN`, `ROUTE_GUARD_TRACE_LOG`, `MICRO_GUARD`, `MICRO_GUARD_MAX_DENIALS`, `MICRO_GUARD_TRACE_LOG`, `MICRO_GUARD_STATE_DIR`, `USERGATE_GUARD`, `USERGATE_STOP_GUARD`, `USERGATE_TRACE_LOG`, `FORGERY_GUARD`, `DEFERRAL_GUARD`, `DEFERRAL_LINT`, `DEFERRAL_TRACE_LOG`, `DEFERRAL_STATE_DIR`, `DISPATCH_PROMPT_GUARD`, `NESTED_SESSION_GUARD`, `PLACEHOLDER_QUESTION_GUARD`, `BLOCKEDBY_GUARD`, `BLOCKEDBY_TRACE_LOG`, `EGRESS_GUARD`, `DONE_CRITERIA`, `ARTIFACT_LINT_FEEDBACK` | removed | hook toggles; the hooks go and the program enforces the invariants (see Hooks) |
| `DISCIPLINE`, `GRILL`, `SIMPLICITY`, `HUMAN_CODE`, `MICRO`, `RULES`, `RULES_FILE`, `GLOBAL_RULES_FILE`, `LEARNINGS`, `LEARNINGS_FILE`, `RETRO_AUTO_APPLY`, `RETRO_DIGEST_DIR`, `TUNING`, `TUNING_AUTO_APPLY`, `ASSESS_TOP_N`, `ASSESS_SINCE`, `ADHOC_LEDGER`, `QL_STATE`, `QUALITY_LOOP_MAX_ROUNDS`, `REGRESSION_SCAN`, `BACKLOG_FILE`, `SPEC_FILE`, `GROUNDING_SPEC`, `VGAP_MAX_FILES` | removed | with the skills and hooks they configure |
| `DOC_DEPS`, `DOCS_FIXTURES`, `DOCS_CACHE_TTL_SECS`, `DOCS_CACHE_DIR` | replaced | dependency-docs probe settings in config; the fixtures variable goes |
| `INDIRECTION_MAX_BODY`, `DUP_MIN_LINES` | replaced | probe thresholds in config |

New in 7.x, for completeness: `LOOP_SPEC_HOME` (R§12), `LOOP_SPEC_PHASE_<NAME>` and
`LOOP_SPEC_ROLE_<ROLE>` (R§5), the `LOOP_SPEC_QUESTION` marker (R§15), and the
`--answer-policy` entry flag (R§5).

## Plugin surfaces, extensions, and packaging

| 6.9 surface | Disposition | 7.x home |
|---|---|---|
| `.claude-plugin/plugin.json` fields `name`, `version`, `author`, `homepage`, `repository`, `license`, `description`, `keywords`, `$schema` | kept | same manifest at 7.0.0 |
| `.claude-plugin/plugin.json` `outputStyles` | kept | R§15 keeps the output style |
| `.claude-plugin/marketplace.json` | kept | version lockstep with `plugin.json` |
| `.codex-plugin/plugin.json` | removed | R§20 |
| `output-styles/loop-spec.md` | kept | R§15 |
| `extensions/opencode/loop-spec.ts` | removed | R§20 |
| `extensions/adk/loop_spec_adk/*` | removed | R§20 |
| `extensions/sessions/session_run.py`, `cycle_run.py`, `profiles/*.toml`, `NOTICE`, `README.md` | removed | accepted 2026-09-22; the session layer served the dropped harnesses. The SDK runner is the unattended path (R§9) |
| `examples/supervisor/*` | replaced | the supervisor example that ships with 7.0 (R§19: the catch-all approval must not survive) |
| `examples/foreign-claimant/*` | removed | accepted 2026-09-22; demonstrates `LOOP_SPEC_FOREIGN_CLAIMANTS`, which goes |
| `llms.txt` | replaced | rewritten for the 7.x surface |
| `README.md`, `CLAUDE.md`, `CHANGELOG.md` | replaced | rewritten at M7 (R§17, R§18). The README must carry exemplar Claude Code use cases, an exemplar Agent SDK implementation, and the one-off Claude Code commands each entry supports (asked 2026-09-22) |
| [migrating-6-to-7.md](migrating-6-to-7.md) | new | how-to for consumers moving a 6.9 setup to 7.x; first version at M0, M1 names filled at M7 (R§18) |
| `evals/` | removed | empty apart from a cache directory |
| `inbox/` | removed | deleted on `v7` 2026-09-22 |

## Documentation

`docs/` outside the 7.0 planning set.

| 6.9 document | Disposition | 7.x home |
|---|---|---|
| `docs/loop-spec/agent-output-contract.md` | replaced | R§15, then the M1 live compatibility checklist |
| `docs/loop-spec/architecture.md` | replaced | rewritten from the roadmap at M7 |
| `docs/loop-spec/claude-invocation-contract.md` | replaced | host probes and the runner decision |
| `docs/loop-spec/cloud-run-autonomous.md` | replaced | SDK runner deployment doc |
| `docs/loop-spec/configuration.md` | replaced | config reference for `.loop-spec/config.json` |
| `docs/loop-spec/dag-efficiency-handoff.md` | removed | 6.9 working notes |
| `docs/loop-spec/gdd.md` | removed | greenfield keeps only init-in-place (R§12) |
| `docs/loop-spec/graph-remediation-contract.md` | removed | with the graph |
| `docs/loop-spec/PREREQUISITES.md` | replaced | host versions page (M0 item 3) |
| `docs/loop-spec/reliability.md` | replaced | rewritten against R§5 identities and R§6 trust model |
| `docs/loop-spec/sentinel.md` | removed | with `sentinel` |
| `docs/loop-spec/supervisor-interface.md` | replaced | supervisor example README |
| `docs/loop-spec/features/*` | removed | 6.9 feature directories in this repo; the 7.x state home is off-branch (R§12) |
| `docs/adopting.md`, `docs/tier-guide.md`, `docs/determinism-audit.md`, `docs/examples/` | replaced | rewritten or dropped at M7; tier guide goes with the tier matrix; the issue-to-PR action example goes with `issue-intake.sh` |
| `tests/` (62 top-level, 173 under `tests/lib/`) | removed | replaced by unit tests for 7.x's deterministic Python modules plus the live checklist `m1-fixtures-7.0.md` (R§17) |

## Decisions recorded 2026-09-22

The maintainer answered every open row in one sitting. The rows above carry the
outcome; this list is the record of the answer as given.

1. No hook ships. Section 16 of the roadmap is corrected.
2. `revise` stays, as an entry that enters EXECUTE in remediation mode from PR comments
   on the adopted PR branch.
3. The critique gate becomes a light critic pass on the PLAN product, looking for
   Critical misses only.
4. The six code probes are cycle behavior on the consumer's files, not maintainer
   tooling, and run as far left as each has input: at PLAN on the named files
   (`house-style probe`, `duplication-scan`, `indirection-scan` base count,
   `security-signal`), per task after the implementer commits and before the review
   step (`comment-tells`, `failure-tells`, `indirection-scan`, `duplication-scan`,
   `house-style compare`, `doc-tells`, all in diff mode), and once over the whole range
   at VERIFY. Findings are review inputs; no postcondition gates on them except the
   security disposition (E11). `surface` goes.
5. `doc-deps` and `docs-probe` both run as program inputs at PLAN, including the
   fetched documentation excerpts.
6. No configured credential refresh. DELIVER checks git and `gh` credentials and
   attempts the host's own refresh before its first remote write, because DELIVER may
   run hours or days after the earlier phases.
7. No unattended flag. An answer carries scope `question` or `run`; `--answer-policy
   default` sets the `run` scope at entry. This keeps the harness that federates
   questions to a chat channel and lets the person answer or proceed autonomously for
   the rest of the run.
8. The `last-result.json` pointer moves to the state home.
9. PR adoption stays, as a repo-module input at SPEC entry.
10. Greenfield keeps only init-in-place with its refusals.
11. Issue intake is removed.
12. A security signal is a required review input with a disposition per signal.
13. `inbox/` is deleted now on `v7`.

Every removal that this inventory proposed is accepted.

Two deliverables were added the same day: the 7.x README must carry exemplar Claude
Code use cases, an exemplar Agent SDK implementation, and the one-off Claude Code
commands each entry supports; and a consumer migration how-to,
`docs/loop-spec/migrating-6-to-7.md`, is merged at M7.

## Removals accepted 2026-09-22

Removals no earlier roadmap decision covered, accepted by the maintainer as a set.

- Entry points outside the seven-phase scope: `assess`, `sentinel`, `watch`, `retro`,
  `rules`, `trust.sh`, `tuning.sh`, `run-digest.sh`, `fragility-scan.sh`.
- Entry points the phase model absorbs: `auto`, `forensics`, `walkthrough`,
  `quality-loop`, `checking-gates`, `specifying-gates`, `rollback`, `loop-runner`.
- Prose and routing helpers with no 7.x counterpart: `dual-process.md`,
  `effort-probe.sh`, `prompt-normalize.md`, `gsd-ingest.sh`, `regression-scan.sh`,
  `verify-live.sh`, `done-criteria.sh`, `session-end-learnings.sh`.
- The session layer (`extensions/sessions/`) and `examples/foreign-claimant/`.

## Related

- [ROADMAP-7.0.md](ROADMAP-7.0.md): why each replacement exists.
- [runner-decision-7.0.md](runner-decision-7.0.md): the runner rows.
- [phase-interface-7.0.md](phase-interface-7.0.md): the route matrix that replaces the graph probes.
