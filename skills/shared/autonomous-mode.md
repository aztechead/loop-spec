# Autonomous mode — the self-answer contract

Autonomous mode makes a run **question-free**: every point where loop-spec would
normally call `AskUserQuestion`, the orchestrator instead takes the answer it
would have recommended — the option grounded in the code graph, the codebase
map, and general best practice — records it as an assumed decision, and
proceeds. The preferred headless/SDK entry is `claude -p "/loop-spec:auto
<description>"`: the auto skill performs a grounded semantic decision and validates
it through `lib/task-route.sh` before delegating to micro, debug, or the full cycle.
An explicit `claude -p "/loop-spec:cycle autonomous <description>"` still means the
full seven-phase cycle with zero human input.

Under the pi harness the preferred entry is `pi --mode json "/skill:auto
<description>"` (or `pi -p ...`, or the pi SDK's `createAgentSession()` prompting the
same text). Under opencode it is `opencode run --format json "Load the loop-spec-auto
skill and run: <description>"` (or the `@opencode-ai/sdk`'s
`client.session.prompt()` against `opencode serve`, same text). The self-answer and
fail-closed routing contracts are identical; see `skills/shared/pi-harness.md` and
`skills/shared/opencode-harness.md`.

## Trigger and precedence

Autonomous mode is ON when either:

- the inline token `autonomous` appears anywhere in the invocation text
  (stripped from the title like `style:` tokens — cycle Step 3), or
- `LOOP_SPEC_AUTONOMOUS=1` is set in the environment.

Effects, in order of precedence:

1. **Explicit answers still win.** If a `LOOP_SPEC_ANSWER_*` / `LOOP_SPEC_CMD_*`
   env var covers the question, use it — autonomous never overrides an answer
   the operator pinned. Same for a prior decision already recorded in
   `.loop-spec/RULES.md` or the feature's decisions record (never re-decide).
2. **Style is forced to `auto`.** `step`/`interactive`/`review-only` tokens are
   ignored with a one-line notice (they exist to pause for a human; there is no
   human).
3. **Every remaining `AskUserQuestion` site self-answers** per the rule below.
4. **Grill mode is suppressed for the session** (`hooks/team/grill-inject.sh`
   checks `LOOP_SPEC_AUTONOMOUS`); the SPEC interview runs in self-answered
   one-pass form instead, and DISCUSS collapses to lead-authored refinement +
   the critique gate (`skills/discuss/SKILL.md`, Autonomous fast path).
5. **Retro auto-applies at completion.** `lib/retro.sh auto` promotes repeated-
   pattern rule candidates into `.loop-spec/RULES.md` without a human (kill
   switch `LOOP_SPEC_RETRO_AUTO_APPLY=0`). Safe by construction: the appliable
   texts are a closed template set with deterministic triggers that only ever
   tighten the loop — autonomous mode cannot author or weaken a rule, and the
   apply happens only at cycle completion, never mid-run.

Autonomous mode implies non-interactive semantics everywhere
`LOOP_SPEC_NON_INTERACTIVE=1` is honored, but is strictly stronger: where
non-interactive aborts or takes a fixed default on a missing `LOOP_SPEC_ANSWER_*`
var, autonomous derives the recommended answer itself. Persist the flag as
`feature.json.autonomous = true` (cycle Step 5, via `lib/feature-write.sh set`)
so phase skills and resumed sessions see it without re-parsing the invocation.

## The self-answer rule

At any point a skill would call `AskUserQuestion`, when autonomous:

