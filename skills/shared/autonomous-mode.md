# Autonomous mode — the self-answer contract

Autonomous mode makes a run **question-free**: every point where loop-spec would
normally call `AskUserQuestion`, the orchestrator instead takes the answer it
would have recommended — the option grounded in the code graph, the codebase
map, and general best practice — records it as an assumed decision, and
proceeds. It is the headless CLI mode: `claude -p "/loop-spec:cycle autonomous
<description>"` runs a full cycle with zero human input.

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
   form instead.

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
- graphify hard requirement, schema-version guards, budget/iteration ceilings
- VERIFY's code-review HARD-GATE and the test-tamper scan
- anything the skill marks abort/escalate-with-evidence rather than ask

When a phase's escalation path fires with no human available (e.g. a gate
bounces past its retry budget), do what the budget-spent path already does in
`auto` style: ship-with-warnings or halt with the evidence written to the
artifact and `warnings[]` — never invent an approval.

## The decisions record

Every self-answered question lands in two places:

1. **SPEC.md `<decisions>` block** — a `## Decisions (assumed — autonomous)`
   list: `- **{question}** → {answer} — {one-line rationale}`. Written by
   whichever phase made the assumption (SPEC for interview rounds, DISCUSS for
   unresolved-dimension resolutions, cycle for setup answers made before
   SPEC.md exists — cycle buffers them and SPEC writes them in).
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
| cycle Step 0 workspace repo confirmation | AskUserQuestion | all discovered repos participate (or `LOOP_SPEC_ANSWER_REPOS`) |
| cycle Step 1 resume choice | AskUserQuestion | resume the most recently updated resumable feature; if none, new feature |
| cycle Step 3 bare invocation | free-text question | abort with usage guidance (no goal to infer) |
| cycle Step 4 command confirmation | AskUserQuestion | trust detection (or `LOOP_SPEC_CMD_*`); record |
| SPEC interview (all rounds + gate prompts) | AskUserQuestion loop | self-answered interview — see `skills/spec/SKILL.md` "Autonomous mode" |
| DISCUSS unresolved dimensions / "depends on user intent" rows | AskUserQuestion in `step`/`interactive` | graph-grounded assumption, recorded (already the `auto` path; the intent row picks the more reversible reading and records it) |
| PLAN teammate-idle / gate escalation | AskUserQuestion | one fresh re-dispatch, then halt with evidence in `warnings[]` |
| ITERATE spec-rewind approval (`step`/`interactive` only) | AskUserQuestion | moot — style is forced to `auto`, which already auto-approves |
| debug skill fix-strategy and escalation choices | AskUserQuestion | recommended strategy, recorded in BUG.md |

Sites not listed follow the general rule: recommended option, recorded, proceed.
