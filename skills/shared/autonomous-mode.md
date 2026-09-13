# Autonomous mode: the self-answer contract

Autonomous mode makes a run question-free: at every point loop-spec would call
`AskUserQuestion`, the orchestrator takes the answer it would have recommended, records
it as an assumed decision, and proceeds. The one exception is a supervisor that
answers ("The supervised path", below), and the probe that names it is
`lib/supervisor/oracle.sh`. It is ON when the inline token `autonomous` (at the leading
or trailing edge of the arguments; inside the description the word is prose)
appears in the invocation (stripped from the title) or `LOOP_SPEC_AUTONOMOUS=1` is set;
the cycle persists it as `feature.json.autonomous = true` so phases and resumes see it.

`execStyle: auto` is not this mode. Auto is the default style: the cycle does not pause
between phases, but a human is attached and grill, SPEC, and DISCUSS questions still
fire (the SPEC checkpoint uses consolidated AskUserQuestion questions (`auto` included)).

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
Claude stamps `CLAUDE_CODE_ENTRYPOINT`. Peer harnesses use explicit non-interactive settings that `lib/harness.sh headless` reads.
Full-route phases return a paused `phase-handoff` result. Graph-declared same-session transitions continue without a new invocation. `LOOP_SPEC_SAME_SESSION=1` makes every transition one, for an operator who wants the whole cycle end to end in one session.
`lib/cycle-launch.sh` owns
CLI relaunches; SDK and ADK supervisors may retain their native relaunch loop. The next
phase starts in a fresh context.

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

1. State the unresolved choice as a question.
2. Answer as the options' author would recommend: what the codebase already does
   (map, PATTERNS, evidence) first, then industry practice, then the most reversible
   option.
3. Record it to disk at once, never in model memory:
   `bash "${LOOP_SPEC_SKILL_DIR}/../../lib/decisions.sh" add "$dir" "$phase" "$question" "$answer" "$rationale"`
   (`$dir` is the feature dir; setup answers use `.loop-spec/decisions-staging` and the
   cycle migrates them). SPEC renders the record into its `<decisions>` block
   (`decisions.sh render`); PLAN copies it into `## User decisions (already made)`
   suffixed `(assumed)`, so the "answer from the record before asking" rule covers
   assumed answers exactly like human ones. A reviewer reads what was assumed and can
   rerun with pinned `LOOP_SPEC_ANSWER_*` values or an edited spec.
4. Proceed without pausing. Never print a question and wait.

## The supervised path

An SDK or ADK supervisor can answer the harness's question tool while the run stays
autonomous: the Claude Agent SDK routes `AskUserQuestion` to its `canUseTool`
callback, ADK routes `get_user_choice` to the caller. `bash
"${LOOP_SPEC_SKILL_DIR}/../../lib/supervisor/oracle.sh" mode --feature-dir "$feature_dir"`
answers `oracle=supervisor` when `LOOP_SPEC_ORACLE=supervisor` (the `supervised`
profile preset sets it, `docs/loop-spec/supervisor-interface.md`); `lib/phase-mode.sh`
carries that answer on the SPEC and DISCUSS mode lines as `oracle=`, and
`lib/phase-exit.sh` keeps either phase open when a named supervisor was never asked.
On that answer, at every self-answer site in SPEC and DISCUSS:

1. Formulate the question exactly as the self-answer rule would, and ask it through the
   native question tool with the recommended option FIRST and labeled `(Recommended)`.
   One consolidated call per checkpoint; the placeholder guard still applies, so every question
   is a real one.
2. The answer is recorded for you on Claude Code and the Agent SDK:
   `hooks/team/oracle-record.sh` writes kind `supervised` from the question tool's
   payload, and `oracle-unavailable` when the call failed; `decisions.sh` refuses
   those kinds from anywhere else there. On opencode, ADK, and Codex record them
   yourself (`decisions.sh add ... supervised`). The recommended option, an empty
   answer, and a failed call all fall back to the self-answer rule for the content
   of the decision; the record still shows the supervisor was asked.
3. A free-text answer of exactly `halt` pauses the cycle: publish a paused result with
   reason `oracle-halt` via `lib/cycle-result.sh write` and return. The supervisor
   resumes with the answer pinned (`LOOP_SPEC_ANSWER_*`, `RULES.md`, or an edited SPEC).
4. Precedence above is unchanged: a pinned answer or a decision on record is never
   re-asked, whoever the oracle is.

`oracle=self` (the default) is the self-answer rule exactly as written. `oracle=human`
means the run is not autonomous and this file does not apply.

A free-text prompt with no goal to infer (a bare invocation) cannot be self-answered:
abort with usage guidance. Compaction summaries preserve the original goal, user
constraints, locked decisions, acceptance criteria, unresolved blockers, evidence
paths, and the exact commands needed to resume.

Self-answering collapses preference questions, never safety aborts: dirty-repo aborts,
schema guards, the iteration ceiling, VERIFY's code-review HARD-GATE and tamper scan,
and DELIVER's exact-SHA, required-check, and unique-PR gates stay hard failures.
Goal and Boundary freeze when the cycle enters PLAN (`lib/spec_intent.py`), after
SPEC and DISCUSS have both asked their questions. From then on self-answering cannot
change them or rewrite the approval digest: return genuine post-approval
intent gaps to the human. Implementation choices outside those sections can change
within the approved outcomes and constraints. Subject to that freeze, sites
that normally reach a human only in one style (DISCUSS unresolved dimensions and
intent findings: AskUserQuestion in `auto`/`step`/`interactive`; ITERATE's spec-rewind
approval in `step`/`interactive`) take the grounded assumption here.

## The continuation ladder (warnings are a record, not a handler)

`warnings[]` records outcomes but does not resolve them.
Use these recovery paths within existing authorization and gate limits:

1. **Self-heal in phase**: gate retry loops run as written; a critique gate closes at the graph's delta ceiling (`lib/graph/gate.sh next`) and the run proceeds.
2. **Lead-authored fallback**: a teammate that produces nothing after one fresh
   re-dispatch is replaced by the lead authoring the artifact from the same brief
   (`lead-authored` in the transcript).
3. **ITERATE rewinds** hands-off; the immutable original goal keeps the oracle honest,
   the Goal and Boundary freeze stays (only a human-approved rewind reopens it),
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
