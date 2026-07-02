---
ambiguity_scores:
  goal_clarity: 0.85
  boundary_clarity: 0.80
  constraint_clarity: 0.80
  acceptance_clarity: 0.80
  ambiguity: 0.19
  rounds_completed: 0
  gate_passed: true
  unresolved_dimensions: []
---

# v2.6 capabilities: greenfield, debug, autonomous

Original goal (verbatim): extend loop-spec beyond feature development in existing
projects while sticking with the grounded archetypes of spec-driven development
with loops, aiming for simplicity (ponytail):

1. Net new application development
2. Debugging a specific error
3. Debugging a non-specific error
4. Working from only the command line without any human-in-the-loop questions —
   where Claude would normally prompt, take the model's recommended / best-guess
   answer based on best principles and practices.

<decisions>
Decisions below were made autonomously per the goal's own capability 4 (no
human-in-the-loop; recommended answer per best practice), each with rationale.

- **Autonomous mode is an orthogonal flag, not a fifth execution style.**
  Trigger: inline token `autonomous` anywhere in the invocation text, or
  `LOOP_SPEC_AUTONOMOUS=1`. It forces style `auto` and layers one rule over
  every AskUserQuestion site: self-answer with the recommended option, record
  the decision. Rationale: styles govern pause frequency; question-answering is
  a separate axis. A shared contract doc keeps it one concept instead of N
  style-table rows. Explicit `LOOP_SPEC_ANSWER_*` env vars still win over a
  self-answer (CI stays deterministic).
- **Greenfield lives inside the cycle, not a separate skill.** Trigger: cycle
  invoked in a non-repo directory (Step 0 `mode == "none"`), or the inline
  token `new`. Rationale: SPEC → DISCUSS → PLAN → EXECUTE → VERIFY → ITERATE is
  exactly the right shape for a new app; only the grounding inputs (graph, map,
  detected commands) are absent, so those steps get a greenfield branch instead
  of duplicating the orchestrator.
- **One debug skill covers both specific and non-specific errors.** A triage
  phase runs only when the input lacks a concrete signal (error text, stack,
  failing test, repro command). Rationale: after triage converges on a specific
  reproducible symptom the two paths are identical; two skills would duplicate
  the reproduce/fix/verify loop.
- **The failing reproduction is the debug oracle.** No fix is attempted before
  a red repro exists (or, when a red repro is genuinely unattainable, an
  explicitly recorded observation plan). Rationale: same maker≠checker
  principle as the cycle — a fix scored against the symptom that produced it,
  not against the fixer's opinion.
- **No new bash libs, no new agents.** All three capabilities are markdown
  skill logic over the existing lib/ + agent surface (ponytail: reuse before
  build). The only shell change is a 3-line suppression in grill-inject.sh.
- **(User, mid-review) Autonomous runs manage all iteration cycles themselves;
  warnings are audit-only.** Realized as the continuation ladder in
  `skills/shared/autonomous-mode.md`: in-phase self-heal → lead-authored
  artifact fallback → hands-off rewinds → backlog + bounded drain chaining at
  the limit → terminal on a second spent budget for the same gap.
- **(User, mid-review) The backlog is exclusively the iteration-limit exit, in
  BOTH modes.** While iterations remain, every ITERATE gap is worked by a
  rewind — never deferred to `BACKLOG.md`. Only when `maxIterations` is hit do
  accepted gaps queue to the backlog (and, autonomous only, chain into drain).
</decisions>

## Requirements

### R1 — Autonomous mode

- **Statement:** With the inline token `autonomous` (or `LOOP_SPEC_AUTONOMOUS=1`),
  a full cycle runs end-to-end with zero AskUserQuestion calls; every point that
  would have asked instead takes the model's recommended answer and records it.
- **Current state:** `LOOP_SPEC_NON_INTERACTIVE=1` skips questions but aborts or
  falls to fixed defaults when a `LOOP_SPEC_ANSWER_*` var is unset; SPEC
  synthesizes thinly instead of self-interviewing; grill mode still injects a
  question directive at session start.
- **Target state:** `skills/shared/autonomous-mode.md` defines the contract
  (trigger, self-answer rule, decision recording); cycle/spec/discuss/verify/
  iterate question sites reference it; SPEC runs its 6-perspective interview in
  self-answered form (the model asks AND answers each round, grounded in the
  code graph, scoring honestly); grill injection is suppressed; every assumed
  answer lands in the `## Decisions (assumed — autonomous)` record inside
  SPEC.md's `<decisions>` block and in PLAN.md's `## User decisions (already
  made)` record marked `(assumed)`.
- **Acceptance:**
  - [ ] `skills/shared/autonomous-mode.md` exists and is referenced by
        cycle, spec, discuss, verify, and iterate SKILL.md files.
  - [ ] cycle Step 3 parses and strips the `autonomous` token (like `style:`)
        and persists `autonomous: true` in feature.json.
  - [ ] spec SKILL.md has an autonomous interview mode distinct from the thin
        non-interactive synthesis (self-answered rounds, decisions recorded).
  - [ ] `grep -n "LOOP_SPEC_AUTONOMOUS" hooks/team/grill-inject.sh` shows the
        suppression; hook still fails open.

### R2 — Greenfield (net-new application) mode

- **Statement:** `/loop-spec:cycle new <description>` in an empty or non-repo
  directory bootstraps a repo and runs the full cycle to a working application;
  in an existing repo `new` scaffolds into a subdirectory only if explicitly
  pathed, otherwise refuses (existing-repo work is the normal cycle).
