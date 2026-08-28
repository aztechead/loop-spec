# Conciseness plan (2026-08)

For the agent (or maintainer) implementing one stage of this plan, possibly in a fresh
session with no memory of the audit. Each stage is one commit on
`cursor/conciseness-audit-74b8` that leaves `bash tests/run-all.sh` green. Do the stages
in order; mark the tracker as you land them.

## Goal and ground rules

Shrink the always-loaded token weight of the plugin so agents follow it more easily,
without dropping functionality. The measure of success is harness best practice, not a
word quota: Anthropic's skill-authoring guidance says keep a SKILL.md body under 500
lines (~5k tokens) and push detail into `references/` loaded on demand. Today `cycle`
(1327 lines), `execute` (791), `discuss` (693), `plan` (669), and `verify` (594) all
exceed that line.

Rules that bind every stage:

1. **Cite, never paste.** A rule lives in exactly one file; everyone else cites it.
   Phase skills keep only their deltas.
2. **Pins move with the text, in the same commit.** `tests/run-all.sh` greps fixed
   strings out of these bodies. Before editing a file, run
   `bash lib/surface.sh covers <path>` and grep `tests/` for its needles; update the
   suite in the same change. Never delete a pin's meaning — relocate the needle or
   repoint the suite.
3. **No entry point disappears.** Aux skills that fold into phases become thin stubs
   (frontmatter + pointer) so `/loop-spec:<name>` and SessionStart wiring survive.
4. **Elevate, don't decide.** A change that would remove a phase, or a contradiction in
   the plugin's logic, stops the work and goes to the maintainer as a question.
5. **Deliberate redundancy stays.** Some repetition is load-bearing (dual subagent
   prompts must each carry the pinned contract phrases; safety invariants repeat by
   design). The audit marked these; when in doubt, keep the repetition and say so.
6. Run the repo's own gates on what you touch: `bash lib/doc-tells.sh scan <md>` for
   docs, `house-style.sh compare` / `comment-tells.sh scan` / `failure-tells.sh scan`
   for shell, `indirection-scan.sh` / `duplication-scan.sh` for new helpers.

## Tracker

| Stage | Scope | Status |
|---|---|---|
| 1 | Implementer contract: one shared block, every rung, three design questions | done |
| 2 | DISCUSS/PLAN: shared critique-gate protocol + preamble cites | done |
| 3 | CYCLE: extract init/phase-loop/completion references, cite shared contracts, fix fences | done |
| 4 | EXECUTE/VERIFY: execute-core extraction, loops shrink, remediation factor | pending |
| 5 | SPEC/ITERATE/DELIVER + feature-state/grounding trims | pending |
| 6 | Aux skill fold-ins (simplicity, human-code, gates, walkthrough, micro/discipline) | pending |
| 7 | Cross-cutting: harness adapters, harness-call-contracts, style docs | pending |

## Findings the stages rest on

Full audit detail lives in the PR discussion; the load-bearing facts:

