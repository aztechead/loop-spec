# loop-spec - Spec-Driven Development Plugin

**Date:** 2026-05-05
**Status:** Design approved, planning next
**Author:** Christopher Bobrowitz
**Repo (target):** `github.com/aztechead/loop-spec`

## Problem

Claude Code subagents spawned by the superpowers fork have no spec-driven discipline. Each spawned implementer/reviewer relies on inline prompt templates, produces no durable per-task artifact, and the orchestrator cannot resume across sessions or audit what each agent decided. GSD (`gsd-build/get-shit-done`) solves this with 6 phases and 30+ specialized subagent types but is too heavy for everyday use and not under the user's control.

## Goals

- Fork-native, zero-dep spec-driven development plugin
- Three speed/quality tiers with asymmetric model selection
- Per-feature persistent artifacts that survive context clears
- Real `.claude/agents/` definitions instead of inline prompt templates
- Self-healing AUTO loop with bounded retries
- Codebase mapping that auto-refreshes after each cycle
- (v2.6) Full development surface on the same archetypes: greenfield mode (net-new
  application bootstrap inside the cycle — Foundations SPEC round, scaffold-first plan,
  deferred graph/map), `/loop-spec:debug` (bounded triage → red-repro → fix → verify loop,
  BUG.md artifact), and autonomous mode (question-free headless runs; self-answer contract
  in `skills/shared/autonomous-mode.md`, assumed decisions recorded through the
  decision-coverage gate)

## Non-goals

- Multi-tenant collaboration (single dev only)
- Non-CC harness support (Codex/Cursor/Gemini deferred)
- Adoption by upstream `obra/superpowers` (zero-dep + skill-restructure rules block it)
- Migration tooling from existing superpowers workflow (greenfield)

## Constraints

