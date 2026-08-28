---
trust: generated
---

# ARCH

> **Generated snapshot, not a runtime contract.** This map describes the tree at its
> recorded generation date and may retain facts from an earlier release. For current
> harness and model behavior, use [the architecture guide](../gdd.md),
> [model matrix](../../../skills/shared/model-matrix.md), and
> [model policy](../../../skills/shared/model-policy.md); regenerate the map before
> using it to plan changes.

> Mapped by loop-spec-mapper-arch on 2026-08-06. Full refresh — the prior version
> (2026-05-11, incremental) was verified stale in multiple places (see note at
> bottom of this run's report) and is not carried forward without re-checking.

## Modules

loop-spec is a Claude Code plugin that also ships as a pi (pi.dev) package and an
opencode (opencode.ai) install from the same tree (`package.json:20-30`,
`extensions/pi/loop-spec.ts`, `extensions/opencode/loop-spec.ts`). There are no
compiled modules; the functional units are markdown skills/agents interpreted by
the harness, plus bash/jq/python3 libs they shell out to.

### `.claude-plugin/` — Plugin manifest
`plugin.json` declares identity/version (`.claude-plugin/plugin.json:1-22`, version
`2.35.0`) and `marketplace.json` is the marketplace descriptor. Version must stay
in lockstep with `package.json` (also `2.35.0`) — `bash lib/bump-version.sh` sets
both plus the README line; `tests/validate-pi-manifest.test.sh` enforces it.

### `skills/` — 34 directories, one shared, 33 invocable skills
Slash-command shims are gone (see Entrypoints); a skill's own `SKILL.md`
frontmatter (`name`, `description`, `argument-hint`, `allowed-tools`) is what
Claude Code registers as `/loop-spec:<name>`. Grouped by role (verified by
reading every `SKILL.md` frontmatter this run):

| Group | Skills |
|---|---|
| Cycle phases (forward chain, see Data Flow) | `spec`, `discuss`, `plan`, `execute`, `verify`, `iterate`, `deliver` |
| Cycle orchestrator + auto-routing | `cycle` (top-level entry), `auto` (routes to micro/debug/cycle), `intake` (any input → spec draft → cycle) |
| Autonomous work-source loop | `sentinel` (scan sources, run one item via intake+cycle under `lib/trust.sh`), `watch` (post-merge bounded watch, never reopens a cycle) |
| Ad-hoc / small-scope | `micro` (five invariants, zero ceremony, escalates to intake when it outgrows ad-hoc scale), `debug` (TRIAGE→REPRODUCE→FIX→SIBLING SWEEP→VERIFY) |
| User-gate machinery | `checking-gates`, `specifying-gates` (opt-in; inert unless a hook routes into them) |
| Session-mode toggles (SessionStart-injected) | `discipline`, `grill`, `human-code`, `simplicity` |
| Diagnostics / ops | `status`, `retro`, `forensics`, `pause`, `rollback`, `walkthrough`, `assess`, `quality-loop`, `revise`, `rules`, `onboard` |
| Codebase map | `map-codebase` (this doc's producer) |
| Base automation layer | `loop-runner` — the only skill with its own Python (`skills/loop-runner/scripts/{loop,planlib,compile_spec,supervisor}.py`) and test harness (`skills/loop-runner/tests/run_tests.sh`, fake claude/pi/opencode CLIs) |
| Shared, not invoked | `shared/` — policy docs read by other skills |

### `skills/shared/` — shared policy (no templates dir claim carried forward; verified list)
Confirmed present: `model-matrix.md` (role→model alias map, replaces the removed
preset axis — see Key Abstractions), `tier-matrix.md` (fixed single-tier gate
behavior), `feature-state-schema.md` (schema for `feature.json`), `model-policy.md`,
`harness-call-contracts.md`, `pi-harness.md` / `opencode-harness.md` (adaptation
contracts, per CLAUDE.md), `no-teams-fallback.md`, `implicit-team-mode.md`,
`execute-subagent.md` / `execute-loops.md` / `execute-loop-fleet.md` /
`execute-inline.md` (one doc per EXECUTE rung), `human-code.md`,
`design-for-change.md`, `grounding-protocol.md`, `report-style.md`, plus
`artifact-templates/`, `review-prompts/`, `team-prompts/`. `preset-matrix.md`
(cited by the prior ARCH.md) does not exist in this tree.

### `agents/` — 16 definition files
Each has `name`/`description`/`tools`/`model` frontmatter (all 16 verified this
run). Write-scoped agents: `spec-writer`, `planner`, `pattern-mapper` (all three
→ `docs/loop-spec/features/**`), `mapper-{tech,arch,quality,concerns,domain}`
(each → its own `docs/loop-spec/codebase/*.md`), `implementer` (worktree code +
commit), `verifier` (`VERIFICATION.md`). Read-only agents (no Write/Edit in
`tools:`): `advocate`, `challenger`, `code-reviewer`, `security-reviewer`,
`spec-compliance-reviewer`, `iterate-judge` (judges the integrated result against
the *original* goal, not the frozen SPEC — `agents/iterate-judge.md:3`).

### `hooks/` — event enforcement
`hooks/hooks.json` wires 8 event types to 20 scripts under `hooks/team/` plus
`hooks/restrict-agent-paths.sh` (Write|Edit) and `hooks/pre-cycle-permission-check.sh`
(unregistered here; a `/permissions` advisory). Verified registrations
(`hooks/hooks.json:1-172`):

| Event | Script(s) | Purpose (verified from file header) |
|---|---|---|
| SessionStart | `hooks/team/{discipline,grill,simplicity,human-code,rules,micro}-inject.sh` | Inject mode directives; grill/simplicity/human-code/micro default ON, discipline defaults OFF |
| PreToolUse: Skill | phase-handoff-guard.sh | Blocks a second distinct phase skill invoked directly in one main-agent turn (enforces cycle-mediated phase transitions) |
| PreToolUse: Agent\|Bash\|EnterWorktree | no-worktrees-guard.sh | Fail-closed backstop for `LOOP_SPEC_WORKTREES=0` |
| PreToolUse: Write\|Edit | restrict-agent-paths.sh | Path-glob enforcement, see below |
| PreToolUse: TaskCreate | task-created.sh | Required-metadata validation |
| PreToolUse: TaskUpdate | pre-task-blockedby-enforce.sh | Blocks claiming a task whose `blockedBy` isn't fully complete |
| PostToolUse: Bash\|Edit\|Write | strategy-rotation.sh | Advisory: nudges strategy after consecutive failures |
| UserPromptSubmit | done-criteria.sh | Compound-task heuristic detection |
| TaskCompleted | task-completed.sh, post-task-complete-revalidate.sh | Phase-aware lint/typecheck gate; user-gate evidence scan |
| TeammateIdle | teammate-idle.sh | Advisory only, never blocks |
| Stop | stop-revalidate-user-gates.sh, stop-deflection-guard.sh, adhoc-verify-guard.sh, deferral-guard.sh, session-end-learnings.sh | Safety-net gates + JSONL learning entry |

`hooks/restrict-agent-paths.sh` (read in full this run,
`hooks/restrict-agent-paths.sh:1-197`) identifies the caller by parsing the
transcript for the most recent **still-open** `Agent` dispatch (no matching
`tool_result` yet) — a closed dispatch's writes belong to the main thread, not
the finished subagent; this is the mechanism, not a name-based guess. Rules
verified in the case statement: `spec-writer`/`planner` → `docs/loop-spec/features/**`;
`pattern-mapper` → that or `.claude/agent-memory/**`; `mapper-*` (glob) →
`docs/loop-spec/codebase/**`; `code-reviewer` → `.claude/agent-memory/**` **only**
(the `memory: project` frontmatter auto-enables Write/Edit, so this closes the
gap that would otherwise let a read-only reviewer persona write code);
`implementer`/`verifier`/empty caller → unrestricted; unknown types → allowed
(fail-open by design).

### `lib/` — 90 non-test bash/python scripts
Not skills; invoked as `bash lib/<name>.sh <args>` from skill markdown. Given the
count, grouped by verified responsibility rather than enumerated; scripts marked
✓ were opened this run, the rest are grouped from filename + `run-all.sh`
registration only (not independently verified):

| Group | Representative scripts |
|---|---|
| Harness/capability probes | `harness.sh` ✓ (claude/pi/opencode + headless/loop-runtime detection, deterministic, `LOOP_SPEC_HARNESS` override), `teams-capability.sh`, `workflow-availability.sh`, `execute-rung.sh` ✓ (concurrency-ladder selector, see Key Abstractions), `dag-width.sh` ✓ (Kahn's-algorithm peak-parallelism), `model-tier.sh` ✓ |
| Feature state | `feature-write.sh` (atomic write: tmp→sync→bak→rename), `feature-init.sh`, `feature-validation.sh`, `team-ops.sh` |
| EXECUTE support | `validate-task-metadata.sh`, `integrate-task.sh`, `worktree-base.sh`, `worktree-commit-check.sh`, `task-route.sh` |
| Delivery / PR | `deliver.sh` ✓ (thin adapter, `lib/deliver.sh:2,13`), `pr-delivery.sh` ✓ (owns every `gh pr` call), `pr-comments.sh`, `pr-feedback.sh`, `pr-body.sh`, `checkpoint-pr.sh`, `revise-branch.sh` |
| Quality / security probes | `security-signal.sh`, `house-style.sh`, `comment-tells.sh`, `fragility-scan.sh`, `test-tamper-scan.sh`, `placeholder-scan.sh`, `regression-scan.sh`, `verification-baseline.sh`, `verification-gap-scan.sh`, `grounding-lint.sh`, `verification-grounding-lint.sh`, `acceptance-lint.sh`, `artifact-lint.sh`, `criteria-coverage.sh`, `decision-coverage.sh` |
| Telemetry / trust | `events.sh`, `cycle-result.sh`, `run-digest.sh`, `status.sh`, `trust.sh` ✓ (graduated L0–L3 autonomy governor, fail-closed, `lib/trust.sh:1-20`), `tuning.sh` |
| Autonomous chain | `sentinel-sources.sh`, `sentinel-triage.sh`, `sentinel-run.sh`, `issue-intake.sh`, `autonomous-chain.sh`, `backlog.sh`, `bounded-run.sh`, `watch.sh` |
| Codebase map | `map-refresh.sh`, `map-audit.sh` ✓ (measures, never rewrites, the map; `budget` caps total lines at `LOOP_SPEC_MAP_MAX_LINES` default 1000, `lib/map-audit.sh:26,43`), `gsd-ingest.sh` ✓ (still present, still maps GSD's 4 files to loop-spec's TECH/ARCH/QUALITY/CONCERNS; DOMAIN.md has no GSD analog) |
| Git / environment | `git-ops.sh`, `prepare-environment.sh`, `worktree-base.sh`, `credential-refresh.sh`, `resolve-bin.sh`, `run-with-watchdog.sh` |
| Misc/version | `bump-version.sh`, `plugin-version.sh`, `owned-gitignore.sh`, `runtime-ignore.sh`, `debug-init.sh`, `greenfield-bootstrap.sh`, `retro.sh`, `rules.sh`, `decisions.sh`, `converged-floor.sh`, `plan-adherence.sh`, `deferral-lint.sh`, `detect-test-cmd.sh`, `quality-loop-state.sh`, `workspace.sh`, `workflow-config.sh`, `project-commands.sh`, `active-cycle.sh`, `cycle-preflight.sh`, `cycle-reconcile.sh`, `finalize-delivery-candidate.sh`, `opencode-install.sh`, `plan-to-loop.sh`, `runtime-preflight.sh`, `sentinel-run.sh`, `extension-points.sh`, `verify-live.sh` |

`lib/workflows/*.js` (`execute-dag.js`, `map-codebase.js`, `acceptance-verify.js`,
`plan-multi-angle.js`, `code-review-dimensions.js`) are Workflow-tool DAG
definitions consumed by the `workflow` EXECUTE rung — the one place JS appears
outside the two `extensions/*.ts` files CLAUDE.md carves out; `hooks/install-bundled-workflows.sh`
installs them and `tests/run-all.sh` only syntax-checks them when `node` is
resolvable (`tests/run-all.sh:179-188`).

### `extensions/` — non-Claude harness bridges
`extensions/pi/loop-spec.ts` (231 lines) and `extensions/opencode/loop-spec.ts`
(333 lines), both read this run. Node-builtins-only by contract (`extensions/opencode/loop-spec.ts:22-26`
states it deliberately, and stays valid plain JS so the offline suite runs it
under stock node). Each re-implements the CC-native surfaces (`${CLAUDE_PLUGIN_ROOT}`,
`${CLAUDE_SKILL_DIR}`, SessionStart/UserPromptSubmit/Stop) as harness-native
hooks, so the same skill markdown runs unmodified under all three harnesses.

### `commands/` — one file, not six
Only `commands/loop-debug.md` exists. It is a one-shot alias
(`Skill(loop-spec:debug, args: "autonomous auto $ARGUMENTS")`) for pre-authored
"$ARGUMENTS" bug reports, not a shim layer for the phase skills — those are
invoked as `/loop-spec:<skill-name>` directly, no `commands/*.md` wrapper needed.

### `.loop-spec/` — runtime state (gitignored except `.loop-spec/codebase/index.json`)
Only `.loop-spec/codebase/index.json` exists in this checkout (no active feature
mid-run). Confirmed still committed and used by `map-codebase` to compute stale
domains from `git diff`.

### `docs/loop-spec/` — committed artifacts
`docs/loop-spec/codebase/{TECH,ARCH,QUALITY,CONCERNS,DOMAIN}.md` (this doc's
siblings, budget-capped in aggregate by `lib/map-audit.sh budget`) and
`docs/loop-spec/features/{slug}/` — 9 feature dirs present at time of mapping
(`multi-root-workspace`, `harness-alignment-graphify`, `grounded-claims`,
`resilience-ops`, `spec-phase`, `cycle-agent-teams`, `user-gate-flow`,
`v26-capabilities`, `planner-execute-discipline`).

### `tests/` — test infrastructure
`tests/run-all.sh` (read in full, 200 lines) runs **~120 suites**, not the two
(`smoke.sh`, `validate-agents.sh`) the prior ARCH.md claimed — that file no
longer exists. Categories: manifest/agent validators, hook units (all 20
`hooks/team/*.test.sh`), ~90 `lib/*.test.sh` unit suites, coverage-lock tests
(`*-coverage.test.sh`, one per cross-cutting contract CLAUDE.md calls out —
`design-coverage`, `human-code-coverage`, `pi-harness-coverage`,
`opencode-harness-coverage`, etc.), a Node-gated workflow syntax check, and
`skills/loop-runner/tests/run_tests.sh`. The test tree is offline-only: the former
`tests/e2e/` live suites were removed; no suite requires network or a live model.

---

## Module Dependencies

```
skills/{spec,discuss,plan,execute,verify,iterate,deliver}
                      <-  Skill(loop-spec:{currentPhase}) dynamic dispatch from skills/cycle
                          (skills/cycle/SKILL.md:746 — literal skill name is read from
                          feature_json.currentPhase, not hardcoded per-phase)

skills/cycle        ->  lib/feature-init.sh activate (per-phase model routing, Step 6)
                     ->  lib/feature-write.sh, lib/events.sh, lib/cycle-result.sh
                     ->  lib/extension-points.sh (project-declared phase instructions/facts)
                     ->  lib/teams-capability.sh (Step 2: none/explicit/implicit)
                     ->  skills/shared/model-matrix.md, tier-matrix.md

skills/execute       ->  lib/dag-width.sh (Step 2: compute W from tasks[] + conflict edges)
                     ->  lib/execute-rung.sh select (Step 3: rung = f(W, teams-capability.sh,
                          workflow-availability.sh, harness.sh loop-runtime))
                     ->  rung "team": TeamCreate/SendMessage/TaskCreate/TaskUpdate (skills/execute/
                          skills/execute/references/team-rung-protocol.md)
                     ->  rung "subagent"/"inline"/"loop"/"workflow": skills/shared/execute-{subagent,
                          inline,loops,loop-fleet}.md / lib/workflows/execute-dag.js
                     ->  lib/validate-task-metadata.sh, lib/integrate-task.sh, lib/worktree-base.sh

skills/verify        ->  Skill(loop-spec:map-codebase) incremental (skills/verify/SKILL.md:448)
                     ->  lib/feature-write.sh append pendingRemediationTasks (read back by execute)

skills/deliver       ->  lib/deliver.sh run  ->  lib/pr-delivery.sh (every `gh pr *` call)
                                             ->  lib/finalize-delivery-candidate.sh
                     ->  lib/pr-feedback.sh check/record

skills/sentinel      ->  lib/sentinel-sources.sh, lib/sentinel-triage.sh, lib/trust.sh (batch bound)
                     ->  Skill(loop-spec:intake)  ->  Skill(loop-spec:cycle) (skills/sentinel/SKILL.md:70-74)

skills/map-codebase  ->  TeamCreate; SendMessage per stale domain -> mapper-{tech,arch,quality,
                          concerns,domain}-1 teammates -> docs/loop-spec/codebase/*.md
                     ->  .loop-spec/codebase/index.json (git-diff-driven staleness)

agents/*             ->  skills/shared/artifact-templates/* (read at write time)
                     ->  docs/loop-spec/codebase/*.md (read for context)

hooks/restrict-agent-paths.sh  ->  python3 (transcript parse for open Agent dispatch)
hooks/team/task-created.sh     ->  python3 (payload parse)
hooks/team/*-inject.sh         ->  .loop-spec/{discipline,grill,simplicity,human-code}.conf,
                                     lib/rules.sh render (rules-inject.sh only)
lib/execute-rung.sh            ->  lib/harness.sh subagents|cli|loop-runtime|loop-runtime-reason
lib/deliver.sh                 ->  lib/pr-delivery.sh (LOOP_SPEC_PR_DELIVERY_BIN override point)
```

No circular dependencies found. `lib/harness.sh` is the one seam everything
harness-conditional passes through — `execute-rung.sh`, `dag-width.sh`
(indirectly, via width thresholds), and the pi/opencode extensions all read it
or its stamped env vars rather than sniffing tools themselves.

---

## Entrypoints

1. **`/loop-spec:cycle`** — top-level orchestrator; resumes an in-progress
   feature or starts fresh from a description or a pre-authored spec file.
2. **`/loop-spec:auto`** — question-free autonomous router; classifies a request
   to `micro`, `debug`, or `cycle` and never asks (`skills/auto/SKILL.md:1-8`).
   Preferred entry for SDK/headless callers.
3. **`/loop-spec:{spec,discuss,plan,execute,verify,iterate,deliver}`** —
   individually invocable, but each expects `feature.json.currentPhase` to
   already match; `phase-handoff-guard.sh` blocks a second phase skill firing
   directly in the same main-agent turn, so in practice these are cycle-internal.
4. **`/loop-spec:{micro,debug,intake,sentinel,assess,quality-loop,status,retro,
   watch,forensics,pause,rollback,walkthrough,revise,rules,onboard,discipline,
   grill,human-code,simplicity,map-codebase}`** — standalone skills, each usable
   without an active cycle.
5. **`/loop-debug`** (`commands/loop-debug.md`) — the only slash command outside
   the skill-name convention; one-shot alias into `debug` for a bug report.
6. **Hook-triggered**: SessionStart mode injections run on every session start
   regardless of user action; `UserPromptSubmit`'s `done-criteria.sh` and the
   five `Stop` hooks fire on ordinary turns, not just cycle runs.
7. **pi / opencode**: same skill set, entered via each harness's native
   skill-invocation surface, bridged by `extensions/{pi,opencode}/loop-spec.ts`.

---

## External Integrations

| Integration | How accessed | Notes |
|---|---|---|
| Claude Code / pi / opencode harness | `Skill`, `Agent`, `TeamCreate`, `TaskCreate`, `Workflow`, `AskUserQuestion`, `EnterWorktree` | Which surfaces exist is probed, never assumed — `lib/harness.sh` |
| GitHub (`gh` CLI) | `lib/pr-delivery.sh` — `gh pr view/list/create/edit/ready/checks`, `gh repo view` | All PR lifecycle now lives in DELIVER via this one file, not scattered across VERIFY as the prior ARCH.md claimed |
| Git | `git worktree`, `git merge --ff-only`, `git push`, `git diff` throughout EXECUTE/DELIVER/watch | Local + the one `git push` in delivery |
| `jq` | `lib/feature-write.sh` and the large majority of `lib/*.sh` | Assumed present; CLAUDE.md requires `jq >= 1.5` |
| `python3` | JSON parsing in hooks (`restrict-agent-paths.sh`, `task-created.sh`) and several `lib/*.sh` | Required runtime dep per CLAUDE.md |
| `node` | Syntax-checks `lib/workflows/*.js`; required at runtime only if the `workflow` EXECUTE rung is opted into and available | Optional — `tests/run-all.sh` skips its check when absent |
| GSD (get-shit-done) artifacts | `lib/gsd-ingest.sh` reads `.planning/{codebase,phases}/` | Optional, no network; prints `NONE` and mapper agents run instead when absent |

No other network calls found this run.

---

## Data Flow Summary

`feature.json` is still the central per-feature object, written only through
`lib/feature-write.sh`'s atomic protocol (validate → `.tmp` → `sync` → rotate
`.bak` → rename). What's different from the prior map: the lifecycle is now
**seven** phases, not four, and it can rewind.

```
currentPhase:  spec -> discuss -> plan -> execute -> verify -> iterate -> deliver -> completed
                                                          ^                   |
                                                          |__ iterate may rewind to
                                                              execute, plan, spec, or discuss
                                                              (human approval required to
                                                              rewind into spec/discuss)
```

- **SPEC**: Socratic interview, gated on a quantitative ambiguity score ≤ 0.20
  across 4 dimensions (not a single critique gate).
- **DISCUSS → PLAN**: single-critic critique gate by default, escalating to a
  full advocate/challenger debate only when contested or security-signaled
  (`lib/security-signal.sh`) — the always-on debate team the prior ARCH.md
  described is gone; single-tier operation fixed this.
- **PLAN Step 6** persists the gate-validated task DAG to
  `feature.json.artifacts.tasks` (`.loop-spec/features/{slug}/tasks.json`) —
  EXECUTE reads this, not a re-derivation from `PLAN.md` prose.
- **EXECUTE**: computes DAG width `W` (`lib/dag-width.sh`, Kahn's algorithm peak
  ready-set size) over PLAN's edges unioned with synthetic file-conflict edges,
  then `lib/execute-rung.sh select` picks one of five rungs — `inline` (serial,
  no subagent tool), `subagent` (lead-driven `Agent` waves), `team` (self-claim
  via `TaskUpdate`, harness `TaskList` is authoritative for *live status* here
  only), `loop` (loop-fleet, requires a persistent runtime), `workflow`
  (`execute-dag.js`, opt-in) — from measured width plus the harness capability
  probes, never a model judgment.
- **VERIFY**: acceptance gate + code-review hard gate, then triggers
  `map-codebase` incrementally before returning.
- **ITERATE**: `iterate-judge` (fresh agent, read-only) checks the integrated
  result against the *original* goal, not just VERIFY's frozen acceptance
  checklist; converged or budget-exhausted → DELIVER, otherwise classifies the
  highest-leverage gap and rewinds.
- **DELIVER**: sole owner of push / PR reconciliation / required-check wait /
  draft→ready transition, entirely through `lib/deliver.sh` → `lib/pr-delivery.sh`.
  Runs on the main thread; no team.

### Autonomous work-source loop (new since the prior map)
```
skills/sentinel scan  ->  source adapters (labeled issues, CI failures, backlog,
                           assessment findings) -> deterministic triage ->
                           .loop-spec/sentinel-queue.json (read-only)
skills/sentinel run    ->  pop first eligible item -> Skill(loop-spec:intake) ->
                           Skill(loop-spec:cycle) autonomous -> always PR-terminated,
                           batch-bounded by lib/trust.sh (never chains past a failure)
```

### Codebase map refresh (incremental, VERIFY-triggered or standalone)
```
git diff baseSha..HEAD --name-only -> .loop-spec/codebase/index.json lookup ->
stale domains -> TeamCreate mapper team -> mapper-*-1 teammates write
docs/loop-spec/codebase/*.md -> index.json updated -> lib/map-audit.sh budget/sweep
(measures the result; never rewrites it) -> git commit
```

---

## Key Abstractions

**Single-tier operation (the tier/preset axis is gone).** The prior ARCH.md's
"Tier vs Preset" abstraction is false as of this run: `skills/shared/tier-matrix.md`
states the quick/balanced/quality axis was removed in a v2.5.0 hard cutover.
Gate behavior, severity thresholds, and fan-out width are now FIXED; trivially
scoped work is handled structurally (the plan critique's structural fast-path,
the DAG-width ladder) rather than by an inferred intent tier. Model routing is a
separate, still-live axis: `skills/shared/model-matrix.md` maps role → model
alias, with `lib/feature-init.sh activate` writing the resolved
`feature.models.<role>` before every phase invocation.

**Probes, not judgments (CLAUDE.md's rule, verified in the code).** Every
consequential branch this run traced back to a deterministic script, never
prose: harness identity (`lib/harness.sh`), team capability
(`lib/teams-capability.sh`), EXECUTE's rung (`lib/execute-rung.sh`, which itself
composes `harness.sh` + DAG width + two more capability flags), and security
escalation (`lib/security-signal.sh`, word-boundary term match). Each emits its
answer plus its reason on one stdout line and fails toward the safer branch.

**The harness triad seam.** `lib/harness.sh` is the one place `claude`/`pi`/
`opencode` branching happens; `execute-rung.sh` and both `extensions/*.ts`
bridges read its output (or the env vars it documents) rather than re-detecting.
Per CLAUDE.md, every non-Claude accommodation is required to be an additive
branch keyed on this probe.

**Trust governor (new since the prior map).** `lib/trust.sh` computes a
graduated autonomy level L0–L3 from the committed metrics contract only — never
a self-report — and is fail-closed: any missing/null/unparseable signal resolves
to the lower level, demotion is instant, promotion requires a streak
(`lib/trust.sh:10-19`). `sentinel run` and the autonomous chain call its
`authorize` verb before acting; the check lives in the acting script, not in
skill prose, so a skill cannot talk itself past it.

**Path enforcement, re-verified.** Still three layers (agent `tools:`
frontmatter, `restrict-agent-paths.sh` PreToolUse glob check,
`task-created.sh`/`pre-task-blockedby-enforce.sh` PreToolUse task-integrity
checks), but the caller-identity mechanism in `restrict-agent-paths.sh` is worth
naming explicitly: it walks the transcript for the most recent *open* `Agent`
dispatch, so a finished subagent's writes are never misattributed once its
`tool_result` lands.

**The map audits itself.** `lib/map-audit.sh` is unusual among the `lib/`
scripts: it never rewrites `docs/loop-spec/codebase/*.md`, it only measures it —
total size against a 1000-line ceiling (`budget`), cited paths that vanished or
changed since the doc was written (`sweep`), index entries whose source file is
gone (`orphans`), and per-domain staleness. This document's own line count is
subject to that ceiling.

---

## Verification notes (this run)

Claims in the prior (2026-05-11) ARCH.md found **false** and not carried
forward: `lib/state-write.sh` (replaced by `lib/feature-write.sh`, which was
already true then and is still true), `skills/shared/preset-matrix.md` (no
preset axis exists any more — see Key Abstractions), `commands/{cycle,discuss,
plan,execute,verify,map-codebase}.md` (none exist; only `commands/loop-debug.md`
remains), the four-phase `DISCUSS -> PLAN -> EXECUTE -> VERIFY` cycle (it is now
seven phases, `SPEC` through `DELIVER`, with `ITERATE` rewind), "gh pr create
via Bash in VERIFY Step 5" (PR creation now lives entirely in DELIVER via
`lib/pr-delivery.sh`), and `tests/run-all.sh` running only `smoke.sh` +
`validate-agents.sh` (it now runs on the order of 120 suites).