- `skills/cycle/SKILL.md` restates ~1.6k words of `skills/shared/*` contracts
  (implicit-team-mode ~540w across five sites, route-exit ~250w, resume ~260w,
  no-teams/harness ~200w, maintenance short-path told three times). Steps 3.5/4/5.5 and
  workspace already prove the reference-extraction pattern; Step 5 init (~1.2k words of
  bash), Step 6 phase loop (~2.5k words), and completion (~600w) have not had it applied.
  The body also has unbalanced code fences from Step 5 onward: the ` ```bash ` opened at
  line 532 swallows the workspace heading at 760, and the file ends inside an open fence
  — headings mid-file render as code to an agent.
- `skills/discuss/SKILL.md` and `skills/plan/SKILL.md` each carry ~1.7k words of
  near-clone critique-gate + adjudication procedure (~80% token overlap on the gate,
  ~78% on adjudication) even though `graph/cycle` topology already lives in
  `graph/critique.graph.json` and the ladder policy in `skills/shared/tier-matrix.md`.
- A ~400-word implementer engineering contract (laziness ladder, design-for-change,
  human-code, failure path) is pasted four times: twice inside
  `skills/shared/execute-subagent.md`, once in `skills/shared/team-prompts/implementer.md`,
  once in `agents/implementer.md` — and is absent from the inline, loops, and loop-fleet
  rungs entirely. The maintainer wants every execution path to ask: can this be more
  modular, can this be more extensible, is this the least code that does it.
- `skills/shared/execute-loops.md` (919w) mostly restates the team prompts it names as
  authoritative. `skills/verify/SKILL.md` repeats a four-step remediation teardown three
  times (lines ~326, ~351, ~367).
- SPEC ships ~318 words of example interview questions and two full AskUserQuestion JSON
  bodies; ITERATE ends with a "Design notes" block that restates its own Steps 0–3;
  `skills/shared/feature-state-schema.md` re-narrates DELIVER policy and duplicates
  `lib/feature-write.sh` as pseudocode.
- Aux exile confirmed: `skills/simplicity/SKILL.md` carries a full copy of the laziness
  ladder (third copy counting the inject); `skills/human-code/SKILL.md` re-teaches
  `skills/shared/human-code.md` and re-documents all four probes;
  `checking-gates`/`specifying-gates` are EXECUTE content; `walkthrough` is VERIFY
  content already invoked from VERIFY.
- The three non-Claude harness adapters repeat the same chat-report, ambient-verification
  and GDD paragraphs; `skills/shared/harness-call-contracts.md` appendices duplicate the
  adapters' dispatch sections.

## Decisions for the maintainer

- **`skills/shared/execute-loops.md`: shrink or delete.** Default taken by stage 4 is
  shrink to lead-only notes (~250–400w: race-claim rule, TaskList as source of truth,
  pointer to team prompts). Deleting the file entirely is cleaner but removes a named
  surface; flag before doing that.
- Resolved during audit: the `tests/discuss-grill-coverage.test.sh` iterate needle that
  looked stale is a must-not entry (pins a softening's absence); no contradiction.
- No finding proposes removing a phase.

## Stages

### Stage 1 — implementer contract, every rung, three questions

New file `skills/shared/implementer-contract.md` (~450–550w): the engineering contract
every code-producing dispatch carries. Headline framing is the maintainer's three
questions — **can I make it more modular, can I make it more extensible, is this the
least code that makes it happen** — mapped onto the existing contracts:
design-for-change (modular/extensible), laziness ladder (least code), human-code (house
style, failure path), human-docs, with the probe commands
(`indirection-scan.sh`, `duplication-scan.sh`, `house-style.sh`, `comment-tells.sh`,
`failure-tells.sh`, `doc-tells.sh`) listed once.

- Replace the four pasted copies with a compact required stanza that cites the shared
  file while keeping needles the suites pin inside each prompt path (TDD force string,
  `writing-good-tests.md`, `NO NESTED SUBAGENTS`, `evidence over recall`,
  `scope is closed` — see `tests/execute-dispatch-contract.test.sh` `count_ge`,
  `tests/execution-discipline-coverage.test.sh`, `tests/tdd-red-green-coverage.test.sh`,
  `tests/ponytail-coverage.test.sh`, `tests/design-coverage.test.sh`,
  `tests/human-code-coverage.test.sh`).
- Close the gap: `skills/shared/execute-inline.md`, `execute-loops.md`,
  `execute-loop-fleet.md`, and `skills/execute/SKILL.md` gain a one-line cite so no rung
  dispatches code without the contract.
- Pin it: extend an existing coverage suite (or add `tests/implementer-contract-coverage.test.sh`)
  asserting every rung doc names `implementer-contract.md`.

### Stage 2 — DISCUSS/PLAN critique protocol

New file `skills/shared/critique-gate-protocol.md` (~900–1200w): parameterized
single-critic pass, escalated debate loop, adjudication tables, gateHistory fail/pass
JSON, delta re-verify, currentGate reset. Cites `tier-matrix.md` for ladder policy and
`graph/critique.graph.json` for routing; does not restate either.

- `skills/discuss/SKILL.md`: replace Steps 4–5 bodies with the cite plus discuss deltas
  (never-skip policy, SPEC-only `security-signal.sh` run, no-op-revision hash shortcut,
  lead-authored fix when autonomous, next step 5.75). Replace the team-mode preamble
  (lines ~11–26) with two cite lines. Compress the Step 1.5 "moved" history note and the
  `evidence.sh` recipe (cite `grounding-protocol.md`). Keep the grill block and every
  `tests/discuss-grill-coverage.test.sh` needle byte-identical.
- `skills/plan/SKILL.md`: same extraction with plan deltas (structural fast-path shell,
  maintenance skip, challenger warm-up, `## User decisions (already made)` suffix, next
  step 4b). Thin the PRE-SUBMIT checklist to a charter cite. Keep
  `review-prompts/prose-pruning.md` (bmad pin) and contract-strings needles
  (`decisions.sh" add`, `evidence.sh" add`, `grounding-lint.sh"`, `UNGROUNDED:`,
  `gate_round`, `dispatch-events.md`, `graph/critique.graph.json`) in each skill.