- Zero external dependencies (markdown + CC tooling only)
- Plugin must work standalone, no coupling to superpowers fork
- Model policy: opus -> `claude-opus-4-7`, sonnet -> `claude-sonnet-4-6` (1M ctx), haiku -> `claude-haiku-4-5`
  - **Note:** consuming projects whose `CLAUDE.md` hard-codes earlier model IDs (e.g., chrisbobrowitz/superpowers fork's policy banning anything other than 4.6/4.5) must update their policy section before adopting loop-spec. Plugin's `cycle` startup health-check verifies model availability via tiny test dispatches (1-token completion against each tier's models); failure prints diagnostic + which model failed + suggested CLAUDE.md edit, then aborts. No silent fallback.
  - 1M-context flag: cycle skill probes a sonnet dispatch with a >200k-token noop input; if rejected, falls back to standard sonnet 4.6 (200k) with a warning logged in `state.json.warnings[]`. Plan/Execute phases still run, just lose room for very large planner contexts.
- Skill content tested manually + `tests/smoke.sh` zero-dep bash runner for one cell of the matrix

## Success criteria

- A user can run `Skill(loop-spec:cycle)` on any project, pick tier+style, and ship a feature end-to-end with all 4 artifacts written and a PR opened
- AUTO style self-heals 3 retries per gate, 12 total per feature, then escalates
- Resume after context clear lands in correct phase with task graph intact
- Map-codebase auto-refreshes only stale domains after each cycle
- 36-cell smoke matrix (3 features x 3 tiers x 4 styles) runs without crashes before tagging v0.1.0

---

## Architecture overview

### Plugin layout

```
loop-spec/
├── .claude-plugin/
│   ├── plugin.json                     # name: "loop-spec", version: 0.1.0
│   └── marketplace.json                # solo plugin
├── .gitignore                          # .loop-spec/, common
├── LICENSE
├── README.md
├── CHANGELOG.md
├── CLAUDE.md                           # contributor guide
├── agents/                             # 13 agent defs
│   ├── loop-spec-spec-writer.md
│   ├── loop-spec-planner.md
│   ├── loop-spec-implementer.md
│   ├── loop-spec-spec-compliance-reviewer.md
│   ├── loop-spec-verifier.md
│   ├── loop-spec-code-reviewer.md
│   ├── loop-spec-advocate.md
│   ├── loop-spec-challenger.md
│   ├── loop-spec-mapper-tech.md
│   ├── loop-spec-mapper-arch.md
│   ├── loop-spec-mapper-quality.md
│   ├── loop-spec-mapper-concerns.md
│   └── loop-spec-mapper-domain.md
├── skills/
│   ├── cycle/                          # orchestrator
│   ├── discuss/
│   ├── plan/
│   ├── execute/
│   ├── verify/
│   ├── map-codebase/
│   └── shared/
│       ├── tier-matrix.md
│       ├── feature-state-schema.md
│       ├── model-policy.md
│       └── artifact-templates/
│           ├── SPEC.md.template
│           ├── PLAN.md.template
│           ├── EXECUTION.md.template
│           └── VERIFICATION.md.template
├── docs/
│   ├── design.md
│   ├── tier-guide.md
│   └── adopting.md
├── hooks/
│   └── restrict-agent-paths.sh         # PreToolUse path-glob enforcement
└── tests/
    ├── README.md                       # 36-cell smoke matrix
    ├── smoke.sh                        # zero-dep bash runner, one cell
    └── fixtures/                       # tiny project for smoke.sh to drive
```

### Per-feature artifact tree (in consuming project)

```
docs/loop-spec/features/{slug}/        # COMMITTED
├── SPEC.md
├── PLAN.md
└── VERIFICATION.md

docs/loop-spec/codebase/                # COMMITTED, auto-refreshed
├── TECH.md
├── ARCH.md
├── QUALITY.md
├── CONCERNS.md
└── DOMAIN.md

.loop-spec/                             # GITIGNORED
├── features/{slug}/
│   ├── state.json
│   ├── state.json.bak                   # last-good copy for crash recovery
│   ├── EXECUTION.md
│   └── tasks/                           # adaptive: only when wave > 3 tasks
│       ├── task-001.spec.md
│       ├── task-001.verify.md
│       └── ...
├── worktrees/{slug}/                    # per-task git worktrees, lifecycle = wave
│   ├── task-001/
│   ├── task-002/
│   └── ...
└── codebase/
    └── index.json                       # file -> domain[] for incremental map
```

### Top-level flow

```
User -> Skill(loop-spec:cycle)
         ├─ asks tier (quality | balanced | quick)
         ├─ asks exec style (auto | step | interactive | review-only)
         ├─ writes feature slug + state.json
         ├─ invokes loop-spec:discuss   -> SPEC.md committed
         ├─ invokes loop-spec:plan      -> PLAN.md committed
         ├─ invokes loop-spec:execute   -> EXECUTION.md (gitignored) + per-task commits
         └─ invokes loop-spec:verify    -> VERIFICATION.md committed + map refresh + PR opened

Each phase skill:
  - reads state.json -> knows tier
  - dispatches subagents from agents/ dir with model = tier-matrix[role][tier]
  - HARD-GATE on critique-gate / code review findings
  - writes phase artifact + updates state.json atomically
  - returns control to loop-spec:cycle
```

---

## Tier matrix

Asymmetric. Reviewers stay heavy on quality + balanced. Quick drops everything one tier.

| Role | quality | balanced | quick |
|------|---------|----------|-------|
| spec-writer | opus | opus | sonnet |
| planner | opus | opus | sonnet |
| implementer | opus | sonnet | sonnet |
| spec-compliance-reviewer | opus | opus | sonnet |
| verifier | opus | opus | sonnet |
| code-reviewer | opus | opus | sonnet |
| advocate | opus | opus | _SKIPPED on QUICK_ |
| challenger | opus | opus | _SKIPPED on QUICK_ |
| mapper-* (all 5) | opus | sonnet | haiku |

**QUICK tier skips critique gate entirely.** The critique gate exists only for BALANCED + QUALITY. QUICK relies on spec-compliance + acceptance gates during EXECUTE/VERIFY (which still run). This trades safety for ~12-20 fewer sequential model calls per feature, matching QUICK's "speed over scrutiny" intent. QUALITY/BALANCED keep the critique gate as the cheapest insurance against bad specs/plans.

Resolution:
- opus -> `claude-opus-4-7`
- sonnet -> `claude-sonnet-4-6` (1M ctx flag)
- haiku -> `claude-haiku-4-5`

Phase skill computes model at dispatch:
```
model = tier_matrix[role][state.tier]
Agent({subagent_type: "loop-spec-implementer", model: model, prompt: ...})
```

Estimated cost per 5-task feature on BALANCED ~= 270k tokens. QUALITY ~= 2x. QUICK ~= 0.4x. Cycle skill prints estimate before EXECUTE; STEP/INTERACTIVE pause for confirmation.

---

## Agent catalog

13 agent definitions in `agents/`. Each declares tool restrictions to prevent role drift.

| Agent | Purpose | Tools |
|-------|---------|-------|
| `loop-spec-spec-writer` | Produces SPEC.md from discuss conversation | Read, Write (specs only), Grep, Glob |
| `loop-spec-planner` | Produces PLAN.md (task DAG, files, verify cmds) | Read, Write (specs only), Grep, Glob, Bash (read-only) |
| `loop-spec-implementer` | Implements one task per dispatch | Read, Edit, Write, Bash, Grep, Glob |
| `loop-spec-spec-compliance-reviewer` | Checks impl matches per-task spec | Read, Bash (read-only), Grep, Glob |
| `loop-spec-verifier` | Runs acceptance criteria, writes VERIFICATION.md | Read, Bash, Grep, Glob, Write (specs only) |
| `loop-spec-code-reviewer` | Quality + security pass on diff | Read, Bash (read-only), Grep, Glob |
| `loop-spec-advocate` | Defends spec/plan in critique gate | Read |
| `loop-spec-challenger` | Critiques spec/plan in critique gate | Read |
| `loop-spec-mapper-tech` | Maps languages, frameworks, deps | Read, Grep, Glob, Bash (read-only), Write (codebase only) |
| `loop-spec-mapper-arch` | Maps modules, boundaries, data flow | Read, Grep, Glob, Bash (read-only), Write (codebase only) |
| `loop-spec-mapper-quality` | Maps test coverage, lint state, type safety | Read, Grep, Glob, Bash (read-only), Write (codebase only) |
| `loop-spec-mapper-concerns` | Maps security, perf hotspots, tech debt | Read, Grep, Glob, Bash (read-only), Write (codebase only) |
| `loop-spec-mapper-domain` | Maps business concepts, glossary, entities | Read, Grep, Glob, Write (codebase only) |

**Tool restriction format:** CC agent frontmatter supports a `tools` allow/deny list (which tools the agent can use), NOT per-glob path scoping. Path-level enforcement uses a different mechanism:

| Mechanism | Used for |
|-----------|----------|
| Agent def `tools:` allow-list | Coarse: which tools an agent can call at all (e.g., reviewer agents have no `Write`/`Edit` in their list) |
| Plugin `hooks/PreToolUse` matcher | Fine: validate `Write`/`Edit` arg paths match allowed glob; abort tool call if not |
| Prompt discipline | Soft: reinforce in agent prompt body |

**Concrete rules:**
- Reviewer agents (`spec-compliance-reviewer`, `code-reviewer`, `advocate`, `challenger`): `tools` list excludes `Write` and `Edit` entirely. Hard guarantee.
- `spec-writer` and `planner`: `tools` includes `Write`, but plugin's PreToolUse hook (`hooks/restrict-spec-writer-paths.sh`) blocks any `Write`/`Edit` whose `file_path` is outside `docs/loop-spec/features/**`.
- `mapper-*`: same hook gates `Write` to `docs/loop-spec/codebase/**`.
- `implementer` and `verifier`: full `Write`/`Edit`/`Bash` (must write code + test files anywhere).

The PreToolUse hook is shipped in the plugin under `hooks/restrict-agent-paths.sh` and registered in `plugin.json`. Risk #6 updated accordingly: enforcement is empirically verifiable (hook runs in CC harness, easy to test).

---

## state.json schema

```json
{
  "schemaVersion": 1,
  "slug": "spec-driven-cycle-mvp",
  "createdAt": "2026-05-05T14:00:00Z",
  "updatedAt": "2026-05-05T15:32:00Z",
  "tier": "balanced",
  "execStyle": "auto",
  "currentPhase": "execute",
  "completedPhases": ["discuss", "plan"],
  "artifacts": {
    "spec": "docs/loop-spec/features/spec-driven-cycle-mvp/SPEC.md",
    "plan": "docs/loop-spec/features/spec-driven-cycle-mvp/PLAN.md",
    "execution": ".loop-spec/features/spec-driven-cycle-mvp/EXECUTION.md",
    "verification": null
  },
  "branch": "feat/spec-driven-cycle-mvp",
  "baseSha": "bbf9a3c...",
  "tasks": [
    {
      "id": "task-001",
      "subject": "Add agents/ dir scaffolding",
      "status": "completed",
      "blockedBy": [],
      "files": ["agents/loop-spec-spec-writer.md"],
      "verifyCommand": "test -f agents/loop-spec-spec-writer.md",
      "acceptanceCriteria": ["File exists", "Frontmatter valid"],
      "wave": 1,
      "commitSha": "abc123",
      "retries": 0,
      "specPath": null,
      "verifyPath": null
    }
  ],
  "waves": [
    {"wave": 1, "taskIds": ["task-001", "task-002"], "status": "completed"},
    {"wave": 2, "taskIds": ["task-003"], "status": "in_progress"}
  ],
  "gateHistory": [
    {
      "phase": "discuss",
      "gate": "spec-critique",
      "attempt": 1,
      "result": "pass",
      "advocateModel": "claude-opus-4-7",
      "challengerModel": "claude-opus-4-7",
      "findingsAddressed": ["..."]
    }
  ],
  "commands": {
    "test": "npm test",
    "lint": "npm run lint",
    "typecheck": "npm run typecheck"
  },
  "stalenessHours": 48
}
```

Atomic write pattern: write to `state.json.tmp`, fsync, rename. Keep last-good `state.json.bak`. Resume restores from bak on parse failure.

`commands.{test,lint,typecheck}` populated at DISCUSS phase by inspecting project (package.json scripts, Makefile, pyproject.toml, etc.). User can override at start. Verify phase reads these for "ensure tests pass" gate.

`stalenessHours` defaults to 48 (matches superpowers `workflow-checkpoint` convention). Resume prompt only fires for state files updated within window.

---

## Phase walkthroughs

### DISCUSS (`loop-spec:discuss`)

```
1. Orchestrator collects feature title -> derives slug
2. Asks tier + exec style, writes initial state.json (currentPhase: "discuss")
3. Conversational clarifying loop with user (one Q at a time)
   - Non-AUTO styles: full conversation in main thread
   - AUTO: <=5 Q rounds then proceeds
4. Dispatch loop-spec-spec-writer (model per tier)
   - Input: conversation transcript, project context
   - Output: SPEC.md draft committed to docs/loop-spec/features/{slug}/
5. GATE: Spec critique gate
   - Dispatch loop-spec-advocate + loop-spec-challenger in parallel
   - Both read SPEC.md, write structured findings
   - Orchestrator reconciles -> fix list
   - Non-empty fix list -> re-dispatch spec-writer with fixes -> re-review
   - Per-gate retry counter; cap 3 -> escalate human
6. On gate pass: append to completedPhases, set currentPhase="plan"
   - Commit: "spec: NO_JIRA {slug}"
7. AUTO/REVIEW-ONLY -> invoke loop-spec:plan
   STEP/INTERACTIVE -> return to user, await /loop-spec next
```

### PLAN (`loop-spec:plan`)

```
1. Read SPEC.md + state.json
2. Read docs/loop-spec/codebase/*.md if present (gives planner architecture context)
3. Dispatch loop-spec-planner (model per tier)
   - Output: PLAN.md with task DAG (numbered, blockedBy, files, verify cmds, acceptance criteria, est scope, wave assignment)
   - TDD ordering enforced for code tasks; non-code tasks excluded
4. Planner writes tasks[] + waves[] into state.json
5. GATE: Plan critique gate (advocate + challenger)
   - Challenger checks: task atomicity, missing deps, untestable acceptance criteria, file-overlap conflicts
6. GATE: Plan-feasibility check
   - All task verifyCommands syntactically runnable
   - Task DAG acyclic
   - Each task >=1 acceptance criterion
   - Failure -> bounce to planner with fix list
7. Both gates pass -> commit "plan: NO_JIRA {slug}", set currentPhase="execute"
8. Phase routing per exec style
```

### EXECUTE (`loop-spec:execute`)

> **Concurrency ladder (v3.1.0).** The wave pseudocode below describes the per-task
> implement -> review -> ff-merge contract, which is unchanged. What changed is *which
> orchestration mechanism* runs it: EXECUTE Step 3 computes the DAG width `W`
> (`lib/dag-width.sh`) and picks the lightest mechanism that fits -- `W == 1` runs a
> single subagent sequentially, `2 <= W < t_team` fans out batched one-shot `Agent`
> waves (no team), `t_team <= W < t_wf` runs the self-claim agent team, and `W >= t_wf`
> escalates to the `execute-dag.js` Workflow only on explicit opt-in
> (`LOOP_SPEC_EXECUTE_WORKFLOW=1`). Thresholds live in `skills/shared/tier-matrix.md`;
> the subagent rung is documented in `skills/shared/execute-subagent.md`. All rungs
> return the same `{merged, blocked, escalation}` result.

```
1. Read PLAN.md + state.tasks + state.waves
2. Branch check: if not on feature branch, create feat/{slug} from main
3. Wave loop:
   for wave in state.waves where status != "completed":
     a. Wave concurrency = min(|wave.tasks|, 5)
     b. Pre-wave file-conflict check:
        - Compute files_union across wave.tasks
        - If duplicates: demote conflicting tasks to next wave
        - Update state.waves
     c. If wave.tasks.length > 3: generate per-task spec files
     d. Dispatch implementers in parallel - EACH IN ITS OWN GIT WORKTREE:
        for task in wave.tasks:
          - Create worktree at .loop-spec/worktrees/{slug}/task-NNN/ off feat/{slug}
          - Set task.status = "dispatching" -> atomic state write
          - model = tier_matrix.implementer[tier]
          - prompt: full task spec, working dir = worktree path, "Commit your work to this worktree's branch task/NNN-{slug}"
          - subagent_type = loop-spec-implementer
          - Set task.status = "running" -> atomic state write
     e. As each implementer returns:
        - Set task.status = "reviewing" -> atomic state write
        - Append implementer report to EXECUTION.md
        - Dispatch loop-spec-spec-compliance-reviewer pointed at that task's worktree
     f. GATE: Spec compliance per task
        - PASS -> set task.status = "merging" -> atomic state write
        - FAIL -> re-dispatch implementer in same worktree with findings, retry++, cap 3 per task
     g. Sequential merge step (after all wave tasks pass review):
        - For each task in wave order:
          - In feature branch (NOT worktree): `git merge --ff-only task/NNN-{slug}` (worktrees commit linearly)
          - If non-fast-forward: rebase worktree onto current feat/{slug} HEAD, retry merge
          - On merge: record task.commitSha, set task.status = "completed"
          - Remove worktree
     h. After all tasks in wave done, mark wave.status = "completed"
4. After all waves: set currentPhase="verify"
5. Phase routing per exec style
```

Notes:
- **Implementers DO commit** (in their own worktree). Orchestrator merges atomically into feature branch in sequence. This eliminates the working-tree race that would occur if implementers wrote to a shared tree.
- Worktrees are gitignored cleanup target; lifecycle bound to wave completion.
- Wave parallelism cap at 5 to avoid model rate limits AND to bound disk usage of N concurrent worktrees.
- INTERACTIVE style pauses before each implementer dispatch.
- Per-task `status` field uses fine-grained values (`pending` -> `dispatching` -> `running` -> `reviewing` -> `merging` -> `completed`) for crash recovery. Resume inspects each in-flight task: `running`/`reviewing` -> re-dispatch from prior step (worktree state is ground truth); `merging` -> resume merge attempt.

### VERIFY (`loop-spec:verify`)

```
1. Read SPEC.md acceptance criteria + PLAN.md task results + state.json
2. Dispatch loop-spec-verifier (model per tier)
   - Runs each acceptance criterion's verify command
   - Collects evidence (output, exit codes)
   - Writes VERIFICATION.md draft (PASS/FAIL/N/A per criterion)
3. GATE: Acceptance criteria
   - Any FAIL -> bounce to loop-spec:execute with failed criteria as new tasks
4. Dispatch loop-spec-code-reviewer (model per tier)
   - Reviews diff base..HEAD against PLAN.md + project conventions
   - Writes findings into VERIFICATION.md
5. GATE: Code review HARD-GATE
   - Critical/Important findings -> bounce to execute (one task per finding)
   - Minor -> logged, not blocking
   - QUICK tier prompt emphasizes "only flag critical, defer minor"
6. Map-codebase incremental update (auto)
   - Compute stale domains from git diff base..HEAD
   - Dispatch mapper-{domain} agents in parallel (only stale ones)
   - Each updates docs/loop-spec/codebase/{TOPIC}.md
   - Update .loop-spec/codebase/index.json
   - Commit: "docs: NO_JIRA refresh codebase mapping (feature: {slug})"
7. Branch finish
   - Ensure tests pass
   - Push branch
   - Open PR with body = SPEC.md summary + VERIFICATION.md acceptance table
8. Commit final VERIFICATION.md, set state.currentPhase="completed"
9. Print summary to user with PR URL
```

### Phase transitions

| Phase | Exits to | AUTO | STEP | INTERACTIVE | REVIEW-ONLY |
|-------|----------|------|------|-------------|-------------|
| DISCUSS -> PLAN | gate pass | auto | pause | pause | auto |
| PLAN -> EXECUTE | gate pass | auto | pause | pause | auto |
| EXECUTE -> VERIFY | all waves done | auto | pause | pause-per-task | auto |
| VERIFY -> done | gate pass | auto | pause | pause | auto |

**Pause mechanism:** all "pause" cells use `AskUserQuestion` with options `[Continue, Review artifact first, Abort]`. State persisted to `state.json` before pause so user can leave session and resume later. "Continue" routes to next phase skill. "Review artifact first" prints artifact path and re-prompts after user acks.

### Self-heal loop (AUTO)

Full-bore operation: gate retries are unbounded. The ONE limit the cycle respects is
ITERATE's round limit (`iterate.maxIterations`, fixed 10). Within EXECUTE, the per-task
rework cap (`maxRetriesPerTask`, fixed 2) routes a repeatedly-failing task to the lead
for escalation instead of ping-ponging it between the same implementer and reviewer.

```
Gate failure detected
  -> state.gateHistory[].attempt++   (every attempt is recorded; history, not a cap)
  -> bounce target phase = (gate's owning phase)
  -> build fix-list from gate findings
  -> re-dispatch the originating agent with fix-list
  -> re-run gate; repeat until it passes
```

**Bounce-creates-new-tasks rule:** when VERIFY's acceptance gate fails and bounces to EXECUTE with new remediation tasks, the new tasks each start with fresh `retries` (do NOT inherit the parent's), and every attempt lands in `gateHistory`.

---

## Map-codebase

### Roles (5 mappers)

- TECH: languages, frameworks, deps
- ARCH: modules, boundaries, data flow
- QUALITY: test coverage, lint state, type safety
- CONCERNS: security, perf hotspots, tech debt
- DOMAIN: business concepts, glossary, entity model

### Auto-update at end of VERIFY

```
verify phase complete
  -> read .loop-spec/codebase/index.json
  -> compute changedFiles = git diff base..HEAD --name-only
  -> staleDomains = unique(index[file] for file in changedFiles) U "arch" if new files added
  -> dispatch mapper-{domain} agents in parallel (only stale ones)
  -> each appends/updates its TOPIC.md section for the new feature
  -> update index.json with new file -> domain mappings
  -> commit: "docs: NO_JIRA refresh codebase mapping (feature: {slug})"
```

### Standalone (`Skill(loop-spec:map-codebase)`)

- `--full`: re-map all 5 domains
- `--domain tech,arch`: re-map subset
- Default: incremental scanning since last map commit

### Per-domain staleness tracking

`index.json` records last-refreshed timestamp per domain. Skill warns if domain unrefreshed in N cycles.

---

## Build plan (greenfield loop-spec repo)

### Repo

- Remote: `github.com/aztechead/loop-spec`
- Plugin name: `loop-spec`
- Initial version: `0.1.0`
- License: MIT
- Empty main -> first commit = scaffolding

### Build waves

```
Wave 1 - bare repo
  - git init, push to remote
  - LICENSE, README stub, .gitignore (.loop-spec/), CHANGELOG, CLAUDE.md
  - .claude-plugin/{plugin,marketplace}.json @ 0.1.0
  - Empty agents/ + skills/ dirs with .gitkeep
  Commit: "feat: NO_JIRA scaffold loop-spec plugin v0.1.0"

Wave 2 - shared infra
  - skills/shared/{tier-matrix, feature-state-schema, model-policy}.md
  - skills/shared/artifact-templates/*.template
  Commit: "feat: NO_JIRA shared specs (tier matrix, state schema, templates)"

Wave 3 - agent defs (parallel-able)
  - All 13 agents/*.md with role prompt, tool restrictions, default model
  Commit: "feat: NO_JIRA 13 agent definitions"

Wave 4 - phase skills (parallel-able, 5 commits)
  - skills/discuss/SKILL.md
  - skills/plan/SKILL.md
  - skills/execute/SKILL.md
  - skills/verify/SKILL.md
  - skills/map-codebase/SKILL.md

Wave 5 - orchestrator
  - skills/cycle/SKILL.md (entry, tier+style picker, state mgmt, phase routing, resume)
  Commit: "feat: NO_JIRA cycle orchestrator skill"

Wave 6 - docs
  - docs/{design, tier-guide, adopting}.md
  - README expanded with quickstart
  - CHANGELOG @ 0.1.0
  Commit: "docs: NO_JIRA initial documentation"

Wave 7 - dogfood
  - Use Skill(loop-spec:cycle) to ship a tiny feature in this same repo
    (e.g., loop-spec:status sub-skill that prints state.json summary)
  - This commit produces the first SPEC/PLAN/VERIFICATION trail in
    docs/loop-spec/features/{slug}/ inside loop-spec itself
  Tag: v0.1.0
```

### Plugin install (consumer side)

```json
{
  "marketplaces": {
    "loop-spec": "git+ssh://git@github.com/aztechead/loop-spec.git"
  }
}
```
Then `claude plugin install loop-spec@loop-spec-marketplace`.

### No coupling to existing fork

- Standalone plugin. Users can have both `superpowers-extended-cc` AND `loop-spec` installed.
- Skill namespacing prevents collision.

### Test surface

- `tests/README.md` defines smoke matrix:
  - 3 features (trivial 1-task, medium 5-task, complex 10-task with parallel waves)
  - 3 tiers (quality, balanced, quick)
  - 4 exec styles (auto, step, interactive, review-only)
  - = 36 cells. Run subset before each tag (full grid quarterly).
- `tests/smoke.sh` - bash-only runnable smoke (zero-dep, just bash + git + claude CLI):
  - Spins up temp dir, `git init`
  - Drops a fixture project (3-file Python module with stub tests)
  - Invokes `claude` with `Skill(loop-spec:cycle)` on QUICK + AUTO defaults
  - Asserts: SPEC.md / PLAN.md / VERIFICATION.md created, state.json reaches `currentPhase: completed`, exit code 0
  - One cell of the matrix, runnable by user OR pre-tag. Catches the 80% regressions.
  - All 36 cells documented in tests/README.md but not all scripted (cost/time prohibitive for full automation).

---

## Risks + mitigations

| # | Risk | Likelihood | Impact | Mitigation |
|---|------|------------|--------|------------|
| 1 | Agent dispatch model param resolution. CC harness may resolve `model: "opus"` to wrong version. | High | Med | Pass full model ID at dispatch where supported; tier-matrix.md stores full IDs. Document min CC version. |
| 2 | Sonnet 4.6 1M-context flag may need explicit beta flag. | High | Med | Probe at install time. cycle skill startup health-check. Fail loud. |
| 3 | Self-heal loop infinite-runs disguised as bounded. | Med | High | ITERATE round limit (`iterate.maxIterations`, 10) is the terminal bound; every gate attempt is recorded in `gateHistory` so thrash is visible, and human-in-loop styles can interrupt at any phase. |
| 4 | Wave parallelism causes file conflicts; planner promised disjoint files but was wrong. | Med | High | Pre-wave file-conflict check in EXECUTE step 3b. Demote conflicting tasks to next wave automatically. |
| 5 | Working-tree race: parallel implementers stomp each other's changes. | (resolved) | High | **Per-task git worktrees** (EXECUTE step 3d). Each implementer commits to its own worktree branch. Orchestrator does sequential `git merge --ff-only` into feature branch. Eliminates the race entirely. New cost: disk usage (capped at 5 worktrees per wave x project size). |
| 6 | Spec-writer / planner / mappers write outside designated dirs. | Low | Med | Plugin ships `hooks/restrict-agent-paths.sh` PreToolUse hook. Reviewer agents have no `Write`/`Edit` in their `tools:` allow-list at all. Hook enforcement empirically testable. |
| 7 | Critique-gate collusion (advocate + challenger same blind spot). | Med | Low | Challenger prompt explicitly told to find structural flaws. Smoke test with deliberately broken specs. |
| 8 | Map-codebase incremental drift. | Med | Med | Quarterly forced full re-map. Per-domain staleness timestamp in index.json. |
| 9 | State.json corruption mid-flow. | Low | High | Atomic write pattern. Last-good backup. Resume restores from bak on parse fail. |
| 10 | Resume across CC sessions loses conversation context. | High | Low | SPEC.md is durable conversation summary. Acceptable lossy. |
| 11 | Cost surprise on QUALITY tier. | Med | Med | cycle skill prints estimated cost before EXECUTE. STEP/INTERACTIVE pause for confirmation. |
| 12 | CC plugin agent loading semantics not stable. | Low | High | Pin minimum CC version. Fallback to inline prompt templates kept in skills/shared/agent-prompts/. |
| 13 | HARD-GATE on minor findings causes slog on QUICK tier. | High | Med | Tier modulates SEVERITY threshold in code-reviewer prompt, not gate strictness. |
| 14 | Solo plugin = bus factor 1. | High | Med | Document architecture thoroughly. Skills are markdown, readable by any human/AI. |
| 15 | Skill content not eval-tested at launch. | High | High | Wave 7 dogfood + `tests/smoke.sh` zero-dep bash runner exercising one matrix cell end-to-end. Treat 0.x versions as beta. Add post-launch eval matrix. |
| 16 | Sequential merge step (EXECUTE 3g) fails when worktree branches conflict despite pre-wave file check. | Med | Med | Pre-wave check covers explicit `files` overlap; cannot catch type/import deps. On merge failure: rebase task worktree onto current `feat/{slug}` HEAD, retry merge once. If still fails: pause + escalate (counts against `executePerTask`). |
| 17 | Cycle health-check at startup blocks every install on transient API hiccup. | Low | Med | Health-check retries 3x with 2s backoff before failing. Failure prints exact model + error so user can diagnose vs reload. |
| 18 | QUICK skipping critique gate ships bad specs unnoticed. | Med | Med | Documented trade-off in tier-guide.md. QUICK still has spec-compliance + acceptance gates; only skips PRE-impl spec/plan review. User who wants safety picks BALANCED. |

### Deferred (out of scope for v0.1.0)

- Multi-tenant collaboration
- Non-CC harness support
- Telemetry / cost dashboards

---

## Open questions

(none - all resolved during brainstorm)
