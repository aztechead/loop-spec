# Autonomous mode: the self-answer contract

Autonomous mode makes a run question-free: at every point loop-spec would call
`AskUserQuestion`, the orchestrator takes the answer it would have recommended, records
it as an assumed decision, and proceeds. It is ON when the inline token `autonomous`
appears in the invocation (stripped from the title) or `LOOP_SPEC_AUTONOMOUS=1` is set;
the cycle persists it as `feature.json.autonomous = true` so phases and resumes see it.

`execStyle: auto` is not this mode. Auto is the default style: the cycle does not pause
between phases, but a human is attached and grill, SPEC, and DISCUSS questions still
fire (the SPEC interview is an AskUserQuestion loop (`auto` included)).

Do not ask for permission to perform work the original request already authorizes;
carry out the next step and keep going until the work is complete. Human gates,
destructive-action confirmations, and safety failures remain pauses or loud failures.

## Entry points

The preferred headless entry is `/loop-spec:auto <description>`, which makes a grounded
routing decision validated by `lib/task-route.sh` before micro, debug, compact, or the
full cycle; `/loop-spec:cycle autonomous <description>` is the full cycle with zero
input. Per harness: `claude -p "/loop-spec:auto <description>"` (or the Claude Agent SDK
`query()` with the plugin loaded; `docs/loop-spec/claude-invocation-contract.md`),
`opencode run --format json "Load the loop-spec-auto skill and run: <description>"`,
`adk run "$LOOP_SPEC_ADK_AGENT_DIR" "Load the loop-spec auto skill and run: <description>" --jsonl`,
and `LOOP_SPEC_HARNESS=codex LOOP_SPEC_NON_INTERACTIVE=1 codex exec --json --sandbox workspace-write '$loop-spec-auto <description>'`.
All stamp `CLAUDE_CODE_ENTRYPOINT`, so `lib/harness.sh headless` detects the profile.
`LOOP_SPEC_PHASE_HANDOFF=1` (or `phase:fresh`) returns after each durable phase with a
paused `phase-handoff` result so a supervisor can relaunch with fresh context.

The compact route (`/loop-spec:auto` classifier) writes an auditable per-gate run/skip
plan; every skip has a reason, a malformed or unbounded proposal promotes to the full
cycle, and Destructive work is never compact. The contract is
[`compact-profile.md`](compact-profile.md).

## Precedence

1. Explicit answers win: a `LOOP_SPEC_ANSWER_*` / `LOOP_SPEC_CMD_*` variable, a rule in
   `.loop-spec/RULES.md`, or a decision already in the feature's record is never
   re-decided.
2. Style is forced to `auto`; `step`/`interactive`/`review-only` tokens are ignored with
   a one-line notice.
3. Every remaining question self-answers (below). `lib/phase-mode.sh` and
   `lib/cycle-driver.sh start` already resolve the setup and phase-entry sites; the
   grill directive is suppressed for the session.
4. Retro auto-applies at completion (`lib/retro.sh auto`; kill switch
   `LOOP_SPEC_RETRO_AUTO_APPLY=0`): a closed template set that only tightens the loop.

Autonomous implies non-interactive everywhere `LOOP_SPEC_NON_INTERACTIVE=1` is honored
and is strictly stronger: where non-interactive aborts or takes a fixed default,
autonomous derives the recommended answer.

## The self-answer rule

1. Formulate the question anyway; it names the ambiguity being collapsed.
2. Answer as the options' author would recommend: what the codebase already does
   (map, PATTERNS, evidence) first, then industry practice, then the most reversible
   option. Boring beats clever.
3. Record it to disk at once, never in model memory:
   `bash "${CLAUDE_SKILL_DIR}/../../lib/decisions.sh" add "$dir" "$phase" "$question" "$answer" "$rationale"`
   (`$dir` is the feature dir; setup answers use `.loop-spec/decisions-staging` and the
   cycle migrates them). SPEC renders the record into its `<decisions>` block
   (`decisions.sh render`); PLAN copies it into `## User decisions (already made)`
   suffixed `(assumed)`, so the "answer from the record before asking" rule covers
   assumed answers exactly like human ones. A reviewer reads what was assumed and can
   rerun with pinned `LOOP_SPEC_ANSWER_*` values or an edited spec.
4. Proceed without pausing. Never print a question and wait.

A free-text prompt with no goal to infer (a bare invocation) cannot be self-answered:
abort with usage guidance. Compaction summaries preserve the original goal, user
constraints, locked decisions, acceptance criteria, unresolved blockers, evidence
paths, and the exact commands needed to resume.

Self-answering collapses preference questions, never safety aborts: dirty-repo aborts,
schema guards, the iteration ceiling, VERIFY's code-review HARD-GATE and tamper scan,
and DELIVER's exact-SHA, required-check, and unique-PR gates stay hard failures. Sites
that normally reach a human only in one style (DISCUSS unresolved dimensions and
intent findings: AskUserQuestion in `auto`/`step`/`interactive`; ITERATE's spec-rewind
approval in `step`/`interactive`) take the grounded assumption here.

## The continuation ladder (warnings are a record, not a handler)

`warnings[]` is the audit trail; nobody reads it mid-flight. When an escalation path
fires, climb instead of stopping:

1. **Self-heal in phase**: gate retry loops run as written; a critique gate closes at the graph's delta ceiling (`lib/graph/gate.sh next`) and the run proceeds.
2. **Lead-authored fallback**: a teammate that produces nothing after one fresh
   re-dispatch is replaced by the lead authoring the artifact from the same brief
   (`lead-authored` in the transcript).
3. **ITERATE rewinds** hands-off; the immutable original goal keeps the oracle honest
   and `iterate.maxIterations` bounds it. While iterations remain, the backlog is never
   used.
4. **Iteration limit hit** (the only backlog entry point): the confirmation pass, then
   every accepted gap becomes a `BACKLOG.md` entry, and after DELIVER reaches
   `ready-for-review` the run chains into backlog drain (`LOOP_SPEC_MAX_FEATURES`).
   `delivery-incomplete` stops chaining.
5. **Terminal**: a gap re-entered from the backlog that spends its rounds again is not
   re-backlogged. Mark it `iterate-terminal:`, close the entry (`lib/backlog.sh
   terminal <gap-id> <note>`; ids are deterministic and matched exactly against
   `feature.backlogEntryId`), write the full evidence trail into ITERATION.md, and
   salvage the work via `lib/checkpoint-pr.sh`. Two limits on one gap means the
   approach is wrong; that is the one legitimate stop, and it stops loudly.

DELIVER stays fail-closed: failed required checks route to EXECUTE; an ambiguous PR,
moved head, timeout, missing auth or remote, or partial workspace delivery stops the
chain. The debug skill's strategy and escalation choices take the recommended option
and record it in BUG.md.