- `agents/planner.md`: engineering-principles section compresses to named obligations +
  cites (keep TDD/ponytail/design/human pins); workspace section points at
  `skills/plan/references/workspace-task-format.md` instead of duplicating it.

Targets: discuss ~5.1k→~3.4k words, plan ~4.5k→~3.0k, planner ~3.1k→~2.4k.

### Stage 3 — CYCLE orchestrator

Apply the existing references pattern to the heavy sections, and fix the fence bug.

- New `skills/cycle/references/initialize-state.md` (Step 5 bash: adopt-PR, worktree,
  prepare, baseline, skeleton — keep the `python -m pytest` venv needle and the exact
  `LOOP_SPEC_STARTUP_BASELINE` guard line, or repoint their suites).
- New `skills/cycle/references/phase-loop.md` (Step 6 invoke/watchdog/PROGRESS/
  state-commit/checkpoint-PR + no-change completion, phase-handoff, fresh rewind). Keep
  ≥2 `feature-init.sh" activate` sites visible to `tests/model-overrides.test.sh`
  (stub keeps the inline activate lines).
- New `skills/cycle/references/completion.md` (result write/retry/summary/chain).
  `tests/terminal-result-coverage.test.sh` and `tests/delivery-phase-coverage.test.sh`
  pin many completion strings — keep those needles in the SKILL stub or move them and
  update both suites in this commit.
- Replace restatements with cites: one teams-mode map instead of the Dispatch/Step 2
  double-tell, one maintenance sentence (keep the pinned
  `ITERATE and DELIVER still run` once), Step 1 resume body → cite
  `cycle-resume-escalation.md`, route-exit block → cite `route-exit-contract.md`
  keeping `protocol-mismatch` / `genuine **non-task**` needles.
- Fix fence balance so every heading from Step 5 to EOF sits outside code fences.
- `references/codebase-map-bootstrap.md`: collapse the two near-identical mapper Agent
  templates into one template + mode deltas.

Target: SKILL body ~10.5k→~4.0–4.5k words; references grow to ~7–7.8k; net surface
−15–20% and the always-loaded body −55–60%.

### Stage 4 — EXECUTE/VERIFY rung dedup

- New `skills/shared/execute-core.md` (~350–500w): result shape
  `{merged, blocked, escalation}` + consume rule, `mergedSet`/`mark-done`, the
  VERIFY-Step-1.75-only suite invariant (said once), dispatch/task_start/task_end event
  shapes, shared inputs. Rung docs keep isolation model, dispatch tool, merge path,
  halt vocabulary as deltas. Keep `feature-validation.sh` absent from every rung doc
  (`tests/execution-validation-coverage.test.sh`) and `dispatch-events.md` named from
  each pinned file.
- `skills/shared/execute-subagent.md`: single implementer prompt template with
  workspace/in-place deltas instead of two full prompts; drop "Why no team" pedagogy;
  one suite-invariant sentence. Update `tests/execute-dispatch-contract.test.sh`
  `count_ge` expectations to the new shape while keeping each prompt path carrying the
  pinned phrases. ~4.6k→~3.0k words.
- `skills/shared/execute-loops.md`: shrink per the maintainer decision above.
- `skills/execute/SKILL.md`: extract the workspace branch-check + rung gate to
  `skills/execute/references/workspace-mode.md`; halve the foreign-claimant essay
  (bullets + cite `handoff-port.md`); cite loop-fleet for the runtime probe narrative.
  ~5.4k→~3.8k words.
- `skills/verify/SKILL.md`: factor the remediation teardown recipe once (a named
  sub-procedure the three sites cite); Steps 7.65/7.66 shrink to command + contract cite
  (`plain-language.md`, `human-docs.md`); trim Step 1.75 history. Keep
  `verification-grounding` needles. ~4.7k→~3.6k words.
- Thin shared "workspace invariants" stub (~50w) cited by cycle/execute/verify; the
  three phase workspace docs stay separate (different jobs).

