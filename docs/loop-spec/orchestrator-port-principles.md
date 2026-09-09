# Orchestrator port: the rules behind the plan

For the agent driving PR 94, to read before any decision the plan and the follow-up did
not anticipate. `docs/loop-spec/orchestrator-port-plan.md` says what to build and
`docs/loop-spec/orchestrator-port-followup.md` says what is still open. This document
says why. Each rule below names the BMad file that shows the behavior, the loop-spec
behavior it replaces, and the rule loop-spec must satisfy. BMad's files are cited by the
path under its `skills/` directory at commit `abe4eb1`; bmad-loop at `c47333d`.

The numbers these rules explain, all haiku, all accepted: BMad fixed the two-line bug
for 0.23 USD with a 43-line spec in 1.8 minutes. loop-spec at dda2cca fixed it for 1.26
USD with 119 artifact lines in 9.5 minutes across six gate rounds. Same model, same
task, same correct diff. The difference is process shape, and process shape is a set of
decisions this document makes explicit.

BMad is not better at everything. The last section lists what not to copy.

## 1. Decide ceremony after looking, never before

BMad: `bmad-build/step-02-plan.md`, step 3. After the investigation, the lead writes
three facts "as it is now, not as a guess": intent gaps, irreversibles, footprint. If
all three are clean, the spec keeps two sections and the route is oneshot. The
decision is a function of evidence the investigation produced.

loop-spec: `lib/cycle-profile.sh` refuses to lighten without evidence, and the evidence
arrives after the phases it would have skipped. The new probe `lib/graph/probes/oneshot.sh`
is the right shape, but it reads a footprint the spec writer typed. On the dda2cca run
the footprint named a protected test file, and the exit gate bounced the lead twice
for not editing a file the task forbade it to touch.

Rule: the route is computed by a probe from facts the scout wrote to disk, not from
prose the lead retyped. A footprint is the set of files the scout cited with `file:line`
minus the files the task marks read-only. The model may lengthen the route. It may
never shorten it, and it never types the inputs the probe reads.

## 2. One artifact, sized by a proposal, not a gate

BMad: `bmad-build/spec-template.md`. One file. The target is 900 to 1,300 tokens, and
`bmad-build/workflow.md` says "neither limit is a gate." Sections that do not apply are
deleted: "Do not write N/A or None." On the oneshot route the template itself says
which sections to delete.

loop-spec: SPEC.md, PATTERNS.md, PLAN.md, tasks.json, VERIFICATION.md, ITERATION.md,
PROGRESS.md, events.jsonl, decisions.jsonl. The 9 September bug-fix SPEC.md was 111
lines with a synthesized interview transcript. At dda2cca the oneshot spec is 39
lines, and VERIFICATION.md is 80 lines for a two-line diff because the grounding
template has a row per criterion regardless of the change.

Rule: on the short route, one spec and one verification record, and the driver writes
both skeletons so the lead fills values, never shapes. The size of a verification
record scales with the diff, not with the template. A lint that flags a shape the
driver wrote is a driver bug with a test, never a REDO.

## 3. Every line loaded is paid in every session

BMad: `bmad-project-context/references/best-practices.md`, section "Size": "Every line
is paid in every session, and instruction-following degrades as the loaded set grows."
`bmad-build/SKILL.md` is 14 lines: run the renderer, follow the one file it prints.
`bmad-build/workflow.md` forbids loading two step files at once. The renderer
substitutes every configuration token, so the model never reads the configuration.
The whole oneshot path is 475 lines.

loop-spec: the short path loads `skills/cycle/SKILL.md` (223 lines), `skills/spec/SKILL.md`
(209) and the six shared contracts it cites (730), then in a second session
`skills/oneshot/SKILL.md` (114) and its contracts (about 580). Six SessionStart hooks
inject directives before the first prompt. About 1,850 lines. The SPEC session alone
cost 0.50 USD and 49 turns on the two-line fix.

Rule: a line budget per phase, measured by a probe that walks the cites, enforced by a
test. A contract is cited by section, not whole. A directive that does not apply to
the session is not injected: headless sessions get no ad-hoc micro directive, no grill,
no simplicity directive. Instruction-following is the resource these lines spend.

## 4. Investigate in silence, then ask once

BMad: `bmad-build/step-02-plan.md`, step 2: "Do not ask the human during
investigation. When something is unclear, look in the repository, planning artifacts,
or history first." Step 3: "Choices the user would not notice are yours: decide and
record them in the spec." Open questions are one list, presented once at one
checkpoint. There is no score.

