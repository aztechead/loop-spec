# Changelog

All notable changes documented here. Format follows Keep a Changelog.

## [2.4.0]

### Fixed
- **Released the modern-harness agent-teams support to main.** The v2.3.0 work (implicit-team
  mode for Claude Code >= 2.1.178) was merged but never released; the published 2.2.0 still
  attempted `TeamCreate` on harnesses that removed it, tripping the guarded-team-op refutation
  and permanently downgrading every phase to the no-teams fallback. This is the root cause of
  "TeamCreate/TeamDelete aren't exposed, only SendMessage, so it doesn't use agent teams".
- **`feature_title` is now persisted in feature.json** (`lib/feature-init.sh --title`, cycle
  Step 5 both modes, Step 5.9 backfill-from-slug for pre-2.4.0 features). ITERATE's judge
  scores against `feature.json.feature_title` as the immutable original goal; the schema-7
  skeleton never wrote it, so the judge silently fell back to SPEC.md — the exact
  passing-checklist-on-a-wrong-spec drift the dual oracle exists to catch.
- **ITERATE budget-exhausted ship is loud, never silent** (`skills/iterate/SKILL.md` Step 0):
  every unresolved gap from the last verdict is harvested into `warnings[]` (prefixed
  `iterate-budget-spent:`), an un-re-judged final remediation is called out explicitly, and
  the cycle On-completion summary now prints `warnings[]` under `## Shipped with warnings`.
  Previously a budget-spent ship looked identical to a clean converge, which is how a whole
  unmet requirement could pass ITERATE after a single remediation pass (quick tier
  `maxIterations=1` ships on re-entry without re-judging the fix).
- **`unresolved_dimensions` now has a consumer**: DISCUSS Step 1 reads the SPEC
  `ambiguity_scores` frontmatter and resolves each unresolved dimension (targeted question in
  interactive styles; explicit graph-grounded assumption in autonomous styles), converting it
  into a testable Good Enough criterion. Previously the list was written and read by nobody.

### Added (self-regulation — Ralph-loop + long-running-agent patterns)
- **Progress journal (F1)**: cycle appends a what/next/gotchas block to
  `.loop-spec/features/{slug}/PROGRESS.md` at every phase transition and commits it with
  feature.json — the narrative complement to machine state, read on resume and used as the
  handoff document for fresh-context rewinds.
- **Resume re-grounding (F2)**: mandatory protocol before re-entering any phase on resume —
  read PROGRESS.md, `git log -10`, run the test command once; a broken tree redirects to a
  remediation task instead of building a new phase on top of it.
- **Test-tamper scan (F3)**: `lib/test-tamper-scan.sh` + VERIFY Step 1.5 fail-fast — deleted
  test files, added skip/focus annotations (`.skip`, `.only`, `xit`, `@pytest.mark.skip`,
  `t.Skip`, ...), and `|| true` on added lines of test files are Critical tampering signals.
  Only ADDED lines are scanned (pre-existing skips never fire). 9-case suite.
- **Deferred-work backlog (F4)**: `lib/backlog.sh` (`add`/`next`/`done`/`count`, idempotent) +
  two automatic producers — VERIFY's tier-deferred findings and ITERATE's budget-spent gaps —
  and a completion-summary count line. Deferral now means "queued", not "gone". 13-case suite.
- **Backlog-drain mode (F5)**: `/loop-spec:cycle backlog` runs one full cycle per top backlog
  entry, bounded by `LOOP_SPEC_MAX_FEATURES` (default 1); never chains past a failure. The
  bounded Ralph loop: `while :; do claude -p "/loop-spec:cycle backlog"; done`.
- **Phase watchdog (F6)**: `currentPhaseStartedAt` stamped at every phase route (new schema
  field + skeleton default); elapsed time checked against tier-scaled ceilings (quick 30m /
  balanced 60m / quality 120m, `LOOP_SPEC_PHASE_TIMEOUT_MINS` override) on phase exit and
  resume. Warns and surfaces; never kills work.
- **Self-learning writers (F7)**: the previously writer-less RULES.md loop gains two automatic
  producers — a VERIFY criterion that fails twice becomes a deterministic rule
  (`rules.sh add --check`), and a budget-spent iterate ship records its gap class.
- **Fresh-context rewind (F8, opt-in `LOOP_SPEC_ITERATE_FRESH=1`)**: ITERATE rewinds commit
  state (feature.json + PROGRESS.md + iterate.feedback) and return to the user for a clean
  relaunch instead of continuing in an ever-longer session; an outer loop or loop-runner
  drives the re-entry.

### Fixed (post-audit hardening)
- **Tool whitelist contradictions**: `ToolSearch` (required by the deferred-tool rescue) and
  `Workflow` (dispatched by plan/verify/execute) were absent from the cycle tool whitelist and
  most phase `allowed-tools` — a literal reading of "any tool not listed is not permitted"
  forbade the cycle's own procedures. Both added everywhere they are used.
- **ITERATE confirmation pass**: when the iteration budget is spent but a remediation landed
  after the last judge pass, the judge runs exactly once more in report-only `mode=confirmation`
  (guarded by `iterate.confirmationUsed`, set before dispatch; does not count as an iteration;
  cannot rewind). Converged → ships as a confirmed converge; else the ship's warnings use the
  fresher verdict. Closes the remaining "fix shipped un-re-judged" semantics on quick tier.
- **Coverage gates whitespace-normalized**: `decision-coverage.sh` and `criteria-coverage.sh`
  now match on whitespace-collapsed text, so a criterion/decision reflowed across lines in
  PLAN.md no longer fails the gate falsely (reflow regression cases added to both tests).
- Inline `tier:`/`style:` override tokens are stripped from the feature title before it is
  slugified/persisted — they were polluting `feature_title`, the immutable goal the ITERATE
  judge scores against. Spec-draft copy instruction made workspace-mode-aware.