### Stage 5 — SPEC/ITERATE/DELIVER + schema/grounding

- `skills/spec/SKILL.md`: example question banks and calibration table →
  `skills/spec/references/interview-prompts.md` (or delete the examples); grounding
  restatement → cite `grounding-protocol.md` (keep `evidence.sh" add` and
  `decisions.sh" add` needles); AskUserQuestion JSON bodies → option bullets + cite
  `harness-call-contracts.md`; SPEC.md frontmatter rules → cite the artifact template.
  Keep the `**\`execStyle: auto\` still interviews.**` pin.
- `skills/iterate/SKILL.md`: delete the self-restating "Design notes" block; trim Step 0
  framing; compress the AskUserQuestion JSON. Keep contract-strings and delivery-phase
  needles (`iterate-budget-spent:`, `iterate-terminal:`, `currentPhase = "deliver"`,
  the staged-diff guard line).
- `skills/deliver/SKILL.md`: three-invariants essay → three bullets; Step 4 routing
  prose → cite `pr-feedback-check.md` keeping the bash loop and
  `feedback persistence failed` needle.
- `skills/shared/feature-state-schema.md`: `delivery` field note shrinks to two lines
  pointing at DELIVER; atomic-write pseudocode → cite `lib/feature-write.sh`; historical
  migration asides → CHANGELOG. Keep the `webapp/frontend && npm ci` needle and the
  graph-schema key coverage.

### Stage 6 — aux skill fold-ins

Fold pattern for each: content lives once in `skills/shared/` (or the owning phase's
references), the aux SKILL.md becomes a stub (frontmatter with unchanged `description`,
the on/off/status CLI if it has one, one pointer line), SessionStart injects keep citing
shared.

- `skills/simplicity/SKILL.md`: ladder copy (lines ~73–128) deleted; stub cites
  `skills/shared/laziness-ladder.md`. Inject already points at shared.
- `skills/human-code/SKILL.md`: principles + probe re-documentation deleted; stub cites
  `skills/shared/human-code.md` / `human-docs.md`; probe subcommand stays.
- `skills/checking-gates/SKILL.md` + `skills/specifying-gates/SKILL.md`: bodies merge
  into new `skills/shared/user-gates.md`; EXECUTE cites it; both skills stub (hook
  `Skill(...)` names keep resolving).
- `skills/walkthrough/SKILL.md`: procedure moves to a VERIFY-citable shared/reference
  home; stub remains for ad-hoc use (bmad pins move with the text).
- `skills/micro/SKILL.md` + `skills/discipline/SKILL.md`: dedupe against their injects —
  protocol/gate text lives in one place, the other cites it. micro remains a standalone
  protocol (not folded into EXECUTE).
- Leave alone (compress only if trivial): auto, debug, intake, loop-runner,
  map-codebase, assess, forensics, revise, sentinel, quality-loop, rollback, onboard,
  pause, retro, status, watch, grill, rules.

### Stage 7 — cross-cutting harness/style surfaces

- The opencode/adk/codex adapters: chat-report, ambient-verification, and GDD paragraphs
  reduce to the pinned sentences (`no output-style slot`, `one thought per action`) plus
  a cite of `report-style.md`; dispatch-mapping tables stay (genuinely per-harness).
- `skills/shared/harness-call-contracts.md`: ADK/opencode/Codex appendices become
  one-liners pointing at each adapter's Dispatch section; Claude schemas stay (linted by
  `tests/lib/harness-call-shapes.test.sh`).
- `skills/shared/report-style.md`: drop the historical "used to be an instruction"
  paragraph. `output-styles/loop-spec.md`: keep all pins; trim only meta-commentary.
  The two files stay separate by design (Claude slot vs other harnesses).

## Acceptance, every stage

- `bash tests/run-all.sh` green.
- `bash lib/doc-tells.sh scan` on every markdown touched;
  `bash lib/house-style.sh compare`, `comment-tells.sh scan`, `failure-tells.sh scan` on
  any shell touched; `indirection-scan.sh` / `duplication-scan.sh` on new helpers.
- Word counts recorded in the commit message (`before → after` per file).
- One conventional commit per stage (`docs:`/`fix:`/`chore: NO_JIRA ...`,
  `Co-Authored-By: Claude <noreply@anthropic.com>`), pushed, PR updated.