loop-spec: SPEC interviews for up to six rounds across four weighted dimensions and
gates on a model-authored number. In autonomous mode the same skill invents the
questions and answers them, then grades itself. `docs/determinism-audit.md` item 1
already names the self-graded gate as a branch selected by judgment.

Rule: an intent gap is a choice the user would notice in the result and the code
cannot settle. Anything else is decided and written down with one line of reason.
Gaps are a list, asked once, and in autonomous mode each gets the recommended answer
in the decision log. Delete the ambiguity scores and the transcript.

## 5. The spec is the implementer's whole brief

BMad: `bmad-build/step-03-implement.md`: "Do not add goal restatements, file lists,
ownership boundaries, investigation detail, acceptance criteria, or CLAUDE.md
house-style rules to the dispatch. The spec is the subagent's sole source of truth."
The handoff is two sentences and a path. The subagent loads the spec's `context:`
files itself; nothing is pasted.

loop-spec: `skills/shared/execute-subagent.md` is 547 lines, and a dispatch binds
engineering directives, stances, and the human-code contract by cite. The
investigation lives in PATTERNS.md, the plan in PLAN.md, the criteria in SPEC.md, and
the worker reads all three.

Rule: a dispatch is a path and one line. Everything the worker needs is in the spec,
or it is not needed. If a contract must bind, it binds by being in the spec's
`context:` list, and that list is short.

## 6. Judge the diff, not the report

BMad: `bmad-build/step-03-implement.md`: "Judge against the diff, not against the
implementation subagent's report." `step-04-review.md` stages the diff to a file,
never pastes it into a prompt, gives reviewers no prior context, and hands the spec's
own claims to one layer only, after that layer has traced the code. bmad-loop's
`verify.py` docstring: "Never trust LLM self-reports."

loop-spec already has this instinct, and it is the best thing in the tree:
`lib/converged-floor.sh` can veto a verdict and never assert one, and
`hooks/team/result-forgery-guard.sh` catches a hand-written result. Keep it. What the
follow-up adds is where the verification runs: between phases, in the driver, on disk,
not by the lead re-reading its own transcript.

Rule: a phase is done when the driver has checked the commit ancestry, a non-empty
diff, and the test command, not when the lead says so. The dispatch event the oneshot
gate requires is self-reported today; a driver-launched session replaces it.

## 7. Triage is a verdict with evidence, then arithmetic

BMad: `bmad-build/step-04-review.md`, Classify. Reviewer severities are discarded. For
each finding the lead goes to the cited line and answers whether the bad outcome
happens. One verdict: high, medium, low, false with a disproof, or maybe-false with
what would settle it. Findings are grouped by root cause, not by file. Routing is by
category: patch, defer, bad spec, intent gap, and the last two revert the code and
re-derive it, because patching over a wrong spec produces incoherent code. Loopbacks
are capped at five. "Reject any finding whose fix is to edit this build's spec."

loop-spec: WP6 adopted the verdict and disproof rule in `lib/review-triage-lint.sh`.
What it did not adopt is the routing. `docs/determinism-audit.md` item 4 still names
severity as the judgment that selects blocking.

Rule: add the four routes. A finding whose root cause is inside the frozen intent
reverts and asks. One whose root cause is in the spec outside the intent reverts,
amends the spec with a change-log entry, and re-implements. Only a trivial, surface-free
fix is a patch. The rest is deferred with evidence.

## 8. Intent is frozen by the human, and nothing later edits it

BMad: the `<frozen-after-approval>` block in `bmad-build/spec-template.md`. Only the
human changes it. Every later step reads it as the goal, and the review's intent-gap
route exists because it cannot be patched.

loop-spec: `feature_title` is immutable and the iterate judge reads it; the oneshot
spec at dda2cca carries an intent block and the exit gate checks it against HEAD.
Good. The full route's SPEC.md has no frozen region.

Rule: the full route freezes SPEC's Goal and Boundary sections at the human gate, and
`lib/artifact-lint.sh` flags a later phase that edits them.

## 9. A mistake becomes a check, never another paragraph

BMad: `bmad-project-context/references/best-practices.md`, "Admit" and "Exclude". A
pitfall earns a line only with observed evidence. "Style rules an agent self-enforces
belong in a formatter, linter, hook, or CI check. Propose the check instead." Every
line faces one question at each write: would removing it change agent behavior?