- **Current state:** Step 0 aborts (`mode == "none"`); graphify build, codebase
  map, and command detection all assume existing code.
- **Target state:** Step 0 gains a greenfield branch (`git init` + empty initial
  commit + `greenfield: true`); Step 4 skips detection and derives commands from
  the SPEC's chosen stack (recorded, then verified after scaffold); Step 5.4
  defers the graph build until after the first EXECUTE wave commits source;
  Step 5.5 skips the map (VERIFY's refresh writes the first one); SPEC round 1
  swaps Researcher for a Foundations perspective (stack, structure, tooling —
  autonomous mode picks the boring industry-standard stack); PLAN must emit
  task-001 = scaffold + test harness with every later task blocked on it, and
  EXECUTE backfills `feature.commands.*` from the scaffold.
- **Acceptance:**
  - [ ] cycle SKILL.md Step 0 documents the greenfield branch and no longer
        unconditionally aborts on `mode == "none"`.
  - [ ] spec SKILL.md contains the Foundations perspective for greenfield.
  - [ ] plan SKILL.md contains the scaffold-first task rule.
  - [ ] Steps 4 / 5.4 / 5.5 each carry an explicit greenfield branch.

### R3 — Debug skill (specific + non-specific)

- **Statement:** `/loop-spec:debug <error text | stack | failing test | vague
  symptom>` runs TRIAGE (non-specific only) → REPRODUCE → FIX loop → VERIFY and
  lands a committed fix with a regression test, or escalates with evidence.
- **Current state:** No debugging entry point; forensics diagnoses loop-spec's
  own workflow state only; assess ranks fragility but fixes nothing.
- **Target state:** `skills/debug/SKILL.md`, main-thread, bounded (max 5
  hypotheses, max 3 fix attempts per hypothesis), graph-grounded hypothesis
  formation, red-repro hard gate before any fix, full-suite + test-tamper-scan
  verification, artifact `docs/loop-spec/debug/{slug}/BUG.md` (symptom,
  evidence, hypothesis log with verdicts, fix, regression test). Non-specific
  input triggers triage first: gather evidence (test suite run, recent git
  history, fragility hotspots, logs the user names), converge on ONE specific
  reproducible symptom, then continue on the specific path. Escalation: a fix
  needing feature-scale change hands off to `/loop-spec:cycle` with BUG.md as
  the spec draft. Honors autonomous mode and the styles.
- **Acceptance:**
  - [ ] `skills/debug/SKILL.md` exists with frontmatter (name, description).
  - [ ] Red-repro gate present ("no fix before failing repro" stated as a hard
        gate) with the recorded-observation fallback for unreproducible bugs.
  - [ ] Bounded loop budgets stated (hypotheses, attempts) — never unbounded.
  - [ ] README skills list includes `/loop-spec:debug`.

### R4 — Docs + release

- **Statement:** README, CHANGELOG, plugin.json (2.6.0), docs/design.md reflect
  the three capabilities; `bash tests/run-all.sh` stays green.
- **Acceptance:**
  - [ ] `jq -r .version .claude-plugin/plugin.json` → `2.6.0`.
  - [ ] `bash tests/run-all.sh` → 0 failures.

### R5 — Intake (anything → SPEC → cycle) *(added this round by the user)*

- **Statement:** `/loop-spec:intake <file | pasted text>` converts any non-spec input
  (Slack message, Jira ticket, email, txt file, prompt) into a spec draft and kicks
  off the cycle from it.
- **Current state:** the cycle accepts pre-authored spec `.md` files (spec-file
  ingest) but nothing converts unstructured sources into that shape.
- **Target state:** `skills/intake/SKILL.md` — acquire source (file or pasted text;
  already-spec-shaped input skips conversion), extract faithfully into the spec
  skeleton (**restructure, never invent**: requirements traceable to source, settled
  decisions → `<decisions>` block, open questions listed but never answered), write
  `.loop-spec/intake/{slug}.md` with a verbatim `## Source` provenance block, hand to
  `Skill(loop-spec:cycle)` via the spec-file branch with inline tokens
  (`autonomous`/`new`/`style:`) passed through. `--no-run` stops after the draft.
  Offline: no URL fetching — sources arrive as text.
- **Acceptance:**
  - [ ] `skills/intake/SKILL.md` exists with frontmatter; fidelity rule stated.
  - [ ] cycle Step 3 branch 3 names the intake handoff and strips the new tokens.
  - [ ] README skills list includes `/loop-spec:intake`.

## Boundaries (what NOT to do)

- **In scope:** the three capabilities above, their docs, and minimal test
  touch-ups.
- **Out of scope:**
  - New agents, new bash libs, new hooks (except the 3-line grill suppression).
    Reuse `detect-test-cmd.sh`, `fragility-scan.sh`, `test-tamper-scan.sh`,
    `git-ops.sh` as-is.
  - Workspace-mode greenfield (multi-repo bootstrap) — defer; greenfield is
    single-repo v1, refused with a clear message in workspace mode.
  - A persistent debug team — debug is main-thread + at most one-shot subagents,
    matching its typically narrow scope (ponytail).
  - Changing the four execution styles or the fixed gates/budgets/model map.
  - Restructuring tested skill content beyond the additive branches above
    (CLAUDE.md: skills are code).

### Good Enough

- All R1–R4 acceptance boxes check.
- An autonomous invocation is describable in one line:
  `claude -p "/loop-spec:cycle autonomous <desc>"`.

### Exceptional (not required)

- Scripted headless e2e for autonomous mode (repo has no scripted e2e today).
- Debug-loop integration with loop-runner fleet for parallel hypothesis testing.