- `LOOP_SPEC_SPEC_FILE` env var: headless equivalent of `/loop-spec:cycle path/to/spec.md`
  for the non-interactive contract (title falls back to the spec's first `# ` heading).
- New lint suite `tests/lib/skill-references.test.sh`: every `${CLAUDE_SKILL_DIR}/references/*`
  pointer in a SKILL.md must resolve, and every references/ file must be pointed to (guards the
  progressive-disclosure layer against rename drift). Manual e2e matrix gains scenario rows
  (spec-file ingest, implicit/explicit harness, iterate budget ship); README tree refreshed.

### Added
- **Spec-file entry path** (the "loop-driven development from a spec file" claim, now honored
  end-to-end): `/loop-spec:cycle path/to/spec.md` detects an existing `.md` argument, copies it
  to `.loop-spec/features/{slug}/spec-draft.md`, and the SPEC phase runs **spec-file ingest
  mode** — no interview; the draft is graph-grounded, scored against the ambiguity gate, and
  normalized into the SPEC.md format with requirements preserved verbatim.
- **Skill-authoring audit against current Claude Code recommendations**: all four oversized
  SKILL.mds brought under the documented 500-line guidance via verbatim extraction into
  per-skill `references/` files (cycle 919→482 — workspace-mode procedures, startup probes,
  command detection, codebase-map bootstrap; verify 533→383 — workspace variants; execute
  555→457 — team-rung protocol Steps 7-10; plan 561→496 — workspace task-format rules +
  PATTERNS bootstrap). No content rewrites — pure relocation with pointer stubs.
  `argument-hint` added to quality-loop and rollback; README/marketplace/plugin descriptions
  updated (6 phases, v2.4.0 status, both agent-team harness generations, ponytail-ported
  simplicity mode named alongside the required graphify graph).
- **`lib/criteria-coverage.sh`** + plan Step 5.5 criteria-coverage gate + planner
  `## Spec coverage` section: every SPEC `### Good Enough` criterion must appear verbatim in
  PLAN.md, mapped to the task(s) satisfying it (quality/balanced BLOCK, quick advisory).
  VERIFY runs only the criteria PLAN records, so a criterion dropped in the SPEC->PLAN handoff
  was invisible to every downstream gate. Test: `tests/lib/criteria-coverage.test.sh`.
- **`iterate-judge` verdict gains `remaining_gaps[]`**: the judge still routes on the single
  highest-leverage gap, but now lists every other known miss; ITERATE converts execute-level
  remaining gaps into remediation tasks in the same pass (the budget counts judge passes, not
  fixes) and reports all of them on a budget-exhausted ship.
- **Deferred-tool rescue in the guarded-team-op contract** (cycle Step 2,
  `skills/shared/implicit-team-mode.md`): modern harnesses may expose `SendMessage`/`Task*`
  as deferred tools whose direct call fails with `InputValidationError` until a
  `ToolSearch("select:...")` loads the schema. That failure is now rescued (load + retry once)
  instead of being misread as a capability refutation that silently downgrades a
  teams-capable harness to the no-teams fallback.

## [2.3.0]

### Added
- **`lib/teams-capability.sh`** + **`skills/shared/implicit-team-mode.md`** -- the cycle now
  works on Claude Code **>= 2.1.178**, which **removed the `TeamCreate` / `TeamDelete` tools**
  (every session now has one implicit team; teammates are spawned directly via `Agent({name})`).
  Cycle Step 2 replaces the binary env probe with a deterministic, version-gated capability probe
  that resolves a three-way **`teamsMode`** (`none` / `explicit` / `implicit`), persisted to
  `.loop-spec/runtime.json` alongside the existing `teamsAvailable` boolean. Phase skills
  (`discuss`, `plan`, `execute`, `verify`, `map-codebase`) gained an implicit-mode adaptation:
  in `implicit` mode they skip `TeamCreate`/`TeamDelete` and spawn named teammates with `Agent({name})`,
  with `SendMessage` and the shared `TaskList` unchanged. Override with `LOOP_SPEC_TEAMS_MODE`.
  Tests: `tests/lib/teams-capability.test.sh` (11 cases) wired into `tests/run-all.sh`.

- **Unattended fleet resilience** (`skills/loop-runner/scripts/loop.py` + `supervisor.py`): new
  opt-in `--fallback-model <id>` (passes `claude -p --fallback-model` so a tick survives overload /
  model-unavailable instead of dying) and `--retry-watchdog <n>` (sets `CLAUDE_CODE_RETRY_WATCHDOG`
  for the child — the recommended unattended retry mechanism, CC 2.1.186, over the now-capped
  `CLAUDE_CODE_MAX_RETRIES`). The supervisor threads both into every loop config. Both default off.
  Tests: `run_tests.sh` section 12 (flag + env propagation, and the default-off case).

### Changed
- **Accurate team detection messaging.** On a modern harness with the flag set, the cycle no
  longer prints "agent teams unavailable / not exposed" and no longer issues a doomed `TeamCreate`
  that trips the guarded-team-op fallback. The guarded-team-op contract is retained as the
  `explicit`-mode safety net only. Resume/orphan handling (`cycle-resume-escalation.md`) skips the
  `TaskList` liveness probe and `TeamDelete` cleanup in `implicit`/`none` mode (no cross-session
  team to orphan or delete).
- **Hardened the ITERATE convergence oracle** (`skills/iterate/SKILL.md`): the `iterate-judge`
  verdict is now extracted from its fenced ```json block and key-validated before the ship/rewind
  decision; a malformed or missing verdict is treated as re-dispatch-once-then-escalate, never as
  "converged". Complements the harness structured-output hardening (CC 2.1.186/2.1.187) that already
  backstops the Workflow `agent({schema})` rungs (`lib/workflows/*.js`).

### Docs
- **Operator hardening guidance** (`docs/loop-spec/PREREQUISITES.md`): optional `Agent(model:...)`
  deny rules (parameter-matched permission syntax, named-spawn enforcement fixed in CC 2.1.186) to
  fail closed on off-policy models as defense-in-depth over loop-spec's prompt-level model pinning;
  plus a note on nested per-repo `.claude/skills` (`<dir>:<name>`) in workspace mode.
- **Subagent depth budget** documented in the cycle dispatch convention (CC's 5-level nested-subagent
  cap; loop-spec dispatch stays within it, and the loop-fleet rung sidesteps it via top-level `claude -p`).

## [2.2.0]

### Added
- **`lib/feature-init.sh`** -- single source of truth for the schema-7 `feature.json`
  skeleton and the canonical per-role models map. Cycle Step 5 (single + workspace) and
  Step 5.9 now both build/normalize from it, so the two construction sites cannot drift
  (this drift is what previously dropped `iterateJudge` from the normalized models map).
- **`lib/resolve-bin.sh`** -- resolves the real on-disk executable for a tool past
  version-manager shell-function shims (nvm/pyenv/rbenv/asdf), preferring
  `node_modules/.bin/*`. Wired into cycle Step 4 command detection.
- **`lib/acceptance-lint.sh`** -- flags bare-substring `grep` acceptance criteria (which
  pass on comments / fail on incidental substrings). Wired into the PLAN feasibility gate
  (blocks quality/balanced, advisory on quick).
- **`skills/shared/laziness-ladder.md`** -- canonical ponytail directive, inlined into
  every code-producing dispatch so the simplicity discipline is followed on every EXECUTE
  rung (team, subagent, loop-fleet, workflow), not only on the main thread.
- New tests: `feature-init`, `resolve-bin`, `acceptance-lint`, the `all-tests-registered`
  meta-test (every `*.test.sh` must be wired into the runner), and `ponytail-coverage`
  (the ladder must be present in every relevant-phase dispatch path). Wired three
  previously-orphaned tests (`ralph-remediation`, `pause-snapshot`, `regression-scan`).

### Changed
- **`feature.json` is now the committed resume contract** (tracked in git; the cycle
  commits it on each phase transition) so resume survives clone / hand-off. Its churny
  siblings (`feature.json.bak`, `gate-logs/`, transcripts) stay gitignored.
- Ponytail laziness ladder threaded into all four EXECUTE implementer dispatch paths and
  the per-task reviewer over-engineering pass in the subagent/workflow rungs.
- Cycle friction remediation: guarded team-op fallback (env var advertises intent, not
  capability), post-merge re-verify in the subagent rung, behavioral-first acceptance form,
  data-flow lens in the challenger, no-op-revision shortcut in DISCUSS.

### Removed
- **Pre-v7 schema support.** loop-spec is now schema-7 only; a `feature.json` with
  `schemaVersion != 7` is skipped on resume with a warning. Deleted
  `lib/migrate-schema-v3-to-v4.sh` and its test; stripped v1/v3/v5/v6/legacy branches from
  cycle/execute/pause/verify resume logic, `cycle-resume-escalation.md`, and
  `feature-state-schema.md`. Two modes remain: single-repo worktree and workspace.

### Fixed
- `lib/regression-scan.sh` used the bash-4-only `mapfile` builtin (live, used by VERIFY;
  broke on stock macOS bash 3.2) -- replaced with a portable read loop.
- Removed the redundant `isolation: worktree` frontmatter from `agents/implementer.md`
  (the explicit `git worktree add` off the feature branch is the sole worktree mechanism;
  harness auto-isolation branched from the base commit and stranded work).

## [2.1.0] - unreleased

### Added
- **Simplicity mode -- the laziness ladder** (`skills/simplicity/SKILL.md`,
  `hooks/team/simplicity-inject.sh`), concept-and-implementation ported from
  [ponytail](https://github.com/DietrichGebert/ponytail). A default-ON,
  self-scoped SessionStart directive that makes the assistant climb a 7-rung
  ladder before writing code -- YAGNI, reuse, stdlib, native, installed dep,
  one line, then the minimum that works -- without cutting validation, error
  handling, security, or accessibility ("lazy, not negligent"). Toggle and set
  intensity with `/loop-spec:simplicity on|off|lite|full|ultra|status`; kill
  switch `LOOP_SPEC_SIMPLICITY=0`. Follows the same toggle-skill + inject-hook
  pattern as grill and discipline, so it reuses existing infrastructure rather
  than adding a parallel mechanism.
- **Over-engineering review pass in `code-reviewer`** (quality/balanced tiers).
  VERIFY's code review now hunts complexity alongside correctness: tagged
  `delete`/`stdlib`/`native`/`yagni`/`shrink` findings reported as Important,
  with a `net: -N lines possible` tally. This ports ponytail-review into the
  existing review machinery instead of shipping a separate command skill. The
  `simplicity:` deliberate-shortcut comment convention (ceiling + upgrade path,
  harvestable with one grep) is distinct from the `TBD`/`FIXME`/`XXX` markers
  VERIFY blocks on.

## [2.0.0] - unreleased

**BREAKING:** graphify is now a hard requirement — the cycle aborts at startup if it
is not installed (escape hatch: `LOOP_SPEC_REQUIRE_GRAPHIFY=0`). Existing users must
`uv tool install graphifyy` before running `/loop-spec:cycle`. Major version bump.

### Added
- **ITERATE phase -- the outer convergence loop** (`skills/iterate/SKILL.md`,
  `agents/iterate-judge.md`). Closes the loop the infographic/article calls the heart of autonomy:
  after VERIFY's gates pass, ITERATE judges the integrated result against the **original goal**
  (not just the frozen SPEC checklist) via a fresh, strict `iterate-judge` (opus, maker≠checker),
  using a **dual oracle** -- deterministic acceptance gate (from VERIFICATION.md) AND an LLM goal
  re-judge scoring each criterion, brutally honest. On convergence it ships; otherwise it classifies
  the single highest-leverage gap and **rewinds** the phase chain: `execute` (implementation) routes
  a remediation task to EXECUTE, `plan` (decomposition) re-enters PLAN, `spec` (wrong scope) re-enters
  DISCUSS. **Fully autonomous in `auto`/`review-only`: no gap type blocks on a human** -- the `spec`
  rewind re-enters DISCUSS in autonomous refinement mode (no AskUserQuestion). This is safe because the
  judge always scores against the immutable original goal (`feature_title`), never the rewritten SPEC,
  so a rewind cannot redefine "done" to game its own oracle; the iteration budget hard-caps the loop and
  it ships-with-warnings when spent rather than waiting. Only `step`/`interactive` surface the SPEC-rewind
  approval gate. Bounded by tier-scaled `feature.iterate.maxIterations`
  (quick 1 / balanced 2 / quality 3) and the cycle-wide global budget -- it ships, never
  spins, never pauses for input in auto. Phase chain is now
  SPEC→DISCUSS→PLAN→EXECUTE→VERIFY→ITERATE→completed; VERIFY now exits to `iterate` instead of
  `completed`; new `feature.json` `iterate` state block + `iteration` artifact; PLAN/DISCUSS read
  `iterate.feedback` on re-entry to "fix the weakest point first". Generalizes the former EXECUTE-only
  remediation loop into the full DISCOVER→PLAN→EXECUTE→VERIFY→ITERATE cycle. Agent count 13→14.
- **Grill mode (on by default)** -- `hooks/team/grill-inject.sh` SessionStart hook injects a
  disambiguation directive so the assistant front-loads 2-4 sharp clarifying questions right after
  the user's initial prompt, before writing code or committing to an approach. Inverse default of
  discipline mode: ON unless `.loop-spec/grill.conf` pins `ENABLED=0` or `LOOP_SPEC_GRILL=0` is set.
  New `skills/grill/SKILL.md` toggle (`on`/`off`/`status`), `hooks/team/grill-inject.test.sh`
  (6 cases, wired into `tests/run-all.sh`), and hook registration in `hooks/hooks.json`.
  Capability adapted from the superpowers brainstorming/clarify pattern; loop-spec realizes it
  in-cycle through the existing SPEC Socratic interview and out-of-cycle through this directive.
- **Self-learning loop (RULES.md)** -- `lib/rules.sh` manages a curated, human-owned
  `.loop-spec/RULES.md`; `hooks/team/rules-inject.sh` (default on, inert until rules exist) carries
  those rules forward into every session so a repeated mistake becomes a permanent, preferably
  deterministic, check the loop cannot repeat. New `skills/rules/SKILL.md`
  (`add`/`list`/`render`/`path`, `--check` for deterministic enforcement). Escalation contract
  (`skills/shared/cycle-resume-escalation.md`) now appends a rule when a gate rejects the same class
  of mistake twice. Tests: `tests/lib/rules.test.sh` (12), `hooks/team/rules-inject.test.sh` (6).
  Idea from the "self-learning loop" anatomy (failure → enforced rule).
- **Guided onboarding** -- `skills/onboard/SKILL.md` (`/loop-spec:onboard`): a short
  multiple-choice walkthrough that writes the optional config in place (grill, self-learning,
  discipline, commit strategy) and confirms each path. Non-destructive and re-runnable.
- **Per-task model tier override** -- `lib/model-tier.sh` resolves an optional task
  `modelTier` (`mechanical`/`standard`/`frontier`) to a concrete model so a single task can route to
  the cheapest model that fits, overriding the fixed per-role default (a concrete `model` pin still
  wins). Wired into the EXECUTE subagent/loop dispatch and the planner's task metadata; the team rung
  keeps role defaults (teammates are pre-spawned). Test: `tests/lib/model-tier.test.sh` (8).
- **Commit-strategy config** -- `lib/workflow-config.sh` reads `.loop-spec/workflow.json`;
  `commitStrategy: at-end` collapses `feat/{slug}` into one commit at EXECUTE phase exit instead of
  per-task commits (default `per-task` unchanged; skipped in workspace mode).
  Test: `tests/lib/workflow-config.test.sh` (6).
- **Semver prerelease support** -- `tests/validate-manifest.test.sh` now accepts a semver
  prerelease suffix (e.g. `X.Y.Z-dev`) on `plugin.json`/`marketplace.json`, so rolling `main`
  builds can carry a `-dev` marker that release tooling strips. (This release is cut as `2.0.0`.)

### Changed
- **Graphify is now a hard requirement** (was optional/skip-if-missing). graphify
  ([safishamsi/graphify](https://github.com/safishamsi/graphify), PyPI `graphifyy`) is loop-spec's
  de-facto code-graph solution. New `lib/graphify-preflight.sh` (`check`/`graph-status`/`build`,
  documented CLI `graphify .` / `graphify . --update`) enforces it: cycle Step 2 aborts at startup
  when the binary is missing (with install instructions), and Step 5.4 hard-fails on a failed build
  instead of "continuing without a graph". Workspace mode now builds one graph per participating repo
  rather than skipping. Escape hatch: `LOOP_SPEC_REQUIRE_GRAPHIFY=0` (degraded Glob/Grep fallback).
  The design phases now treat the graph as **guaranteed and primary**, not conditional:
  `skills/spec/SKILL.md` (scout step queries the graph + GRAPH_REPORT.md god-nodes to ask sharper
  questions), `skills/discuss/SKILL.md` (graph drives the AskUserQuestion option sets),
  `agents/pattern-mapper.md` and `agents/planner.md` (graph-first analog-finding, dependency/blast-radius
  reasoning). `skills/map-codebase/SKILL.md` routes through the preflight lib. Manifests, README, and
  CLAUDE.md updated to list graphify as required. Test: `tests/lib/graphify-preflight.test.sh` (10).
  The offline test suite never invokes the cycle, so it does not require graphify installed.
- **Plan "User decisions (already made)" record** -- PLAN.md now carries an explicit
  decisions section (`agents/planner.md`); EXECUTE coordinators resolve a question from that record
  (and from `RULES.md`) before escalating, and escalation questions must be self-contained (name the
  artifact + verified state, never contradict a recorded decision). Adapted from superpowers v6.0.0
  plan-quality. (`skills/shared/cycle-resume-escalation.md`, `agents/planner.md`.)
- **Tier is now inferred, not asked** (`skills/cycle/SKILL.md` Step 3). The cycle reads the feature
  description (plus any grill answers) and infers `quick`/`balanced`/`quality` from a blast-radius
  rubric instead of presenting a tier menu. Bare `/loop-spec:cycle` now asks a single free-text
  "what do you want to build?" question — no tier/style menu. Inline overrides
  (`tier:...`, `style:...`) still honored but never prompted for. Non-interactive mode is unchanged
  (env vars, `LOOP_SPEC_ANSWER_TIER` default `quick`; inference is not applied in CI). Streamlines
  the entry from a multi-question gate to a single launch line.

## [1.1.0] - 2026-06-12

### Added
- **Workspace mode (multi-repo)** (`lib/workspace.sh` with `detect`/`list-repos`/`resolve-repo`):
  depth-1 child-repo discovery or explicit `.loop-spec/workspace.json` pin; `-C <path>` option on
  `lib/git-ops.sh`, `lib/checkpoint.sh`, and `lib/worktree-commit-check.sh` so every git operation
  can target an arbitrary repo root; feature state schema v7 optional `workspace` block (absent =
  single mode, no migration required); workspace paths added to `skills/cycle/SKILL.md` (Step 0
  detection, per-repo Step 4 command detection, two-phase in-place `feat/{slug}` branch creation in
  Step 5, graphify/GSD skip in Steps 5.4/5.5, workspace resume rule), `skills/plan/SKILL.md`,
  `skills/execute/SKILL.md`, and `skills/verify/SKILL.md`; `LOOP_SPEC_ANSWER_REPOS` env var for
  non-interactive workspace repo selection. EXECUTE subagent-rung cap in workspace mode is v1 scope;
  team/loop-fleet/Workflow rungs remain single-repo only (deliberately deferred).
- **`skills/assess/SKILL.md`** -- standalone, read-only codebase fragility and health assessment;
  workspace-aware (scans every configured repo in workspace mode, single repo in single mode).
  New `lib/fragility-scan.sh`: deterministic per-file fragility ranking from git history
  (commit churn, bugfix-commit density, recency weighting), pure git + python3 stdlib; no LLM.
  Dispatches bounded code-reviewer subagents at the top-N hotspot files (`LOOP_SPEC_ASSESS_TOP_N`,
  default 5 per repo); synthesizes `docs/loop-spec/assessment/ASSESSMENT.md`. Concept adapted from
  assessment-pipeline ideas; clean-room text.
- **`skills/quality-loop/SKILL.md`** -- iterative pre-commit review convergence loop;
  workspace-aware scope resolution (explicit file args win, else union of modified files across repos).
  Deterministic-checks-first ordering; review independence protocol (no prior-round findings in
  reviewer prompts); severity gate (security CRITICAL/HIGH block, MEDIUM/LOW advisory);
  `LOOP_SPEC_QUALITY_LOOP_MAX_ROUNDS` (default 3); systemic-issue escalation on same category in
  two consecutive rounds. New `lib/quality-loop-state.sh`: round/finding/convergence state tracker
  with atomic writes at `.loop-spec/quality-loop.json`. New `agents/security-reviewer.md` (sonnet,
  read-only tools: Read/Glob/Grep only); total agent count is now 13. Concept adapted from
  quality-loop ideas; clean-room text.

## [1.0.0] - 2026-06-10

### Changed
- **Rebranded super-spec → loop-spec and reset versioning to 1.0.0.** Plugin and marketplace are now named `loop-spec` / `loop-spec-marketplace`; the agent namespace is `loop-spec:{role}`, skills invoke as `/loop-spec:*`, environment variables use the `LOOP_SPEC_` prefix, the task marker metadata key is `loopSpec`, and state/artifact directories are `.loop-spec/` and `docs/loop-spec/`. Repository renamed to `aztechead/loop-spec` (GitHub redirects the old URL). No functional changes beyond the rename. Entries below this point predate the rebrand and use the old `super-spec` version lineage (1.0.0–3.2.0); their `loop-spec`/`LOOP_SPEC_` spellings were updated mechanically during the rename.

## [3.2.0] - 2026-06-10

### Added
- **Bundled loop-runner skill (`skills/loop-runner/`) — loop engineering as a first-class citizen.** Three tested layers for autonomous execution: `loop.py` (one bounded loop: invoke `claude -p`, verify, measure real progress, halt safely — verifier-integrity hash-locking, budget/iteration/stall/timeout stops, durable state, stable `result.json` contract), `compile_spec.py` (spec → validated task plan with a synthesized verifier per task), `supervisor.py` (plan → fleet in isolated worktrees with dependency-ordered scheduling, merge + halt policy, fleet budget clamping). Invocable standalone as `/loop-spec:loop-runner`. Its offline regression suite (29 checks against a fake `claude` binary) is wired into `tests/run-all.sh`.
- **EXECUTE loop-fleet rung** (`skills/shared/execute-loop-fleet.md` + `lib/plan-to-loop.sh` + `tests/lib/plan-to-loop.test.sh`): PLAN.md tasks (with explicit + synthetic `blockedBy` edges) are compiled into a loop plan and run as a supervised fleet. Selected on explicit opt-in (`LOOP_SPEC_EXECUTE_LOOPS=1`, any DAG width) or automatically in place of the team rung when agent teams are unavailable. This is the strongest spec-adherence path in the plugin: every iteration of every worker mechanically re-runs the task's `verifyCommand`, and SPEC.md/PLAN.md (plus per-task `specPath`) are integrity-protected — a worker that edits the requirements to match its work halts the entire fleet (`verifier_integrity`, mapped to the `verifier-integrity` escalation). Returns the identical `{merged, blocked, escalation, tier}` shape as the other rungs; loop state is durable, so re-entering EXECUTE resumes budget-halted tasks instead of re-paying completed iterations.
- **Teams-optional operation** (`skills/shared/no-teams-fallback.md`): the cycle no longer hard-aborts when `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS != 1`. Cycle Step 2 records `runtime.json.teamsAvailable`; DISCUSS/PLAN/VERIFY declare one-shot-subagent fallbacks (same agent types, models, prompt templates; critique rounds run challenger → advocate sequentially with `gate-logs/` summaries inlined), EXECUTE's ladder substitutes the loop-fleet or subagent rung, and resume treats unreachable teams as gone instead of demanding a manual `TeamDelete`.

### Fixed
- **Plugin hooks no longer break core Claude Code task tracking ("errors thrown during plugin use").** `hooks/team/task-created.sh` (PreToolUse: TaskCreate) denied EVERY TaskCreate lacking loop-spec metadata — including the main thread's ordinary task tracking and other plugins — and could itself error (no fail-open trap around its python3 call). `hooks/team/task-completed.sh` (TaskCompleted) similarly blocked unrelated completions during discuss/plan phases and ran the project's lint/typecheck on every unrelated completion during execute. Both are now scoped to loop-spec-owned tasks only (`metadata.loopSpec == true`, written by EXECUTE Step 4, or the `task-NNN:` subject convention), fail open on any parse error, and honor a `LOOP_SPEC_TASK_GUARD=0` kill switch. Test suites updated and `task-created.test.sh` is now actually wired into `tests/run-all.sh` (it previously never ran).
- **`hooks/restrict-agent-paths.sh` no longer misattributes main-thread writes to a finished subagent.** The caller heuristic took the LAST `Agent` dispatch in the transcript regardless of completion, so after any spec-writer/planner/mapper dispatch ended, subsequent main-thread Writes outside `docs/loop-spec/**` were spuriously DENIED (a major source of "reprompt to get back on track"). The parser now matches `tool_use` ids against `tool_result` ids and only attributes writes to a dispatch that is still open. Also added: fail-open ERR trap (a malformed payload previously exited 1 = harness hook error on every Write/Edit), a fast path that exits before any parsing when the project has no `.loop-spec/features` state, and a `LOOP_SPEC_PATH_GUARD=0` kill switch.
- **Workflow syntax smoke test parsed the wrong grammar.** `tests/workflows/smoke.sh` ran `node --check` on `lib/workflows/*.js`, which parses CommonJS module scope and rejects both `export const meta` and the dynamic-workflow dialect's top-level `return`/`await` — all five workflow scripts failed the suite despite being valid for the Claude Code workflow runtime. The check now emulates the runtime: strips `export` and wraps the body in an `async function(args, phase, agent, parallel, output)` before `node --check`-ing it as ESM.
- **Session-wide hook overhead trimmed (speed).** `strategy-rotation.sh` (every Bash/Edit/Write), `output-compressor.sh` (every Bash/Read/Grep), `done-criteria.sh` (every prompt), and `stop-deflection-guard.sh` (every Stop) now exit on a single `stat` when the project has no `.loop-spec/` state instead of spawning python3/jq pipelines in every unrelated project. `session-end-learnings.sh` no longer `mkdir -p`s `.loop-spec/` into every project the user ever opens — it only appends learnings where loop-spec is already in use.

### Changed
- **Cycle startup is faster.** The Step 3.5 model probe (two Agent dispatches) is cached in `runtime.json.modelsProbedAt` and skipped when probed within the last 24h or `LOOP_SPEC_SKIP_HEALTHCHECK=1`; a model-policy failure surfaces identically on the first real dispatch. The `runtime.json` write is now a merge (preserves cached keys) and additionally records `teamsAvailable`.
- `skills/shared/tier-matrix.md` EXECUTE ladder gains the loop-fleet rung rows; `.gitignore` covers loop-runner runtime state (`.loop/`, `*-loop-worktrees/`); plugin + marketplace manifests bumped to 3.2.0.

## [3.1.1] - 2026-06-02

### Fixed
- **EXECUTE no longer hangs when a teammate's completion message is dropped.** The team-rung lead loop previously advanced only on `REVIEW PASS` SendMessage receipt: it enqueued merges and re-checked the exit condition when that message arrived. A teammate's final `SendMessage` can race with its turn-end and never reach the lead (plain-text output is invisible, and the message can be coalesced with the idle notification), so a dropped `REVIEW PASS` stranded the completed task and the phase never exited. The lead now follows a **wake-and-reconcile contract** (`skills/execute/SKILL.md` Step 7): every wake -- any teammate `SendMessage` OR the harness-guaranteed `TeammateIdle` notification -- triggers a `TaskList` re-read, enqueues any `completed` task (excluding retry-exhausted `metadata.result == "blocked"` tasks) whose worktree has commits and is not yet merged/queued, processes the merge queue, and re-evaluates the exit condition. `REVIEW PASS`/idle/`CLAIMED` messages are demoted to wake hints; `TaskList` state is the source of truth. This mirrors the DISCUSS and PLAN phases, which already synchronize on `TeammateIdle` plus a state check. Teammate prompts (`implementer.md`, `reviewer.md`) and `execute-loops.md` now require the status `TaskUpdate` to precede its `SendMessage` so state is correct even if the message drops.

## [3.1.0] - 2026-06-02

### Added
- **EXECUTE concurrency ladder: dispatch mechanism now scales to the task DAG width `W` instead of always preferring the heaviest available tool.** Previously EXECUTE was binary: it used the Workflow DAG whenever the `Workflow` tool existed and fell back to a `TeamCreate` self-claim team otherwise. That inverted the Anthropic tool idiom (subagents for modest fan-out, teams for coordinated high concurrency, Workflow only on explicit opt-in). EXECUTE Step 3 now computes `W` via the new `lib/dag-width.sh` (peak antichain across a Kahn wave simulation over the union of explicit + synthetic `blockedBy` edges) and selects a rung:
  - `W == 1` -> **subagent, sequential** (one `Agent` per task, lead merges inline).
  - `2 <= W < t_team` -> **subagent, batched** (a wave of parallel one-shot `Agent` calls, no persistent team).
  - `t_team <= W < t_wf` -> **agent team** (the existing self-claim `TeamCreate` path, promoted from fallback to a first-class rung).
  - `W >= t_wf` -> **Workflow DAG** (`lib/workflows/execute-dag.js`) **only** when `LOOP_SPEC_EXECUTE_WORKFLOW=1` (explicit opt-in) and the `Workflow` tool is available.
  All four rungs use per-task worktrees, the same spec-compliance + retry contract, ff-merge into `feat/{slug}`, and return the identical `{merged, blocked, escalation, tier}` shape.
- **`lib/dag-width.sh`** plus `tests/lib/dag-width.test.sh` (wired into `tests/run-all.sh`): computes `W`, ignores dangling edges, and exits 3 on a dependency cycle so EXECUTE escalates a deadlock rather than mis-selecting a rung.
- **`skills/shared/execute-subagent.md`**: the lead-driven subagent-rung procedure (wave loop, implementer/reviewer `Agent` prompts, inline ff-merge), referenced by `execute` SKILL Step 3.
- **`runtime.json.workflowExecuteOptIn`**: written at cycle startup from `LOOP_SPEC_EXECUTE_WORKFLOW`. With the flag unset, EXECUTE never dispatches a Workflow even on a very wide DAG; it tops out at the agent-team rung. The flag does not affect the opportunistic fan-out workflows in PLAN/VERIFY/map-codebase (still gated on `workflowsAvailable` alone).

### Changed
- **`skills/shared/tier-matrix.md`** gains an "EXECUTE concurrency ladder" section with the rung rule and per-tier `t_team` / `t_wf` thresholds (quality/balanced: 3 / 6; quick: 4 / 8).

## [3.0.1] - 2026-06-01

### Fixed
- **Workflow availability was misdetected as unavailable, forcing every fan-out phase (EXECUTE, plan, verify, map-codebase) onto the slower TeamCreate fallback.** The cycle Step 3.5 probe set `runtime.json.workflowsAvailable` from model self-introspection and defaulted to `false` when unsure, so even on Claude Code versions where the `Workflow` tool is supported it wrote `false`. The probe now detects availability deterministically from the Claude Code version via the new `lib/workflow-availability.sh` (the `Workflow` tool ships in CC `>= 2.1.154`), with a `LOOP_SPEC_WORKFLOWS_AVAILABLE=1|0` override for testing. Unit-tested in `tests/lib/workflow-availability.test.sh` (wired into `tests/run-all.sh`).

## [3.0.0] - 2026-06-01

Collapse the model-selection axis to a single fixed per-role map, and fix the phase-chaining regression that blocked the cycle from invoking phase skills.

### Changed
- **Model selection is now fixed per role; the `quality`/`balanced`/`fast` preset axis is removed.** `skills/shared/preset-matrix.md` is renamed to `skills/shared/model-matrix.md` and rewritten as one fixed role -> model table. The map: Opus for spec-writer, planner, advocate, challenger, and spec-compliance-reviewer (the Ralph loop); Sonnet for implementer, code-reviewer, verifier, mapper-*, and pattern-mapper. `claude-haiku-4-5` is no longer assigned to any role. Tier (quality/balanced/quick) is unchanged and still controls gate behavior, retries, and fan-out width.
- **`feature.json` schemaVersion 4 -> 5.** The `preset` field is removed; `models` is rewritten to the fixed map. Migration is automatic and lossless: cycle Step 5.9 now normalizes `models` idempotently and drops a vestigial `preset` field on the next resume of any in-flight feature.
- **Cycle Step 3 no longer prompts for a model preset.** Inline `preset:...` tokens and the `LOOP_SPEC_ANSWER_PRESET` env var are silently ignored. The Step 3.5 health-check always probes the fixed two-model set `{claude-opus-4-8, claude-sonnet-4-6}`.
- **Tier-keyed Workflow params table** (refuteVoters/planAngles/dimensionReviewers/completenessCritic) moved from the old preset-matrix into `skills/shared/tier-matrix.md`, where it belongs (it was always keyed by tier, not preset). `dispatch-fanout.md` updated to point there.
- **Agent frontmatter defaults** for advocate, challenger, and spec-compliance-reviewer changed Sonnet -> Opus to match the fixed map.

### Fixed
- **The plugin could not chain skills.** `disable-model-invocation: true` was set on `cycle` and every phase skill, but the entire workflow is built on `Skill(loop-spec:{phase})` calls: the cycle orchestrator invokes each phase, and phases hand off to each other (spec -> discuss, verify -> execute). `disable-model-invocation` removes a skill from Claude's context entirely, so any `Skill(...)` call to it fails (`Skill loop-spec:spec cannot be used with Skill tool due to disable-model-invocation`); it also made `cycle` itself unreachable via `Skill(loop-spec:cycle)`, which the smoke harness relies on. Removed the flag from all seven workflow skills (`cycle`, `spec`, `discuss`, `plan`, `execute`, `verify`, `map-codebase`). They remain directly slash-invocable (`/loop-spec:<name>`); slash invocation is unaffected by the flag. Per the Claude Code skills docs, any skill invoked via `Skill(...)` from another skill must not carry `disable-model-invocation`.
- **SPEC/DISCUSS/PLAN commits landed on the base branch.** Previously `feat/{slug}` was not created until EXECUTE Step 1, so all spec and plan artifacts committed during the earlier phases went directly onto whatever branch the user had checked out. Feature-level worktrees fix this: the branch and worktree are created at cycle Step 5, before any artifact is written, so every phase commit from SPEC onward lands on `feat/{slug}` in isolation.

### Added
- **EXECUTE now runs as a Workflow DAG (`lib/workflows/execute-dag.js`).** When the `Workflow` tool is available, EXECUTE dispatches a deterministic dependency-ordered wave loop: each wave runs up to `maxParallelImplementers` implement+review chains in parallel, implementer agents create raw per-task worktrees via `git worktree add` at absolute paths (preserving the existing ff/rebase merge semantics and `lib/worktree-commit-check.sh`), a spec-compliance gate with per-task retry (up to `maxRetriesPerTask`) guards quality/balanced tiers, and a single dedicated merge agent ff-merges (rebase-retry on non-ff) each passed task branch into `feat/{slug}` sequentially. The prior self-claim agent team (TeamCreate lead + implementers + reviewers racing to claim harness tasks, with a manual FIFO merge queue) is retained as the `workflowsAvailable=false` fallback, following the same dispatch-fanout contract used by map-codebase, verify, and plan.
- **Feature-level git worktrees.** Each new feature (schema v6) gets a dedicated worktree created at cycle Step 5 via raw `git worktree add .claude/worktrees/{slug} -b feat/{slug} {baseSha}`. The orchestrator session enters it with `EnterWorktree({path: feature.worktreePath})` (path form, requires the path to be under `.claude/worktrees/`). All subsequent phase skills run inside the worktree because inline `Skill()` calls inherit the switched cwd. The user's main checkout is never switched onto a feature branch.
- **`feature.json` schemaVersion 5 -> 6.** New field `worktreePath` (string, value `.claude/worktrees/{slug}`). Features on schema v5 or earlier have no `worktreePath` and resume in-place without a worktree (back-compat; no forced migration of in-flight features).
- **`lib/git-ops.sh` subcommands `create-feature-worktree` and `list-feature-worktrees`.** `create-feature-worktree <slug> <base_sha>` guards against an already-existing worktree path or branch and prints the worktree path on success. `list-feature-worktrees` parses `git worktree list --porcelain` and prints one `<path>\t<branch>` line per worktree under `.claude/worktrees/`, used by cycle resume to discover in-progress features.
- **Resume discovers features via `git worktree list`.** On re-entry, cycle Step 1 calls `git-ops.sh list-feature-worktrees`, reads each worktree's `feature.json`, and for a schema v6 feature calls `EnterWorktree({path: feature.worktreePath})` before continuing. Legacy schema features resume in-place as before.
- **Pause snapshots and exits the worktree.** After writing `HANDOFF.json` and `.continue-here.md`, the pause skill calls `ExitWorktree({action: "keep"})` to return to the main checkout while leaving the worktree intact for resume.
- **Per-task EXECUTE worktrees now use absolute paths.** Subagents (implementers, reviewers) do not inherit the feature worktree cwd, so per-task worktree paths are now computed as `$(git rev-parse --show-toplevel)/.loop-spec/worktrees/{slug}/task-{taskId}` (absolute) and handed to implementers explicitly. The `git worktree add` call works from any directory because the path is absolute.
- **`EnterWorktree` and `ExitWorktree` added to cycle's allowed-tools.** These tools are used for the feature-level worktree only. Per-task EXECUTE worktrees continue to use raw `git worktree add` (not the harness tools) because implementers are subagents.

### Removed
- **`tests/smoke.sh` and the `tests/fixtures/minimal-py` fixture.** The headless single-cell end-to-end test drove the installed plugin (a cached git snapshot, not the working tree) through `claude --print "Skill(loop-spec:cycle)"`, which proved unreliable (it exercised stale code and the interactive AskUserQuestion path) and was never a dependable gate. End-to-end coverage is now the manual matrix in `tests/README.md`, run against a live Claude Code session. `tests/run-all.sh` remains the automated gate and now also runs `tests/workflows/smoke.sh` (workflow `node --check`) when a node runtime is present.

## [2.5.0] - 2026-05-29

SPEC-phase main-thread fix plus a doc-compliance pass against the official Claude Code skills/plugins/hooks docs. All findings were produced by a fan-out adversarial critique (each verified by an independent refute panel) and the survivors fixed here.

### Fixed
- **SPEC phase ran its Socratic interview inside a spawned `spec-interviewer` teammate**, but a subagent cannot hold an interactive question-and-answer with the user: it runs one turn and goes idle, so the phase stalled (no SPEC.md, the orchestrator kept nudging an idle teammate, and improvised `SendMessage` calls errored). The interview now runs on the **main thread** in `skills/spec/SKILL.md` itself: the orchestrator asks 2-3 questions per round via `AskUserQuestion`, scores the 4 ambiguity dimensions, enforces the gate (ambiguity <= 0.20 with per-dimension minimums), and writes SPEC.md + the transcript directly. This mirrors the discuss phase's main-thread clarifying loop. The non-interactive path (`LOOP_SPEC_NON_INTERACTIVE=1` + `LOOP_SPEC_ANSWER_SPEC_CONFIRM`/`LOOP_SPEC_ANSWER_SPEC_OVERRIDE`) is preserved and synthesizes SPEC.md from context.
- **`pause`/`rollback` skills invoked bundled `lib/` scripts with bare relative paths** (`skills/pause/SKILL.md` `bash lib/pause-snapshot.sh`; `skills/rollback/SKILL.md` `bash lib/checkpoint.sh ...`), which resolve against the user's project dir and fail with "No such file" in any real repo. Switched to the documented `${CLAUDE_SKILL_DIR}/../../lib/...` substitution, matching every phase skill.
- **Both blocking Stop hooks never checked `stop_hook_active`** (`hooks/team/stop-revalidate-user-gates.sh`, `stop-deflection-guard.sh`), so a Stop-hook-induced continuation could be re-blocked until Claude Code's 8-iteration override kicked in. Each now early-exits 0 when `stop_hook_active` is true. New test cases assert the guard.
- **Three hooks emitted malformed structured output** that the harness silently dropped, so their entire purpose never took effect: `output-compressor.sh` used the invalid `decision:"continue"` plus top-level `additionalContext`; `strategy-rotation.sh` and `budget-gate.sh` used top-level `additionalContext`. All three now nest under `hookSpecificOutput.{hookEventName,additionalContext}` per the hooks docs (shape already used correctly by `done-criteria.sh`/`discipline-inject.sh`).

### Removed
- **`agents/spec-interviewer.md`** deleted: the interview is no longer delegated to a subagent, and the spec phase no longer creates a team (the advocate/challenger spawned in the old spec team were never messaged). `validate-agents.sh` agent count 13 -> 12; the `spec-interviewer)` case and its fixture/test cases (M/N/O) removed from `restrict-agent-paths.sh`; README agent tree + top-level cycle diagram updated.
- **Six legacy `commands/*.md` shims** (`cycle`, `discuss`, `execute`, `plan`, `verify`, `map-codebase`) deleted. The docs mark `commands/` as the legacy form ("use `skills/` for new plugins"); each shim collided 1:1 with a same-named phase skill, and unlike the skills it lacked `disable-model-invocation: true` -- an unguarded, model-invocable proxy to a side-effectful workflow. The phase skills remain directly slash-invocable as `/loop-spec:<phase>` (the doc quickstart confirms `disable-model-invocation` skills are still slash-invocable).
- **Dead `continueOnBlock` field** removed from the two `TaskCompleted` entries in `hooks/hooks.json`. It is not a real hook-config field (the live hooks reference lists only `matcher` + `hooks` at the group level), so the harness ignored it; the `TaskCompleted` gates block on exit 2 by design, which is unchanged.

### Changed
- **SKILL.md bodies brought under the 500-line guidance** via progressive disclosure (skill-022). `execute` (570 -> 498): the implementer/reviewer self-claim loop walkthroughs (teammate-internal reference; the teammates actually run them from `team-prompts/implementer.md`/`reviewer.md`) moved to `skills/shared/execute-loops.md`; the lead's 3-state task model and its own procedure (merge queue, idle/wake, exit) stay inline. `cycle` (518 -> 485): the full resume algorithm and the phase pause/escalation procedure moved to `skills/shared/cycle-resume-escalation.md`; Step 1 keeps the inline resume fast-path. No procedural logic changed; only reference material relocated behind explicit pointers. `plan` is 489. (Runtime eval still pending, as smoke can't autodrive headless; the move is reference-only so behavior is preserved.)
- **README + `marketplace.json` version/model sync.** README status `v1.0.1 beta` -> `v2.5.0`; stale `claude-opus-4-7` model-policy references -> `claude-opus-4-8`; `marketplace.json` version `2.4.0` -> `2.5.0`; removed the deleted `commands/` from the structure tree and corrected the "commands map 1:1" framing.
- **`forensics` skill** gained an `argument-hint` (it reads `$ARGUMENTS`).

### Added
- **`$schema` on `plugin.json`** (`https://json.schemastore.org/claude-code-plugin-manifest.json`) for editor autocomplete/validation (Claude Code ignores it at load time). `claude plugin validate ./ --strict` passes.
- **`tests/validate-manifest.test.sh`** (wired into `run-all.sh`): asserts `plugin.json` version == `marketplace.json` version == top CHANGELOG heading, that `hooks/hooks.json` is valid JSON, and that no retired `claude-opus-4-7` id lingers in shipped agents/skills/README. Guards the version/model drift this release cleaned up.

### Evaluated, not applicable
- **Hook `if` argument-filter** (NIT): the flagged tool-event hooks (`restrict-agent-paths`, `output-compressor`, `strategy-rotation`, `budget-gate`) branch on caller identity, output content, or session cost respectively. The `if` field uses permission-rule syntax over the tool *input* (`"Bash(git *)"`, `"Edit(*.ts)"`), which cannot express any of those predicates; adding an `if` would silently skip invocations the hooks must process. Left without `if` deliberately.

### Noted (not changed; requires empirical confirmation before action)
- The `${CLAUDE_SKILL_DIR}/../../` vs `${CLAUDE_PLUGIN_ROOT}` question (29 skill references): the critique surfaced both directions; the more rigorous adversarial pass concluded `${CLAUDE_PLUGIN_ROOT}` is not substituted in skill Bash, so the current convention stays until confirmed live. (This was the v2.4.0 fix; do not revert it on a hunch.)

## [2.4.0] - 2026-05-29

Idiomatic-skills pass against the official Claude Code skills/plugins docs. Fixes two hard bugs that made a fresh run flail (filesystem hunting + "agent not found" retries) and aligns frontmatter with documented conventions.

### Fixed
- **Skills referenced bundled files via `${CLAUDE_PLUGIN_ROOT}`** (a hooks/MCP variable that is empty in skill Bash), so the orchestrator hunted the filesystem to locate `lib/`/`hooks/` every run. Switched all 29 skill references to the documented `${CLAUDE_SKILL_DIR}/../../lib|hooks/...` substitution. `hooks/hooks.json` keeps `${CLAUDE_PLUGIN_ROOT}` (correct there).
- **Plugin agents were spawned with bare `subagent_type: "loop-spec-<role>"`**, but the harness namespaces plugin agents as `loop-spec:<role>` -> every spawn failed first try with "Agent type not found" and the orchestrator retried. Agents are now referenced by their namespaced id.

### Changed
- **Renamed all 13 agents** to drop the redundant filename prefix: `agents/loop-spec-<role>.md` -> `agents/<role>.md` (frontmatter `name` and the namespaced id follow: `loop-spec:<role>`). `restrict-agent-paths.sh` now normalizes the namespaced/legacy caller to the bare role; fixtures + `validate-agents.sh` updated. Contributor guide ("Adding an Agent") updated.
- **Frontmatter idioms** on the 7 workflow skills (cycle, spec, discuss, plan, execute, verify, map-codebase): added `disable-model-invocation: true` (side-effectful workflows are user/cycle-invoked, never auto-triggered) and `allowed-tools` (the documented pre-approval, mirroring the in-body tool whitelist). `cycle` and `map-codebase` gained `argument-hint`; `cycle` Step 3 now reads the feature description from `$ARGUMENTS`.

### Deferred (follow-ups, not in this release)
- SKILL.md bodies are large (recurring token cost); the docs favor concise bodies with detail in supporting files. A concision pass needs eval evidence before restructuring tested flow.

## [2.3.0] - 2026-05-29

### Fixed
- **Graphify bootstrap never ran when the codebase docs already existed** (`skills/cycle/SKILL.md`): the graphify pre-flight was nested inside Step 5.5, which early-exits when all 5 `docs/loop-spec/codebase/*.md` exist, so a repo with the docs but no `graphify-out/graph.json` never got a graph. Hoisted to a standalone **Step 5.4** that runs every cycle (when graphify is installed), independent of the codebase-map skip. GSD supersession (preserve into loop-spec docs, then remove raw `.planning/codebase/`) moved into the same always-run step.
- **Reviews/mappers ran on opus** (`skills/cycle/SKILL.md` + all phase skills): model selection used a fragile per-spawn `preset_matrix[role][preset]` markdown lookup; when unresolved, teammates inherited the orchestrator's session model (opus). Now concrete model IDs are resolved ONCE at cycle Step 5 into `feature.json.models` and every spawn passes `model: feature.models.<role>` (a literal). map-codebase mappers, which had no `model:` at all, now get one. Authoring roles use opus only on the `quality` preset; reviewing/implementing/mapping roles never use opus. Features predating v2.3.0 (and v3-continued features) have no `models` block; the cycle backfills it from `preset` at Step 5.9 before routing, so phase skills never read an undefined model. Roles include `patternMapper`. (schema: `models` block documented in `feature-state-schema.md`.) Non-interactive `LOOP_SPEC_ANSWER_TIER` default remains `quick` (unchanged); the new interactive fast-path default is `balanced`, announced in the launch line.

### Changed
- **opus model id 4-7 -> 4-8** across `preset-matrix.md`, `model-policy.md`, `cycle` probe, `loop-spec-planner`, `loop-spec-spec-writer`, and `agents/README.md`.
- **Launch straight into the workflow** (`skills/cycle/SKILL.md` Step 3): when `/loop-spec:cycle <description>` carries a feature description, the cycle no longer opens a blocking 4-question prompt. It derives the title, parses optional inline `tier:`/`preset:`/`style:` overrides, defaults the rest to `balanced`/`balanced`/`auto`, prints a one-line launch summary, and proceeds. Only a bare invocation (no description) asks (a single title question). Startup Steps 1/2/3.5 now run silently (output only on failure or a real decision), removing the preflight narration.

## [2.2.0] - 2026-05-29

Pipeline audit (5 phase skills + shared infra) for speed and first-time quality, plus EXECUTE/review quality gates derived from usage-insights friction analysis. Findings were adversarially verified before implementation; eval-gated restructures are recorded in `docs/loop-spec/pipeline-audit-proposals.md`.

### Added
- **Shortcut/cheat gate in both reviewers** (`agents/loop-spec-spec-compliance-reviewer.md`, `agents/loop-spec-code-reviewer.md`): each now scans the diff for reject-on-sight shortcuts and bounces them before they reach the user. Patterns: suppression markers (`# type: ignore`, `ty: ignore`, `# noqa`, `# pyright: ignore`, `eslint-disable`, new warning filters), re-exports/shims added only to keep an old test/import green, `pytest.mark.xfail(strict=True)` that XPASSes or gutted assertions, and hardcoded/stubbed stand-ins for required logic. The per-task spec-compliance reviewer FAILs on any hit (earliest catch); the VERIFY code-reviewer flags them Critical.
- **Worktree-commit-landed guard** (`lib/worktree-commit-check.sh`, wired into EXECUTE Step 8 merge): asserts a worktree branch is ahead of its base before the lead ff-merges it, so a subagent that failed to commit (sandbox/worktree isolation) is caught loud instead of silently merging zero work. Test: `tests/lib/worktree-commit-check.test.sh` (registered in `run-all.sh`).
- **Graphify bootstrap on cycle start** (`skills/cycle/SKILL.md` Step 5.5.0): when `graphify` is installed and the repo has no `graphify-out/graph.json`, the cycle builds it with `graphify update .` (deterministic AST extraction, no LLM/API key) before the codebase map, so graph documentation accrues automatically as loop-spec is used. Idempotent: a repo that already has `graph.json` is left untouched. When the graph is bootstrapped this run and superseded GSD `.planning/codebase/` docs are present, they are removed (committed, recoverable) after their content is folded into `docs/loop-spec/codebase/` by the GSD ingest step.

### Fixed (graphify)
- Corrected the graphify CLI invocation in `skills/map-codebase/SKILL.md` (Step 0) and `skills/verify/SKILL.md` (Step 9) from the LLM-requiring `graphify . --update [--wiki]` slash form (which errored with "no LLM API key found" in CLI context) to `graphify update .` (no key needed).
- `agents/loop-spec-planner.md` and `agents/loop-spec-pattern-mapper.md` now gate "prefer graphify queries" on `graphify-out/graph.json` (what `query`/`path`/`explain` actually read) instead of `graphify-out/wiki/index.md`, so the no-LLM bootstrap graph is actually used.
- `skills/shared/feature-state-schema.md`: clarified the `graphify` index block (`graph.json` from `graphify update .`; `wiki` only from the LLM-backed run).

### Fixed
- **PLAN quality-tier workflow read undefined paths** (`skills/plan/SKILL.md`): the `plan-multi-angle` dispatch passed `feature.specPath`/`feature.patternsPath`, which do not exist; corrected to `feature.artifacts.spec`/`feature.artifacts.patterns`. The quality-tier draft agents were reading nothing and emitting empty/hallucinated plans.
- **EXECUTE preset model routing** (`skills/execute/SKILL.md`): the Step 4 `TeamCreate` omitted `model:` on implementers and reviewers, so fast-preset users silently got sonnet instead of haiku. Resolve from `preset-matrix` and pass explicitly per `model-policy.md`.
- **PLAN decision-coverage gate ran against an unbound `$plan_path`** (`skills/plan/SKILL.md`): `plan_path` is now declared in Inputs, so the Step 5.5 `decision-coverage.sh` call evaluates the real PLAN.md instead of spurious-blocking on an empty path.
- **SPEC interviewer non-interactive round-6 default** (`agents/loop-spec-spec-interviewer.md`): the agent defaulted to "abandon" (no SPEC.md written), contradicting the orchestrator contract (`spec/SKILL.md`: always write). Now defaults to writing SPEC.md with `unresolved_dimensions` flagged. Removes a non-deterministic abort path.
- **SPEC interviewer transcript write was denied by the path hook** (`hooks/restrict-agent-paths.sh`): the interviewer is documented to write its transcript under `.loop-spec/features/**`, but the hook allowed it only `docs/loop-spec/features/**`, silently denying the write. Added a dedicated case allowing both roots, with test coverage.
- **Ralph remediation dispatched empty briefs** (`lib/ralph-remediation.sh`): the loop read `t['description']`, but VERIFY writes remediation tasks with `subject`/`verifyCommand`/`acceptanceCriteria`. Compose the brief from the real keys (with `description` as a backward-compat fallback); test fixtures updated to the real schema.
- **`state.commands.*` references** (`agents/loop-spec-verifier.md`, `VERIFICATION.md.template`): renamed to `commands.*` (the actual schema-v4 field; `state.json` was removed in v1.0.0).
- **`smoke.sh` was inconsistent with the orchestrator** (`tests/smoke.sh`): asserted `schemaVersion == 3` while the cycle writes 4, and never exercised the SPEC phase. Now asserts `== 4`, sets the SPEC non-interactive env var, and asserts the spec phase ran (`completedPhases`, `artifacts.specInterview`, `ambiguity_scores` frontmatter).
- **`patternsSource` enum drift** (`skills/plan/SKILL.md`): wrote `"cached"`/`"planner"`, neither in the schema enum; standardized on `"pattern-mapper"`.
- **`baseBranch` not initialized at feature creation** (`skills/cycle/SKILL.md`): a plan-only/early-exit feature could open its PR against the wrong base. Now detected via `lib/git-ops.sh detect-base-branch` at cycle Step 5.
- **Schema/code drift** (`skills/shared/feature-state-schema.md`): documented `pendingRemediationTasks`, `bootstrapPendingDomains`, and `activeWorkflow` (written by the runtime, absent from the v4 contract); corrected the `retries` "Set by" attribution (reviewer / EXECUTE Step 6, not the hook); corrected the EXECUTE task-list creation note (Step 3, not a non-existent "Step 0" / "pre-created at PLAN exit").

### Changed
- **First-time-quality agent briefs.** The verifier is now handed its resolved test/lint/typecheck commands and told to gate only on SPEC "Good Enough" criteria (report "Exceptional" as informational); the code-reviewer now receives `spec_path` and checks each SPEC Boundary/anti-goal against the diff (flagging violations Critical) with a tier-to-blocking-severity rule; the planner spawn brief carries a pre-submit self-check against the feasibility and decision-coverage gates it is judged against.
- **Carry grounding context into EXECUTE tasks** (`skills/execute/SKILL.md`, `agents/loop-spec-planner.md`, `team-prompts/implementer.md`, `team-prompts/reviewer.md`): `readFirst` (planner `read_first` anchors) and `specPath` are now written into task metadata and read by implementers/reviewers, with a documented fallback to the feature SPEC.md when `specPath` is null. Implementers/reviewers previously started from a thin criteria list because `specPath` was never written.
- **SPEC.md template** (`skills/shared/artifact-templates/SPEC.md.template`): added the `<decisions>` block the spec-writer treats as mandatory and the decision-coverage gate scans for, removing a built-in author-stall.
- **SPEC interviewer scoring rubric** (`agents/loop-spec-spec-interviewer.md`): added per-dimension calibration anchors (at the minimum and ~0.85) and a "score from the SPEC you could write now, not from optimism" directive, tightening gate consistency.
- **VERIFY regression scan is now opt-in** (`skills/verify/SKILL.md`): the advisory scan re-ran every prior feature's test suite serially in front of the fail-fast marker scan and parallel team. It is now gated behind `LOOP_SPEC_REGRESSION_SCAN=1` (default off), taking the serial cost off the critical path.
- **PLAN reviewer warm-up** (`skills/plan/SKILL.md`): on non-quick tiers, advocate/challenger are sent a context-loading warm-up (SPEC + codebase maps only) while the planner authors, so round 1 does not start cold. Skipped on quick tier (no critique gate).
- **DISCUSS structured choices** (`skills/discuss/SKILL.md`): the clarifying loop now presents design/approach decisions as `AskUserQuestion` numbered multiple-choice with tradeoffs rather than prose, so the user steers with one click; free-text reserved for genuinely open prompts.

## [2.1.0] - 2026-05-28

### Added
- Dynamic workflows integration at fan-out points (`map-codebase`, VERIFY acceptance gate, VERIFY code-review HARD-GATE, PLAN multi-angle on quality tier). Workflows are dispatched only when the `Workflow` tool is available in the orchestrator session; the fallback path runs the previous TeamCreate dispatch unchanged.
- `hooks/install-bundled-workflows.sh` -- install-time injection of shared snippets + bundled `/loop-spec:codebase-audit` and `/loop-spec:multi-angle-plan` slash commands.
- `hooks/pre-cycle-permission-check.sh` -- non-fatal advisory when `Workflow` tool is missing.
- `skills/shared/dispatch-fanout.md` -- shared contract for workflow/fallback branching.
- Tier-driven workflow params (`refuteVoters`, `planAngles`, `dimensionReviewers`, `completenessCritic`) in `skills/shared/preset-matrix.md`.
- `forensics` detects `workflow_orphaned` anomaly within a session (never on legitimate cross-session resume).

### Changed
- `skills/{cycle,map-codebase,verify,plan,pause,forensics}/SKILL.md` updated with workflow dispatch branches and pause/resume snapshotting.

### Fixed
- **task-created hook registration** (`hooks/hooks.json`): moved `task-created.sh` from the `TaskCreated` event to `PreToolUse` with matcher `TaskCreate`. The harness `TaskCreated` event payload does not include `tool_input.metadata`, so the hook saw `metadata: None` on every call and denied all `TaskCreate` invocations. `PreToolUse:TaskCreate` is the shape the hook was written for (see header comment, `task-created.test.sh`), and matches the analogous registration of `pre-task-blockedby-enforce.sh` on `PreToolUse:TaskUpdate`. EXECUTE phase, which creates one task per implementer, is no longer blocked at the first `TaskCreate` call.

## [2.0.1] - 2026-05-28

### Fixed
- **task-created hook registration** (`hooks/hooks.json`): moved `task-created.sh` from the `TaskCreated` event to `PreToolUse` with matcher `TaskCreate`. The harness `TaskCreated` event payload does not include `tool_input.metadata`, so the hook saw `metadata: None` on every call and denied all `TaskCreate` invocations. `PreToolUse:TaskCreate` is the shape the hook was written for (see header comment, `task-created.test.sh`), and matches the analogous registration of `pre-task-blockedby-enforce.sh` on `PreToolUse:TaskUpdate`. EXECUTE phase, which creates one task per implementer, is no longer blocked at the first `TaskCreate` call.

## [2.0.0] - 2026-05-28

### Added
- **Spec phase** (`skills/spec/SKILL.md`): new SPEC -> DISCUSS -> PLAN -> EXECUTE -> VERIFY phase order. The spec phase runs a Socratic interview (up to 6 rounds, 5 rotating perspectives: Researcher, Simplifier, Boundary Keeper, Failure Analyst, Seed Closer) with a quantitative ambiguity gate (ambiguity <= 0.20, per-dimension minimums). Uses the weighted formula `1.0 - (0.35 * goal_clarity + 0.25 * boundary_clarity + 0.20 * constraint_clarity + 0.20 * acceptance_clarity)`. Produces SPEC.md with `ambiguity_scores` frontmatter. Agent: `agents/loop-spec-spec-interviewer.md`.
- **schemaVersion 4** (`skills/shared/feature-state-schema.md`): adds `"spec"` to `currentPhase` enum (before `"discuss"`), `retryBudget.perPhase.spec`, `retryBudget.perPhaseUsed.spec`, and `artifacts.specInterview`. Opt-in migration via `lib/migrate-schema-v3-to-v4.sh`. In-flight v3 features continue on v3 unless the user chooses to migrate on resume.
- **loop-spec-spec-interviewer agent** (`agents/loop-spec-spec-interviewer.md`): new teammate agent that conducts the Socratic interview loop, scores ambiguity after each round, enforces the per-dimension gate thresholds, and writes SPEC.md with the `ambiguity_scores` frontmatter block and `spec-interview-transcript.md`. Restricted to `docs/loop-spec/features/**` by `hooks/restrict-agent-paths.sh`.
- **cycle skill spec-phase routing** (`skills/cycle/SKILL.md`): cycle now initializes `schemaVersion: 4` and `currentPhase: "spec"` for new features, routes to the spec phase first, and prompts for opt-in migration when an in-flight v3 feature is detected on resume.
- Graphify optional integration: `skills/map-codebase/SKILL.md` now includes a Step 0 graphify pre-flight that runs `graphify . --update --wiki` when `command -v graphify` succeeds, falling back to a one-line install hint when graphify is absent. Graphify-absent runs still dispatch the three remaining mapper agents (quality, concerns, domain) with a note that ARCH and TECH domain coverage requires graphify.
- Graphify pre-update in verify: `skills/verify/SKILL.md` Step 7 runs `graphify . --update` (non-blocking) before the `map-codebase` skill invocation when graphify is detected.
- Graphify query preference in planner and pattern-mapper agents: when `graphify-out/wiki/index.md` exists, `agents/loop-spec-planner.md` and `agents/loop-spec-pattern-mapper.md` prefer `graphify query/path/explain` over reading flat ARCH.md and TECH.md for structural and architectural questions.
- Graphify block in feature-state-schema: `skills/shared/feature-state-schema.md` documents the optional `graphify` block in `index.json` (fields: `graph_json_path`, `wiki_path`, `last_updated`) and notes that in graphify-present mode the `last_refreshed_at` domain set covers only `quality`, `concerns`, and `domain` (not `tech` or `arch`).
- Deleted `agents/loop-spec-mapper-arch.md` and `agents/loop-spec-mapper-tech.md` (superseded by graphify in the graphify-present path); `tests/validate-agents.sh` expected count updated from 14 to 12.
- **checking-gates skill** (`skills/checking-gates/SKILL.md`): new skill for verifying task acceptance criteria. Loads the task's self-check definition, routes to `specifying-gates` when HOW is ambiguous (Path A), and executes the verification directly when HOW is clear (Path B). Handles all three `failurePolicy` values: `stop-plan`, `reopen-continue`, `log-continue`. Evidence is posted as `PROVEN BY` tokens in the task record via `TaskUpdate`.
- **specifying-gates skill** (`skills/specifying-gates/SKILL.md`): new skill for locking down verification mechanics when a task's acceptance criteria are underspecified. Asks the user four structured questions (observable, mechanism, scope, failure policy) via `AskUserQuestion` and optionally a fifth Q5 dispatch contract block when the chosen mechanism is subagent-driven. Writes back enriched metadata to the task via `TaskUpdate` and removes the `requiresUserSpecification` flag once complete.
- **post-task-complete-revalidate hook** (`hooks/team/post-task-complete-revalidate.sh`): `TaskCompleted` hook that scans the transcript window for `AC:` and `PROVEN BY` evidence tokens on any task with `userGate: true` in its metadata. Exits 2 (block) when a gate task closes without evidence; exits 0 for all non-gate tasks. Honors kill-switch `LOOP_SPEC_USERGATE_GUARD=0`; fails open on malformed payloads. Appends pipe-separated trace-log lines to `${LOOP_SPEC_USERGATE_TRACE_LOG:-/tmp/claude-hooks/loop-spec-user-gate-trace.log}`.
- **stop-revalidate-user-gates hook** (`hooks/team/stop-revalidate-user-gates.sh`): `Stop` event hook that re-validates all closed `userGate: true` tasks when the last assistant message contains a plan-complete phrase (e.g., "all gates passed", "plan complete", "all tasks completed"). Exits 2 when any gate task is missing `AC:` or `PROVEN BY` evidence in the full transcript. Honors kill-switch `LOOP_SPEC_USERGATE_STOP_GUARD=0`; fails open on malformed payloads.
- **pre-task-blockedby-enforce hook** (`hooks/team/pre-task-blockedby-enforce.sh`): `PreToolUse:TaskUpdate` hook that blocks any `status=in_progress` transition when a `blockedBy` entry in the task's metadata is not yet `completed`. Outputs `DENY: task-NNN is blocked by task-MMM (status: pending)` to stderr. Exits 0 when `blockedBy` is empty, all dependencies are `completed`, peer task statuses are unavailable in the payload (fail-open), or the status transition is not `in_progress`. Honors kill-switch `LOOP_SPEC_BLOCKEDBY_GUARD=0`.
- **stop-deflection-guard hook** (`hooks/team/stop-deflection-guard.sh`): `Stop` event hook that blocks session-end when the last assistant message contains a context-excuse deflection phrase ("fresh session", "context is full", "context is high", "running low on context", "start a new session") but computed context usage (input_tokens + cache_read_input_tokens + cache_creation_input_tokens) is below `LOOP_SPEC_DEFLECTION_THRESHOLD_PCT` percent (default 50) of `LOOP_SPEC_CONTEXT_LIMIT` (default 200000). The exit 2 rejection message cites the actual computed usage percentage. Honors kill-switch `LOOP_SPEC_DEFLECTION_GUARD=0`; fails open when the `usage` field is absent.
- **9 new optional task metadata fields** in `skills/shared/feature-state-schema.md` "Harness task list usage" table: `userGate` (bool, marks a task as a user-verified gate), `requireEvidenceTokens` (array of token arrays, extra evidence patterns to match), `requireABCompare` (bool, requires side-by-side comparison evidence), `subagentType` (string, subagent role for gate execution), `model` (string, model override for gate subagent), `dispatchBrief` (string, prompt fragment passed to the gate subagent), `failurePolicy` (string enum: `stop-plan` | `reopen-continue` | `log-continue`), `gateScope` (string enum: `once` | `per-target` | `one-then-all` | `custom`), `requiresUserSpecification` (bool, triggers `specifying-gates` skill before gate execution). All fields are optional; `lib/validate-task-metadata.sh` type-checks them when present and rejects invalid enum values.
- **Anti-shallow planner rules**: `agents/loop-spec-planner.md` now includes an explicit anti-shallow section with a linked reference to `docs/loop-spec/planner-antipatterns.md`. The antipatterns doc enumerates failure modes (vague steps, missing verify commands, unconstrained files lists, copy-paste task bodies) with concrete before/after examples. Planner is instructed to self-check each task against the antipatterns list before emitting the plan.
- **decision-coverage gate** (`lib/decision-coverage.sh`): new lib helper that scores a PLAN.md for decision coverage. Counts design decisions (architecture choices, library picks, data-shape choices) and checks that each has a stated rationale. Exits non-zero with a structured report when coverage falls below threshold. BLOCKING on quality and balanced tiers; advisory (exit 0 with warning) on quick tier. Exercised by `tests/lib/decision-coverage.test.sh`.
- **plan-adherence exit check** (`lib/plan-adherence.sh`): new lib helper invoked at EXECUTE Step 10. Diffs the committed file set against the task's declared `files` list and flags untracked writes and missing writes. Exits non-zero when drift exceeds zero (strict mode, quality/balanced) or a configurable threshold. Exercised by `tests/lib/plan-adherence.test.sh`.
- **detect-test-cmd helper** (`lib/detect-test-cmd.sh`): new lib helper that auto-detects the project's test command from `package.json`, `Makefile`, `pyproject.toml`, `Cargo.toml`, and common CI config files. Returns the first matching command string. Used by the post-merge build/test gate in EXECUTE Step 8. Exercised by `tests/lib/detect-test-cmd.test.sh`.
- **Post-merge build/test gate in EXECUTE Step 8** (quality/balanced tiers only): after each implementer merges its worktree branch, EXECUTE Step 8 now calls `lib/detect-test-cmd.sh` and runs the detected test command in the feature branch context. A non-zero exit blocks further task dispatch and triggers the existing retry/reopen flow. The gate is skipped entirely on quick tier.
- **strategy-rotation hook** (`hooks/team/strategy-rotation.sh`): `TaskCompleted` hook that tracks consecutive task failures per feature slug in a temp-dir counter file. When failures reach `LOOP_SPEC_ROTATION_THRESHOLD` (default 3) it emits a `BLOCK:` message recommending a strategy review and resets the counter. Exits 0 on success transitions. Honors kill-switch `LOOP_SPEC_ROTATION_GUARD=0`. Exercised by `hooks/team/strategy-rotation.test.sh`.
- **budget-gate hook** (`hooks/team/budget-gate.sh`): `Stop` event hook that reads cumulative token usage from the session payload and blocks session-end when projected cost exceeds `LOOP_SPEC_BUDGET_CEILING_USD` (default 10.00). Cost is estimated from input/output token counts using configurable per-token rates. Emits a structured overage report to stderr. Honors kill-switch `LOOP_SPEC_BUDGET_GUARD=0`; fails open when usage field is absent. Exercised by `hooks/team/budget-gate.test.sh`.
- **pause skill + lib/pause-snapshot.sh** (`skills/pause/SKILL.md`, `lib/pause-snapshot.sh`): `/loop-spec:pause` skill that snapshots mid-cycle state into `HANDOFF.json` (current phase, task statuses, last-known-good commit, budget consumed) and writes `.continue-here.md` with a resume script. Enables safe session handoff without losing cycle progress.
- **forensics skill** (`skills/forensics/SKILL.md`): `/loop-spec:forensics` read-only diagnostic skill that runs 7 named patterns (stall-detect, drift-check, evidence-scan, gate-leak, budget-audit, dependency-cycle, integrity-check) against the current feature state and emits a structured report. No writes; safe to run at any point in a cycle.
- **Regression gate in verify** (`skills/verify/SKILL.md`): advisory pre-VERIFY regression scan that calls `lib/regression-scan.sh` before dispatching verifier agents. Emits a structured warning report when regressions are detected; advisory only (non-blocking) so the cycle continues to standard verification.
- **rollback skill + lib/checkpoint.sh** (`skills/rollback/SKILL.md`, `lib/checkpoint.sh`): `/loop-spec:rollback` skill backed by `lib/checkpoint.sh` which creates and restores git-tag-based checkpoints. Supports 6 checkpoint types: phase-start, phase-end, task-complete, user-gate, manual, and auto. Tags follow the pattern `ss-ckpt/{slug}/{type}/{timestamp}`.
- **Ralph remediation executor** (`lib/ralph-remediation.sh`): threshold-gated bounded retry loop for automated remediation of known failure patterns. Reads failure fingerprints from the task record, dispatches targeted fix agents up to `LOOP_SPEC_RALPH_MAX_RETRIES` times (default 3), and exits non-zero when the threshold is exceeded to escalate to human review.
- **Intent contract integration in spec-writer** (`agents/loop-spec-spec-writer.md`): spec-writer now produces a Boundaries section (explicit out-of-scope declarations) and a 2-tier Success criteria block (measurable done-conditions split into must-have and nice-to-have). Ensures downstream planner and verifier have a shared intent contract to check against.
- **discipline-inject SessionStart hook + discipline skill** (`hooks/team/discipline-inject.sh`, `skills/discipline/SKILL.md`): `SessionStart` hook that injects the active cycle's discipline rules into the session context at startup. Paired with `/loop-spec:discipline` skill for viewing and amending those rules mid-session. Exercised by `hooks/team/discipline-inject.test.sh`.
- **output-compressor PostToolUse hook** (`hooks/team/output-compressor.sh`): `PostToolUse` hook that compresses agent tool outputs exceeding 3000 characters by stripping whitespace, collapsing repeated lines, and summarizing long JSON arrays. Reduces context window pressure on high-output tasks. Exercised by `hooks/team/output-compressor.test.sh`.
- **done-criteria UserPromptSubmit hook** (`hooks/team/done-criteria.sh`): `UserPromptSubmit` hook that intercepts compound task completions (messages containing multiple "done" markers) and validates that each sub-task has a matching evidence token before allowing the submission to proceed. Exits 2 to block premature done claims. Exercised by `hooks/team/done-criteria.test.sh`.
- **session-end-learnings Stop hook** (`hooks/team/session-end-learnings.sh`): `Stop` hook that accumulates session learnings into a cross-cycle JSONL log (`${LOOP_SPEC_LEARNINGS_LOG:-/tmp/claude-hooks/learnings.jsonl}`). Extracts failure patterns, successful strategies, and timing data from the session payload before allowing the session to end. Exercised by `hooks/team/session-end-learnings.test.sh`.
- **Agent frontmatter additions** (`agents/`): all agent definition files now include `isolation`, `effort`, and `disallowedTools` frontmatter fields. `isolation` declares the agent's expected execution context (worktree / shared / any). `effort` signals relative token budget (light / medium / heavy). `disallowedTools` lists tools that must never be called by that agent role. A new `agents/README.md` documents all frontmatter fields and their allowed values.

## [1.0.2] - 2026-05-20

### Removed
- Cycle Step 2b harness capability probe (TeamCreate `loop-spec-probe-{pid}` + probe-a/probe-b teammates + 5 sub-probes). Each cycle start now skips the throwaway team and 30-60s of agent dispatch; harness contract violations surface at the first real phase call site instead. Env-var check (Step 2a) retained.

## [1.0.1] - 2026-05-18

### Fixed
- **Critical**: restored exec bit on `hooks/team/*.sh` and `tests/lib/*.test.sh` + `tests/validate-agents.test.sh` (v1.0.0 shipped them mode 100644, breaking plugin install with "Permission denied" on every TaskCreate / TaskCompleted / TeammateIdle event)
- **Critical**: rewired `hooks/team/task-completed.sh` from invalid top-level `TaskCompleted` event registration (where the script's `tool_name == "TaskUpdate"` gate could never fire) to `PostToolUse: TaskUpdate`, restoring the lint/typecheck quality gate
- **Major**: removed all `waves[]` references from `skills/plan/SKILL.md`, `agents/loop-spec-planner.md`, and `skills/shared/artifact-templates/PLAN.md.template` (v1.0.0 already moved to self-claim parallelism but planner prompts still asked for waves[])
- **Major**: hardened `lib/feature-write.sh` to assert array type on append (would have silently overwritten non-array `false` values with `[$v]`)
- **Major**: corrected stale `state.json` references in `agents/loop-spec-planner.md`, `commands/discuss.md`, and `skills/cycle/SKILL.md`
- **Major**: removed unused `EXECUTION.md.template` and all references (no v1.0.0 phase skill writes EXECUTION.md)
- **Major**: corrected preset enums (`opus|economy` leftovers) in `skills/shared/feature-state-schema.md`, `skills/map-codebase/SKILL.md`, `skills/shared/tier-matrix.md`, `docs/tier-guide.md`, `docs/loop-spec/codebase/ARCH.md`
- **Minor**: hardened `hooks/team/task-completed.sh` shell-command exec (allowlist + array exec, no `bash -c`)
- **Minor**: hardened `lib/feature-write.sh` dot_path (validated segments, passed via `--argjson` to jq `setpath`)
- **Minor**: restricted `lib/team-ops.sh` CLI dispatcher to explicit function allowlist
- **Minor**: reordered `find -maxdepth -name` flags in `task-completed.sh` to silence GNU `find` warning on Linux
- **Minor**: stripped duplicate `Slug` glossary entry and stale `state.json (schema v2)` reference from `docs/loop-spec/codebase/DOMAIN.md`

### Changed
- Preset options reduced from 5 (opus/quality/balanced/fast/economy) to 3 (quality/balanced/fast)
- Architectural rule: opus reserved for spec-writer and planner only; all other roles (reviewers, advocates, implementers, mappers) capped at sonnet/haiku
- quality preset: opus for spec-writer/planner, sonnet for all other roles
- balanced preset: sonnet throughout
- fast preset: sonnet for spec-writer/planner, haiku for all other roles
- Agent frontmatter defaults updated: code-reviewer, spec-compliance-reviewer, advocate, challenger, verifier changed from opus-4-7 to sonnet-4-6
- README + CLAUDE.md "Zero deps" claim updated to declare `bash`, `git`, `jq >= 1.5`, `python3 >= 3.6` as runtime prereqs (no package manager required)
- Added 5 mermaid diagrams to README Architecture section (top-level cycle, per-phase team lifecycle, critique-gate debate, EXECUTE self-claim topology, task lifecycle state machine)

### Previously changed
- PLAN phase: pattern-mapper-1 teammate removed; planner-1 now produces PATTERNS.md then PLAN.md in one agent turn (eliminates one sequential model call per PLAN phase)
- PLAN phase: pattern-mapper skipped if PATTERNS.md already exists from any prior source (cache check before spawning planner-1)
- EXECUTE phase: spec-compliance gate skipped on quick tier (R=0 reviewers; implementers self-complete and signal lead directly)
- Codebase bootstrap (Step 5.5b): mapper agents now fire as background Agent calls instead of blocking Skill invocation; DISCUSS Q&A proceeds concurrently; discuss/SKILL.md Step 1.5 polls for completion with fallback to synchronous map-codebase on timeout
- Model probe (Step 2c) deferred to Step 3.5 (after preset selection); only unique models for the chosen preset are probed instead of all 3 models regardless of preset
- Retry budgets now tier-dependent: quick (perGate=1, global=10), balanced (perGate=2, global=20), quality (perGate=3, global=30)
- Tier default changed from `balanced` to `quick` in non-interactive mode and AskUserQuestion ordering
- AUTO-style DISCUSS Q-round caps reduced: quality 5->3, balanced 5->2, quick 3->1

## [1.0.0] - 2026-05-11

### Added
- Agent teams for all phases (DISCUSS, PLAN, EXECUTE, VERIFY, map-codebase): each phase creates a dedicated team via TeamCreate with specialized teammates communicating via SendMessage
- lib/feature-write.sh: atomic write helper for feature.json (replaces lib/state-write.sh)
- lib/team-ops.sh: shell helpers for team name generation and env validation
- hooks/team/teammate-idle.sh: phase-aware TeammateIdle advisory hook
- hooks/team/task-created.sh: TaskCreate metadata validation hook (TaskCreated event)
- hooks/team/task-completed.sh: phase-aware completion gate (TaskCompleted event)
- skills/shared/team-prompts/: advocate, challenger, implementer, reviewer prompt templates
- skills/shared/feature-state-schema.md v3: replaces state.json with feature.json
- docs/loop-spec/PREREQUISITES.md: CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 setup guide
- Tier-driven team params: maxCritiqueRounds, maxParallelImplementers, maxRetriesPerTask

### Changed
- All phase skills (cycle, discuss, plan, execute, verify, map-codebase) rewritten to use TeamCreate/SendMessage/TaskCreate
- Execution model: wave-based parallel dispatch replaced by harness task list with self-claiming implementers
- State storage: state.json replaced by feature.json (.loop-spec/features/{slug}/feature.json)
- Tool whitelist in cycle/SKILL.md: TeamCreate, TeamDelete, SendMessage, TaskCreate, TaskUpdate, TaskList, TaskGet now allowed
- Critique debate: advocate+challenger now debate directly via SendMessage (ROUND-N DONE protocol)
- Version bumped to 1.0.0

### Removed
- lib/state-write.sh and tests/lib/state-write.test.sh (replaced by lib/feature-write.sh)
- Wave-based execution (tasks[], waves[] from state.json)
- One-shot Agent dispatch model for phase orchestration (replaced by TeamCreate)

### Migration
This is a breaking change. There is no automatic migration from v0.3.2 to v1.0.0.
- **In-flight features on v0.3.2**: complete them on v0.3.2 before upgrading. state.json files from v0.3.2 are not compatible with v1.0.0.
- **After upgrading**: start fresh cycles. Run `Skill(loop-spec:cycle)` for new features.
- **Prerequisite**: set `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` and use Claude Code v2.1.32+. See docs/loop-spec/PREREQUISITES.md.

## [0.3.2] - 2026-05-11

### Fixed
- `cycle/SKILL.md` frontmatter description and `commands/cycle.md` both omitted "model preset" from their prompt lists. Created before the preset system (0.3.0), causing Claude to skip the Q2 model preset question in the Step 3 AskUserQuestion batch.
- `cycle/SKILL.md` Step 3 now asserts "EXACTLY 4 questions - do not omit Q2" to prevent description-priming from silently dropping the model preset question even when descriptions are accurate.

## [0.3.1] - 2026-05-11

### Added

- **Worktrees always project-local** -- `using-git-worktrees` skill drops the global `~/.config/superpowers/worktrees/<project>/` option. Worktrees must live inside the repo root for sandbox and tooling access. Multi-repo setups: each repo anchors to its own root via `git rev-parse --show-toplevel`. `.worktrees/` added to `.gitignore`.
- **VERIFY step 0: unresolved marker scan** (ported from GSD v1.41.2) -- before dispatching verifier or code-reviewer agents, VERIFY scans changed source files for `TBD`/`FIXME`/`XXX` markers and fails immediately if any are found. Prevents agent budget from being spent on incomplete implementations.
- **EXECUTE stall detection** (ported from GSD v1.41.2) -- EXECUTE resume now distinguishes three states for in-flight tasks: commits present (treat as done, run spec-compliance), partial dirty changes (re-dispatch with embedded diff as context), clean stall (fresh re-dispatch). Replaces the previous "commits exist = done" heuristic which could skip spec-compliance on crashed agents.
- **EXECUTE orphaned worktree pruning** (ported from GSD v1.41.0) -- after all waves complete and before phase routing, EXECUTE prunes worktrees whose branches are already merged into the feature branch. Non-destructive: worktrees with uncommitted changes are skipped with a warning. Runs `git worktree prune` to clean stale metadata entries.

## [0.3.0] - 2026-05-11

### Added
- **Model preset system**  -  5 model presets (opus, quality, balanced, fast, economy) independent of tier. Preset controls which model each agent role uses; tier controls gate behavior. New file: `skills/shared/preset-matrix.md`.
- `LOOP_SPEC_ANSWER_PRESET` env var for non-interactive CI runs. Default: `balanced`.
- `docs/tier-guide.md` rewritten to document tier vs preset as separate dimensions, with combo table and warnings.

### Changed
- `state.json` schema bumped to **v2**  -  adds `preset` field. v1 states auto-migrate to `preset: balanced` on resume (persisted to disk).
- `skills/shared/tier-matrix.md` stripped of model assignments (now tier-policy only  -  gate behavior and severity thresholds).
- **S1** `cycle/SKILL.md` health-check: probes 3 unique model IDs in one parallel Agent batch instead of nested loop.
- **S2** `cycle/SKILL.md` Step 3: all 4 user questions (tier, preset, style, title) in a single AskUserQuestion call.
- **S5** `execute/SKILL.md`: spec-compliance-reviewer dispatched per-task immediately when implementer returns, not after wave barrier. Cuts wave wall-clock ~30%. Merge ordering unchanged (Step 2g still sequential in id order).
- **S6** `execute/SKILL.md`: worktree cleanup deferred to post-wave batch instead of per-task serial.
- **S7** `verify/SKILL.md`: verifier + code-reviewer dispatched in parallel. Happy-path saves full code-reviewer round-trip duration.
- **S8** `verify/SKILL.md`: map-codebase incremental refresh runs in parallel with conditional pre-push test command.
- **S9** `verify/SKILL.md` + `agents/loop-spec-verifier.md`: verifier is now the authoritative test runner; orchestrator no longer re-runs test suite after verifier returns. Saves one full test-suite execution per cycle.
- All phase skills (`discuss`, `plan`, `execute`, `verify`, `map-codebase`) updated to use `preset_matrix[role][state.preset]` instead of `tier_matrix[role][state.tier]`.

## [0.2.1] - 2026-05-06

### Fixed
- Renamed every "adversarial review" / "attack" reference to "critique gate" / "critique" across agents, skills, docs, and README. The advocate/challenger pair previously tripped the Anthropic safety filter when CC auto-generated tool-use task summaries containing words like "Challenger attack SPEC", aborting the dispatch with a usage-policy refusal.
- Discuss + plan dispatches now require an explicit `description:` field on every Agent call (`"Critique gate: defense of SPEC"`, `"Critique gate: critique of SPEC"`, etc.) so CC never auto-generates a charged summary.
- Renamed the gate enum strings: `adversarial-spec-review` -> `spec-critique`, `adversarial-plan-review` -> `plan-critique`. (No live state.json files in the wild yet, so no migration needed.)

## [0.2.0] - 2026-05-06

Hardening pass after the v0.1.x dogfood revealed skill-prose fragility.

### Added
- `lib/state-write.sh` - atomic state.json writer with `.bak` rotation, JSON validation, and idempotent rotation. 8 unit tests.
- `lib/git-ops.sh` - base-branch detection, kebab-case slugify, clean-tree check, current-sha. 10 unit tests.
- `lib/gsd-ingest.sh` - GSD `.planning/codebase/` and `.planning/phases/{slug}/PATTERNS.md` ingestion. 17 unit tests.
- `tests/lib/*.test.sh` - one suite per lib script (35 tests, all PASS).
- `tests/run-all.sh` - meta runner: validators + hook + lib units in one command (no claude CLI needed).
- Tool whitelist section in `skills/cycle/SKILL.md`. Lists exactly which tools the orchestrator + sub-skills may use (Agent, Bash, Read, Write, Edit, AskUserQuestion, Skill, Glob, Grep) and explicitly bans `SendMessage`, `TeamCreate`, `TaskCreate`, `EnterWorktree`, `WebFetch`, `CronCreate`, etc. Generalizes the v0.1.2 SendMessage fix to a structural guard.
- Provenance fields in feature state schema: `artifacts.patternsSource` (`gsd-ingest` / `pattern-mapper` / `manual` / `null`) and `artifacts.codebaseSource.{tech,arch,quality,concerns,domain}` (`gsd-ingest` / `mapper` / `manual` / `null`). Set by cycle Step 5.5 and PLAN Step 0.

### Changed
- Cycle Step 5 (init state) now invokes `lib/state-write.sh` and `lib/git-ops.sh slugify` instead of inline pseudocode.
- Cycle Step 5.5a + 5.5b call `lib/gsd-ingest.sh codebase` and update provenance via `lib/state-write.sh`. Inline bash blocks removed.
- Cycle Step 5.5c now produces at most two clean commits per first run (one for ingest, one for mapper) and never amends. Removes the fragile cross-skill amend coordination.
- PLAN Step 0a calls `lib/gsd-ingest.sh patterns` instead of inline ingest pseudocode. Sets `artifacts.patternsSource` accordingly.
- Pattern-mapper agent prompt trimmed ~30%. Same role boundary, less repetition.
- README rewritten to lead with the origin story (speed of superpowers + spec-driven of GSD = this) and document the new repo layout including `lib/` and `tests/run-all.sh`.

### Removed
- `.loop-spec/codebase/index.json` rebuild from Step 5.5a. The wishful "enumerate every file mentioned in backticks" prose is gone; the next incremental refresh (end of VERIFY) builds index.json from real file scans.

### Process
- Work done on `refactor/v0.2.0-hardening` branch and merged via PR rather than committed straight to main.

## [0.1.4] - 2026-05-06

### Added
- GSD interop in first-run codebase map. Cycle Step 5.5a now scans `.planning/codebase/` for an existing get-shit-done map and ingests it into loop-spec format before dispatching mappers:
  - `STACK.md` + `INTEGRATIONS.md` -> `TECH.md`
  - `ARCHITECTURE.md` + `STRUCTURE.md` -> `ARCH.md`
  - `CONVENTIONS.md` + `TESTING.md` -> `QUALITY.md`
  - `CONCERNS.md` -> `CONCERNS.md`
  - GSD has no DOMAIN analog, so `loop-spec-mapper-domain` always runs unless `DOMAIN.md` already exists.
  Step 5.5b only dispatches mappers for whatever's still missing after ingestion (via `--domain` filter).
- GSD interop in PLAN Step 0a. Pattern-mapper dispatch now first checks `.planning/phases/{slug}/PATTERNS.md` and `.planning/{slug}/PATTERNS.md`. If a matching GSD PATTERNS.md exists, it is ingested into `docs/loop-spec/features/{slug}/PATTERNS.md` and the pattern-mapper dispatch is skipped.

## [0.1.3] - 2026-05-06

### Added
- New `loop-spec-pattern-mapper` agent + PLAN Step 0. Before the planner runs, pattern-mapper reads SPEC.md, derives the concepts the feature needs, finds the closest existing analog for each in the codebase, and writes `docs/loop-spec/features/{slug}/PATTERNS.md` with imports / core pattern / error handling / test analog excerpts. The planner reads PATTERNS.md and cites analog paths in each task's Steps so implementers mirror house style. Modelled on `gsd-pattern-mapper` from get-shit-done.
- `skills/shared/artifact-templates/PATTERNS.md.template` -- per-concept template.
- First-run codebase map auto-runs once per project. `cycle` Step 5.5 checks for `docs/loop-spec/codebase/{TECH,ARCH,QUALITY,CONCERNS,DOMAIN}.md`; if any are missing it invokes `Skill(loop-spec:map-codebase) --full` before entering DISCUSS. Aborts the cycle if the map still is incomplete after the skill returns. Modelled on `gsd-codebase-mapper` first-run behaviour from get-shit-done.
- `pattern-mapper` row added to `skills/shared/tier-matrix.md` (opus/sonnet/haiku across quality/balanced/quick).
- `state.artifacts.patterns` field added to feature state schema (v1).
- PreToolUse hook accepts `loop-spec-pattern-mapper` (allowed under `docs/loop-spec/features/**`); fixture + 2 test cases (K, L). Total: 12/12 PASS.
- `validate-agents.sh` expected-count bumped to 14.

## [0.1.2] - 2026-05-06

### Fixed
- Phase skills (discuss, plan, execute) and the cycle orchestrator now state explicitly that "re-dispatch" means a fresh `Agent` tool call with the new context embedded in the prompt, NOT `SendMessage` to a returned subagent. Previously the model would sometimes reach for `SendMessage` (which then failed validation because `summary` was missing) when retrying a failed gate. Added a top-level "Dispatch convention" section in `skills/cycle/SKILL.md` and inline notes at every `re-dispatch` mention in `discuss/plan/execute`.

## [0.1.1] - 2026-05-06

### Added
- Slash commands mirror skills 1:1: `/loop-spec:cycle`, `/loop-spec:discuss`, `/loop-spec:plan`, `/loop-spec:execute`, `/loop-spec:verify`, `/loop-spec:map-codebase`.

### Changed
- Install commands now use SSH (`git@github.com:aztechead/loop-spec.git`) for repos behind SSO (URL since rehosted).

## [0.1.0] - 2026-05-05

### Added
- Initial release. 4-phase spec-driven workflow (DISCUSS → PLAN → EXECUTE → VERIFY).
- 13 specialized agent definitions.
- 5-domain incremental codebase mapping.
- 3-tier asymmetric model selection (quality/balanced/quick).
- 4 execution styles (auto/step/interactive/review-only).
- AUTO self-heal loop with bounded retries (3 per gate, 30 global).
- Per-task git worktrees for parallel execution.
- PreToolUse path-glob enforcement hook.
- tests/smoke.sh zero-dep bash runner.