loop-spec: 194 `LOOP_SPEC_*` variables, 24 guards under `hooks/team/`, six SessionStart
injections, and a contributor rule that says the same thing as BMad's. The 6 September
findings named the pattern: under pressure the model routed around the plugin's own
gates, and the response each time was one more guard plus prose telling the lead about
it. The dda2cca feature run is the latest instance: two directives in one session, and
the model chose the one without a driver call.

Rule: a new guard needs an observed failure and must replace prose, not join it. The
number of injected directives and the number of variables are metrics that go down.
When a guard and a skill disagree, the guard wins by construction, which means the
skill's text about the guard is deleted.

## 10. Customization is layered data rendered into an immutable snapshot

BMad: `bmad/scripts/resolve_customization.py` merges base, team, and user TOML with
declared rules: strings replace, lists append, tables merge, arrays of tables merge by
id. `bmad/scripts/render_skill.py` writes the workflow the model reads as a
content-addressed snapshot with a SHA-256 manifest, so the running text is immutable
and a record can cite exactly which text ran.

loop-spec: `.loop-spec/extensions.json` is additive-only, which is the right authority
boundary. Harness differences live in four prose contracts totaling 887 lines, and the
phase text the model reads is whatever is on disk in the plugin directory.

Rule: harness behavior and project overrides are data merged at render time. The phase
body a session reads is a rendered file with a hash, the record carries the hash, and
the eval driver refuses a record whose hash does not match the tree. This is also what
makes two eval runs comparable.

## 11. Unattended means a terminal status, never a question

BMad: `bmad-build-auto/workflow.md`, HALT. Every unattended run ends by writing a
status and a blocking condition into the spec, even when it halts before a spec
exists, in which case it creates a skeletal one. "Never end your turn to await a
completion notification." No subagents means status blocked, condition named.

loop-spec: `lib/cycle-result.sh` writes a stamped terminal record and the eval detects a
forged one. Good. The dda2cca feature run ended with no record at all because no
cycle began, and nothing denied the stop.

Rule: a headless session ends in a driver-written terminal record or a Stop-hook
deny. There is no third ending. The invocation stamp already exists; the deny reads it.

## 12. The orchestrator is outside the model and re-derives the truth from disk

bmad-loop: `engine.py` docstring: "The engine never edits sprint-status.yaml or spec
files; it re-reads them to decide and verify. All creative work happens inside
disposable adapter sessions." `sprintstatus.py`: one writer, idempotent, never
regresses. `statemachine.py`: a 57-line transition table that raises on any illegal
move.

loop-spec at dda2cca: the loop left the lead, and `lib/graph/driver.py` walks the graph.
What remains in the lead is the session spawn for the session rung and the between-phase
verification. `graph/cycle.graph.json` is already a better transition table than
bmad-loop's, because its edges carry probe conditions.

Rule: the driver launches sessions, verifies between them, and writes state. The lead
answers questions, enters worktrees, and runs one phase body. When you find a mechanical
step in a SKILL.md, it is a driver feature that has not been written yet.

## What not to copy

- **Prose guardrails.** BMad's HALTs, "never auto-push," and "never skip steps" are
  instructions. Haiku skipped the whole bmad-build workflow on one of two identical
  runs. loop-spec's hooks are the reason to keep loop-spec.
- **No delivery.** BMad and bmad-loop end at a local commit. DELIVER stays.
- **Minimum-finding floors.** BMad's blind-hunter layer must find at least N issues by
  a formula. That is how a false off-by-one about newline counting became a durable
  backlog entry. A reviewer with a quota invents findings.
- **Self-reported subagent use.** bmad-build cannot tell whether its reviewers ran.
  loop-spec's dispatch telemetry is better and should become driver-observed.
- **Five personas and a PRD chain.** Your readers are agents; humans audit the
  decision log. The planning skills add reading, not decisions.
- **The runtime floor.** BMad requires uv and Python 3.11 for every skill. loop-spec's
  bash, jq, and Python 3.7 floor stays, with the vendored session layer behind the
  existing `extensions/` exception.

## The one-sentence version

BMad spends tokens on looking at the code and deciding once; loop-spec spends them on
describing the process to the model and then checking whether the model described it
back correctly. Move every description into the driver, every check onto the disk, and
every decision after the evidence, and the numbers converge.