1. **Formulate the question anyway** — it names the ambiguity being collapsed.
2. **Answer it as the options' author would recommend**: prefer the choice that
   is grounded in what the codebase already does (graph/map/PATTERNS evidence),
   then industry best practice, then the most reversible option. Boring beats
   clever (simplicity mode's laziness ladder applies to decisions too).
3. **Record it** in the decisions record (below) with a one-line rationale.
4. **Proceed without pausing.** Never print a question and wait.

Free-text prompts (e.g. cycle's bare-invocation "what do you want to build?")
cannot be self-answered — there is no goal to infer. That single case aborts
with usage guidance: autonomous invocations must carry a description, a spec
file, or `backlog`.

## What autonomous does NOT override

Self-answering collapses *preference* questions, never *safety* aborts. These
stay hard failures exactly as written in their skills:

- dirty-repo aborts (workspace Step 5 two-phase check, worktree creation)
- graphify hard requirement, schema-version guards, the iteration ceiling
- VERIFY's code-review HARD-GATE and the test-tamper scan
- DELIVER's exact-SHA identity, required-check, and unique-PR gates
- anything the skill marks abort/escalate-with-evidence rather than ask

## The continuation ladder (warnings are a record, not a handler)

An autonomous run must manage every cycle of iteration itself. `warnings[]` is
the audit trail of what happened — it is NEVER how a problem gets handled,
because in a headless run nobody is reading warnings mid-flight. When a phase's
escalation path fires, climb this ladder instead of stopping:

1. **Self-heal in phase** — the existing gate retry loops (gate re-dispatch with
   findings, teammate rework via SendMessage) run exactly as written; gate
   retries are unbounded.
2. **Lead-authored fallback** — if a teammate fails to produce its artifact
   after one fresh re-dispatch, the lead (main thread) authors the artifact
   itself from the same brief and continues, noting `lead-authored` in the
   transcript. A missing teammate output is a dispatch problem, not a reason
   to stop the loop.
3. **ITERATE rewinds** — `execute`/`plan`/`spec` gaps rewind hands-off (style
   is `auto`); the immutable original goal keeps the oracle honest and
   `iterate.maxIterations` keeps it bounded. **While iterations remain, the
   backlog is never used** (any mode): every gap is worked by a rewind, not
   deferred — a backlogged in-limit gap would be convergence the loop claimed
   but never did.
4. **Iteration limit hit (the ONLY backlog entry point)** — run ITERATE's
   confirmation pass as written, then convert EVERY accepted gap into a
   concrete `BACKLOG.md` entry (`lib/backlog.sh add`, one self-contained
   feature description per gap). After DELIVER's sidecar reaches
   `delivery.json.status == "ready-for-review"`, the autonomous run **chains directly
   into backlog drain** (cycle Step 3 branch 4 semantics, bounded by
   `LOOP_SPEC_MAX_FEATURES`) so the gaps become worked items in the same run,
   not notes for a human. `delivery-incomplete` stops chaining. Record the same
   facts in `warnings[]` for the PR audit trail.
5. **Terminal** — a gap that re-enters via backlog drain and spends its rounds
   AGAIN is not re-backlogged: mark it terminal (`iterate-terminal:` prefix in
   `warnings[]` and the backlog entry closed via `lib/backlog.sh terminal
   <gap-id> <note>`; the gap id is deterministic — `backlog.sh gap-id` — and
   matched by exact equality against `feature.backlogEntryId`, never fuzzy text). Two full
   limits on the same gap means the approach is wrong, not under-iterated —
   that is the one legitimate stop, and it stops with the complete evidence
   trail (BUG-level detail in ITERATION.md), never silently. Before stopping,
   the run salvages the work product via `lib/checkpoint-pr.sh` (draft PR with
   the evidence trail) so a terminal stop still yields a reviewable artifact.

The ladder never invents an approval and never overrides a safety gate; it
exhausts autonomous handling before anything is left for a human, and what it
does leave is a worked evidence trail rather than a warning line.

## The decisions record

The moment an assumption is made it goes to DISK, never model memory — the audit
trail must survive compaction and session death. `lib/decisions.sh` is the store
(JSONL; `add` / `render` / `migrate`):

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/decisions.sh" add "$dir" "$phase" "$question" "$answer" "$rationale"
```

`$dir` is the feature dir once it exists; setup answers made before then (cycle
Steps 0–4: workspace repos, resume choice, detected commands) use the staging dir
`.loop-spec/decisions-staging`, and cycle Step 5 migrates them right after
feature-init: `decisions.sh migrate .loop-spec/decisions-staging "$feature_dir"`.

From that store, every self-answered question lands in two places:

1. **SPEC.md `<decisions>` block** — a `## Decisions (assumed — autonomous)`
   list, rendered verbatim from the store (`decisions.sh render "$feature_dir"`
   emits the `- **{question}** → {answer} — {rationale}` lines). Whichever phase
   makes an assumption `add`s it (SPEC for interview rounds, DISCUSS for
   unresolved-dimension resolutions, cycle for setup answers); SPEC writes the
   rendered list in.
2. **PLAN.md `## User decisions (already made)`** — the planner copies the
   record forward, each entry suffixed `(assumed)`, so the existing
   escalation contract ("consult the decisions record before asking") covers
   assumed answers exactly like human ones.

The record is the audit trail: a human reviewing the PR reads what was assumed
and why, and can rerun with corrections as pinned `LOOP_SPEC_ANSWER_*` vars or
an edited spec file.

## Site map (where the contract applies)

| Site | Normal behavior | Autonomous behavior |
|---|---|---|
| auto route selection | explicit cycle choice | grounded semantic proposal -> `lib/task-route.sh` validation -> micro/debug/full; uncertainty and risk promote to full |
| cycle Step 0 workspace repo confirmation | AskUserQuestion | all discovered repos participate (or `LOOP_SPEC_ANSWER_REPOS`) |
| cycle Step 1 resume choice | AskUserQuestion | resume the most recently updated resumable feature; if none, new feature |
| cycle Step 3 bare invocation | free-text question | abort with usage guidance (no goal to infer) |
| cycle Step 4 command confirmation | AskUserQuestion | trust detection (or `LOOP_SPEC_CMD_*`); record |
| SPEC interview (all rounds + gate prompts) | AskUserQuestion loop | self-answered interview, all six perspectives in ONE pass with a single end-of-pass scoring — see `skills/spec/SKILL.md` "Autonomous mode" |
| DISCUSS phase shape | clarifying loop + spec-writer + critique gate | **collapsed** (`skills/discuss/SKILL.md`, Autonomous fast path): no clarifying loop (the SPEC self-interview covered it), no spec-writer (SPEC.md is the draft; the lead applies revisions directly) — only the critique gate dispatches a teammate |
| DISCUSS unresolved dimensions / "depends on user intent" rows | AskUserQuestion in `step`/`interactive` | graph-grounded assumption, recorded (already the `auto` path; the intent row picks the more reversible reading and records it) — applied by the lead directly under the fast path |
| DISCUSS / PLAN teammate-idle | AskUserQuestion | one fresh re-dispatch, then the lead authors the artifact itself (continuation ladder rung 2). DISCUSS's fast path has no spec-writer, so this applies to its critique teammates and to PLAN's roster |
| ITERATE spec-rewind approval (`step`/`interactive` only) | AskUserQuestion | moot — style is forced to `auto`, which already auto-approves |
| ITERATE limit spent | ship-with-warnings, human drains backlog later | confirmation pass → accepted gaps become BACKLOG entries → chain into backlog drain (ladder rungs 4-5) |
| DELIVER transport / identity / CI gate | stop or manual repair | failed required checks route to EXECUTE; ambiguous PR, moved head, timeout, missing auth/remote, or partial workspace delivery fail closed and stop chaining |
| debug skill fix-strategy and escalation choices | AskUserQuestion | recommended strategy, recorded in BUG.md |

Sites not listed follow the general rule: recommended option, recorded, proceed.
