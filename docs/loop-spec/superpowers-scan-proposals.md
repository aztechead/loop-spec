# External scan — obra/superpowers (last four months)

**Status:** S1, S2, S3, S4, S5, S6, S7, S9, S10, S11 shipped (2026-08-25).
Identification of the rest stands. S8 (spike/bounded/architectural ceremony)
and the skip list below were not ported.

**Source scanned:** [obra/superpowers](https://github.com/obra/superpowers) at
v6.3.0 (`b36e0829`, released 2026-08-12). Window is 2026-04-25 → 2026-08-25
(four months back from this scan). Releases in that window: v5.1.0, v6.0.0
(the large rewrite), v6.0.1–v6.0.3, v6.1.0–v6.1.1, v6.2.0, v6.3.0. Read from
a full clone of `RELEASE-NOTES.md` plus the current skills
(`brainstorming`, `writing-plans`, `subagent-driven-development`,
`writing-skills`, `test-driven-development/writing-good-tests.md`,
`finishing-a-development-branch`), not from marketing copy.

**Fit:** Superpowers is the skill library loop-spec forked away from. It
optimizes a *session*: bootstrap at start, brainstorm, write a plan a junior
could follow, then a controller dispatches one implementer per task with a
reviewer behind it. loop-spec optimizes a *cycle*: durable `feature.json`,
deterministic probes, four peer harnesses, and a PR-terminated result. The
overlap is the EXECUTE/VERIFY controller. The gap is almost never "a skill we
lack"; it is a *dispatch contract* Superpowers measured on live evals and
loop-spec still pays in pasted context, one-shot retries, and reviewer
coaching.

---

## What loop-spec already has (do not re-port)

Recorded so the list below is not mistaken for a general "Superpowers is
ahead" verdict.

| Superpowers (Apr–Aug 2026) | loop-spec today |
|---|---|
| Brainstorming clarify / one-question-at-a-time | Grill + SPEC Socratic interview (`CHANGELOG` 2.0.0: "adapted from the superpowers brainstorming/clarify pattern") |
| Plan "User decisions (already made)" | `agents/planner.md` + `skills/shared/cycle-resume-escalation.md` (explicitly adapted from Superpowers v6.0.0) |
| Global Constraints + per-task Interfaces | `skills/plan/SKILL.md` Step authoring + implementer brief (`skills/shared/team-prompts/implementer.md`) |
| Project-local worktrees | Cycle startup worktree; global `~/.config/superpowers/worktrees/` already dropped |
| Per-task model tier | `lib/model-tier.sh` — but every tier currently resolves to `inherit` (portable catalogs cannot name a model). Superpowers still *requires* an explicit model on every dispatch to stop silent top-tier inheritance |
| Maker ≠ checker, read-only reviewers | Reviewer tool allow-lists; `hooks/restrict-agent-paths.sh` |
| Durable per-plan progress | Per-feature `feature.json` + `tasks.json` + `task-progress.sh` — already stronger than `.superpowers/sdd/<plan>/progress.md` |
| Ceremony scaling (small vs large work) | `/loop-spec:auto` routes `micro \| debug \| full`. Different taxonomy than Superpowers' spike/bounded/architectural, and auto fails *up*; Superpowers' bounded path still hard-gates on human approval of a short in-chat design |
| Debug before fix | `/loop-spec:debug` (red reproduction before any fix, sibling sweep, BUG.md) is a stricter loop than Superpowers `systematic-debugging` |
| Vendor-neutral action language | `skills/shared/{claude,opencode,adk,codex}-harness.md` + `lib/harness.sh` |
| Skill-behavior evidence | Offline `tests/run-all.sh` + opt-in e2e. Superpowers moved skill tests into a live-session `evals/` submodule (drill); loop-spec already rejected stored maps and extra Python deps for that class of work |
| Forge-agnostic PR creation | DELIVER is GitHub-specific on purpose (`lib/pr-delivery.sh`) |

---

## Not worth porting

These shipped in the window and should stay Superpowers-shaped.

1. **Visual brainstorm companion** (v6.0.0). A Node WebSocket server with
   session-key auth, idle timeout, and browser telemetry. Violates lean-deps
   and has no cycle phase to attach to.
2. **New harnesses** (Kimi, Pi, Antigravity, Devin CLI, Hermes, Grok Build).
   loop-spec's contract is four peer harnesses from one tree. Adding a fifth
   is a product decision, not a skill port, and each one is a coverage suite
   (`tests/*-harness-coverage.test.sh`), not a README install stanza.
3. **Plan-scoped `.superpowers/sdd/<plan>/` workspace** (v6.2.0). Superpowers
   needed this because a shared scratch dir leaked ledgers across plans.
   loop-spec already scopes artifacts per feature slug. Do not add a second
   scratch tree.
4. **Removing named agents in favor of general-purpose + prompt templates**
   (v5.1.0). Opposite of loop-spec's design: role files, tool allow-lists, and
   `hooks/restrict-agent-paths.sh` *are* the discipline Superpowers gave up.
5. **Session-start bootstrap compression / using-superpowers trim** (v6.1.0).
   loop-spec does not inject a methodology primer every session; grill /
   micro / rules hooks are the equivalent and are already opt-in.
6. **Slash-command deprecation** (v5.1.0). loop-spec commands are real entry
   points, not stubs.
7. **"Discard this work" menu removal** (v6.2.0). DELIVER never offers
   discard.
8. **Skills-library recap/persuasion compression** (v6.2.0). House style
   already forbids selling-the-reader prose (`skills/shared/human-docs.md`).
   Do not restructure tested skill content to match Superpowers' table form
   without eval evidence.

---

## Ranked candidates

Ranking is by expected leverage on loop-spec's actual EXECUTE/VERIFY cost and
failure modes, not by how new or well-eval'd the Superpowers change was.
"Worth" here means: a cycle could land it without a new harness, without a
Node runtime, and without reversing a loop-spec invariant.

### S1. File-handoff dispatch (task brief + review package) — **high**

**Source:** v6.0.0 SDD rewrite. Scripts
`skills/subagent-driven-development/scripts/task-brief` and `review-package`.
Superpowers' own claim (eval-backed, harness-dependent): roughly 2× wall-clock
and ~50% fewer tokens vs pasted diffs. The cited mechanism is specific: a
pasted diff parks in the controller's context for the rest of the session;
a reviewer without a file rebuilds `git diff` by hand.

**Gap:** `skills/shared/execute-subagent.md` composes a self-contained prompt
and inlines the task spec. Reviewers are told to run `git show` / `git diff`
themselves (`agents/spec-compliance-reviewer.md`). Everything the lead pastes,
and everything the subagent prints back, stays in the lead context. GDD's
handoff port moves *phase* state as files; per-task review still travels as
prompt text.

**Mechanism:** two small scripts under `lib/` (not a vendored Superpowers
copy): `task-brief` extracts one PLAN task (or `tasks.json` entry) to a
uniquely named file under `.loop-spec/features/{slug}/dispatch/`;
`review-package` writes `git log` + `git diff --stat` + `git diff -U10` for
`BASE..HEAD` to a sibling file. Dispatch prompts carry *paths* plus a one-line
fit and any ruling the brief cannot know. Exact values live only in the brief.
The reviewer is forbidden to re-run git for the same range if the package
exists. One-shot Agent rungs and team `SendMessage` rungs both consume the
same files.

**Why this is the first pick:** Superpowers measured this as the single
biggest reviewer cost. loop-spec's subagent rung is the same shape (lead
drives one-shot Agents, prompt carries the work). It is also the cheapest
to pin: a unit test that a package contains the range, and a skill-coverage
assert that the dispatch template names the path not the diff.

**Tests:** round-trip fixture (PLAN task → brief file → path in a canned
prompt); review-package refuses `HEAD~1` (the Superpowers footgun for
multi-commit tasks); `tests/ponytail-coverage.test.sh` still green (no new
dep).

### S2. Resume-the-implementer fix loop + scoped re-review + breaker — **high**

**Source:** v6.2.0 lifecycle restructure.
`re-review-prompt.md`; rounds 1–3 resume the same implementer; rounds 4–5
fresh implementer on a more capable model; five-round circuit breaker with
controller adjudication.

**Gap:** `skills/shared/execute-subagent.md` re-dispatches a *fresh* one-shot
Agent with findings inlined, capped at `maxRetriesPerTask` (2). There is no
scoped re-review: the next spec-compliance reviewer re-reads the whole task.
On the team / implicit-team rung, `SendMessage` can already resume a named
teammate; the subagent rung cannot, and the skill does not distinguish.
Superpowers' eval note: a loop that survives three resumes usually means the
implementer cannot see its own problem — fresh eyes plus a capability bump
together, not another identical retry.

**Mechanism:** on rungs that have a live agent identity (explicit teams,
implicit named teammates, loop-fleet if the child is addressable), rounds 1–3
`SendMessage` the open findings to that identity; rounds 4–5 spawn fresh on a
higher selector. On one-shot Agent rungs, keep fresh dispatch but feed the
*report file* (S1) as persistent memory and switch to a scoped re-review
prompt that verdicts findings against the fix diff only. A scripted round
counter in `tasks.json` metadata trips a breaker; the lead adjudicates
residuals into the ledger / `warnings[]` instead of spinning.

**Tests:** table-driven round policy (resume vs fresh vs breaker); scoped
re-review prompt coverage (must name FIX_BASE, must not ask for a full-task
re-read). Eval-gated before changing the one-shot retry count, per "skills
are code."

### S3. Worker no-nested-subagents contract — **high / cheap**

**Source:** v6.3.0. Implementers and reviewers may not spawn subagents;
observed duplicate full review seats per task when workers dispatched their
own reviewer.

**Gap:** `agents/implementer.md` allow-list has no `Agent` (good on the named
role). The subagent EXECUTE rung *intentionally* dispatches the **default**
agent with a self-contained prompt (`execute-subagent.md` "Agent dispatch
convention") — that default agent *can* spawn Agent. Reviewer prompts do not
say "do this review yourself."

**Mechanism:** a one-line contract in implementer + both reviewer prompts
and in the default-agent EXECUTE templates: never dispatch a helper or a
reviewer; review arrives from the lead after the report. Optionally add
`Agent` to `disallowedTools` on named implementer/reviewer roles (already
absent from the allow-list; the hole is the default-agent path). Fail-safe:
a hook that denies `Agent` from an implementer/reviewer caller is better
than prose, if the harness exposes the caller role the way
`hooks/restrict-agent-paths.sh` already does.

**Tests:** agent-frontmatter allow-list assertion; EXECUTE template grep that
the no-subagents sentence is present; if a hook lands, a deny-case in the
existing hook suite.

### S4. Controller must not pre-judge reviewer findings — **high / cheap**

**Source:** v6.0.0. Real runs caught controllers coaching "do not flag X" /
"at most Minor"; the flaw shipped. Also: plan-mandated defects are findings
the human (or, in loop-spec, the lead's recorded ruling) adjudicates — they
are not waved through because the plan asked for them.

**Gap:** loop-spec reviewer independence is stated for quality-loop personas.
EXECUTE dispatch templates do not ban pre-rating severity or instructing a
reviewer to ignore a class of issue. `skills/shared/review-prompts/verification-gap.md`
already says "Assign no severity" for that one pass; the spec-compliance
reviewer still returns `pass|rework|block` and the lead can bias the prompt
on retry.

**Mechanism:** a shared directive (one file, like `review-prompts/`) that
EXECUTE, quality-loop, and VERIFY reviewer dispatches include: never "do not
flag", never "at most Minor", never "the plan chose." A finding that
conflicts with plan text is `plan-mandated`; the lead records a ruling
(autonomous: `lib/decisions.sh`; interactive: ask) before acting. Probe, not
judgment: a small grep/lint over dispatch prompt files for the banned
phrases Superpowers named.

**Tests:** `lib/` lint of prompt templates; a fixture prompt containing
"do not flag" fails the lint. Do not put this lint on free-form model output
(that would be a judgment selecting a path).

### S5. "Cannot verify from the diff" verdict + lead resolution — **medium-high**

**Source:** v6.0.0 task-reviewer. Requirements that live in untouched code or
span tasks do not block the rest of the review; the controller must resolve
each one before marking the task complete, because the controller holds
cross-task context the reviewer lacks.

**Gap:** spec-compliance-reviewer is binary `pass|rework|block` on the task
diff. Cross-task and "this requirement is in code this task did not touch"
cases currently collapse into `rework` (false fix loop) or `pass` (silent
gap). VERIFY's whole-branch review is the backstop, but it runs after
EXECUTE has already merged.

**Mechanism:** add a third structured channel `unverified[]` (requirement +
why the diff cannot show it). The lead must either confirm from the plan /
prior tasks (treat as `pass` with a ledger note) or promote to `rework`.
Do not let `unverified` items evaporate.

**Tests:** schema on the reviewer result object; lead procedure coverage in
`execute-subagent.md` / team reviewer prompt; a fixture where the only
failing criterion is outside the diff.

### S6. Rulings, not stalls, for non-catastrophic plan conflicts — **medium-high**

**Source:** v6.3.0. One donated session sat blocked ~9 hours on a question
the controller could have decided. Four things still stop the run:
irreversible/destructive, security-sensitive, side effect outside the
worktree (merge/push/publish), and a plan so broken every path is a guess.
Everything else: decide, ledger `Ruling: <what> — <why> — <what it costs if
wrong>`, continue. Pre-dispatch conflict scan writes a *table* of what was
checked (task pairs sharing a file/interface, per-task self-agreement);
"the scan is clean" without rows is not a scan.

**Gap:** autonomous mode already self-answers and records via
`lib/decisions.sh`. Interactive EXECUTE still escalates on ambiguity
(`skills/shared/cycle-resume-escalation.md`). Superpowers made *ruling the
default even when a human is present*, because the stall cost the human's
day. loop-spec's interactive default is the opposite: stop and ask. The
port is not "always autonomous"; it is a narrower class: plan-internal
conflicts and reviewer/plan contradictions that are reversible in git.

**Mechanism:** reuse `lib/decisions.sh` with a `ruling` kind for EXECUTE.
Interactive style still stops for the four Superpowers stop-reasons (map
onto existing escalation reasons). For the rest, record the ruling in
feature state and continue. Pre-flight scan: EXECUTE already computes
file-overlap `blockedBy` edges (Step 2b) — extend that scripted pass to
emit the conflict table into the feature dir so the lead cannot skip it.
The table is the probe; the ruling is still a model judgment *after* the
probe.

**Tests:** file-overlap table golden; autonomous vs interactive stop-reason
matrix (four stop, everything else records a ruling). Eval-gated if it
changes when interactive EXECUTE asks a question.

### S7. Same-shape micro-task batching — **medium**

**Source:** v6.3.0. Several small independent edits of the same kind (same
one-line fix, constant change, field addition) become one dispatch; the
review checks every file in the brief made it into the diff. Superpowers
still forbids parallel *implementation* subagents (conflict risk);
loop-spec already parallelizes on DAG width via worktree isolation.

**Gap:** loop-spec batches by DAG width and file-overlap, not by *shape*.
A plan of twenty identical one-line edits is twenty implementer seats.

**Mechanism:** a planner/EXECUTE seam, not a new skill. Optional planner
hint `batchGroup` on tasks that share verify command, file-glob class, and
no independent judgment; EXECUTE collapses a group into one brief listing
every file. Reviewer asserts every listed file appears in the diff (script:
`git diff --name-only` ⊇ brief files). Fail-closed: missing hint = today's
one-task-one-dispatch. Do not batch across `blockedBy`.

**Tests:** collapse predicate; review-package name-list inclusion; no
collapse when `blockedBy` or files overlap a different group.

### S8. Three-path SPEC ceremony (spike / bounded / architectural) — **medium**

**Source:** v6.3.0 brainstorming. Classify out loud before the first
question; ceremony scales, the approval gate never does. Spike → answer,
throwaway labeled; bounded → short design *in chat*, hard stop for yes, no
spec file; architectural → full spec + writing-plans. Ratchet is one-way:
hidden complexity upgrades the path mid-task. "I understand this kind of
app, so it's bounded" is a named red flag — bounded measures the *repo*
(an existing flow to change), not familiarity.

**Gap:** `/loop-spec:auto` is the closest analog (`micro | debug | full`)
but it classifies *which loop to run*, not *how much design ceremony
inside SPEC*. `micro` states done-criteria and goes (one question); it
does not present a short design and stop. Superpowers' interesting
invariant is: even a two-sentence design is gated on an explicit yes.
loop-spec autonomous / auto mode is question-free by contract, so a hard
approval gate cannot apply on that path.

**Mechanism if picked:** teach `auto` (or SPEC Step 0) the three-path
labels as a *narrated classification* that still routes through existing
skills: spike → not a cycle (report + throwaway); bounded → `micro` *plus*
an interactive approval of the in-chat design (skipped under `autonomous`);
architectural → full cycle. Keep auto's fail-closed promotion (uncertain →
full). Do not invent a fourth loop.

**Tests:** classification examples as fixtures in `auto` (existing JSON
decision object gains an optional `ceremony` field); autonomous skips the
bounded approval; mid-task upgrade to full is already auto's fail-up.

**Tension to decide in review:** loop-spec's product bet is unattended
correctness. Superpowers' product bet is a human who stays in the design
loop. Porting the approval-never-scales rule into interactive SPEC is
cheap and compatible. Porting it into `auto`/`autonomous` fights the
autonomous-mode contract.

### S9. `writing-good-tests` falsifiability catalog — **medium**

**Source:** v6.2.0. `testing-anti-patterns.md` rebuilt as a positive
catalog. Gate function: before the test body, name the production change
that should fail it; derive expectations independently of the code under
test; close the string-presence trap (behavior, never source text) and the
change-detector trap (a constant assertion can fail and still protect
nothing). Trivial code and human prose earn no test. Trigger broadened from
"adding mocks" to any test writing.

**Gap:** loop-spec has `docs/loop-spec/planner-antipatterns.md` (banned
subjective *acceptance-criteria* phrases) and
`skills/shared/review-prompts/verification-gap.md` (would a use-site break
be caught). Neither is a test-*authoring* skill for implementers. TDD is a
conditional step in `agents/implementer.md` ("If task says TDD").
Implementers can still write grep-the-skill-file tests and constant
assertions; VERIFY's tamper scan catches deleted tests, not vacuous ones.

**Mechanism:** a shared reference loaded by implementer prompts (not a new
slash skill; new file under `skills/shared/` if this item is picked).
Keep Superpowers' two named traps; replace any Superpowers-specific
"documents that instruct agents are tested by the consuming agent's
behavior" with loop-spec's existing "skills are code / eval evidence"
rule. Optional: a cheap probe that flags tests whose only assertion is
`grep`/`contains` on a fixture the test itself wrote — only if it can
be deterministic.

**Tests:** implementer prompt wiring (`tests/human-code-coverage.test.sh`
pattern); do not restructure TDD skill flow without eval.

### S10. Transcription-tier implementers when the plan carries complete code — **medium**

**Source:** v6.0.0 eval ladder (E03). When the task text contains the
complete code to write, implementation is transcription plus testing: use
the cheapest tier. Turn count beats token price: cheapest models on
multi-step *prose* tasks take 2–3× turns and cost more overall, so
mid-tier is the floor unless the plan is complete code.

**Gap:** `lib/model-tier.sh` currently prints `inherit` for every tier
because a portable catalog cannot name a model. The *policy* Superpowers
learned is still missing: planner should mark `modelTier: mechanical`
when the task is transcription, and EXECUTE should treat that as "cheapest
available on this harness" rather than session inherit (which is often the
most expensive).

**Mechanism:** do not resurrect hardcoded model IDs. Extend
`lib/model-tier.sh` to resolve `mechanical` to the harness's cheapest
*alias* from `skills/shared/model-matrix.md` / runtime probe, and keep
`standard`/`frontier` as today. Planner guidance: complete-code tasks get
`mechanical`; prose-spec tasks do not. Explicit `model` pin still wins.

**Tests:** extend `tests/lib/model-tier.test.sh`; planner prompt coverage
for when to set the tier. Harness-coverage: every harness that cannot name
a cheap alias still inherits (fail-safe).

### S11. Worktree remove: never `--force` on untracked files — **medium / cheap**

**Source:** v6.3.0 finishing-a-development-branch. When `git worktree
remove` refuses because of uncommitted/untracked work, stop, name the
files, and ask. `--force` was destroying work that existed only in that
tree (`#2016`, `#1223`, `#2024`).

**Gap:** `lib/git-ops.sh` uses `git worktree remove --force` on *failed
create* rollback (justified: the add never finished). CONCERNS.md already
flags EXECUTE post-wave cleanup and orphan-prune as `--force` on trees that
may hold untracked files. `integrate-task.sh --cleanup` is the success
path; failed tasks are supposed to be preserved, but orphan prune is not.

**Mechanism:** split "rollback a partial `worktree add`" (keep `--force`)
from "remove a task worktree after merge or on prune." The latter: try
without `--force`; on refusal print the dirty/untracked list and leave the
tree (or escalate). Never `rm -rf` a worktree that had a successful
checkout.

**Tests:** `lib/git-ops.sh` / `integrate-task.sh` cases: clean remove
succeeds; dirty tree is refused and listed; partial-add rollback still
`--force`.

### S12. Pre-flight plan conflict table before Task 1 — **low-medium**

**Source:** v6.0.0 / v6.3.0. Before dispatch, scan for tasks that contradict
each other or Global Constraints, and for anything the plan mandates that
the review rubric treats as a defect. Output is a table, not a verdict.
v6.3.0 requires the checks to be *recorded*.

**Gap:** PLAN already runs a critique gate (challenger, optional advocate
debate). EXECUTE Step 2 detects file overlap. Neither produces a
controller-side "I looked at these pairs" artifact, so a lead can skip the
read and start Task 1.

**Mechanism:** if S6's overlap table lands, this is that table plus a
second scripted pass: `lib/plan-adherence.sh` (already extracts task IDs)
grows a `conflicts` subcommand that lists file-sharing pairs and
interface consume/produce mismatches from `tasks.json`. The lead must write
rulings into feature state before dispatch. "Scan clean" without rows
fails the probe.

**Tests:** golden `tasks.json` with a consume/produce mismatch; empty table
on a disjoint fixture.

### S13. Match-form-to-failure + micro-test wording (skill authoring) — **low** (contributor-facing)

**Source:** v6.0.0 writing-skills. A flat "don't do X" works for discipline
slips and *backfires* when the failure is the shape of an output (worked
example wins; prohibition arm was worse than no-guidance control in their
wording tests). Micro-test: sample a phrasing a handful of times against a
no-guidance control, read every result by hand, treat variance as a warning.

**Gap:** `CLAUDE.md` already says "don't restructure tested skill content
without eval evidence" and "probes, not judgments." There is no form-
selection table for authors of new skills, and no cheap wording probe
recipe. Superpowers' finding is directly useful the next time someone
edits EXECUTE templates.

**Mechanism:** a short section in `skills/shared/human-docs.md` (or a
contributor-only page linked from CLAUDE.md) with the four-row form table
and the micro-test recipe. Not a user-facing skill. Does not change any
tested SKILL.md body.

**Tests:** none required if it is contributor docs only; `lib/doc-tells.sh`
must still pass.

### S14. Reviewer re-reads evidence, does not re-run the implementer's suite — **low-medium**

**Source:** v6.3.0. Reviewers who find evidence illegible re-read it rather
than re-running the test suite. Controller must not ask a reviewer to
re-run tests the implementer already ran on the same code; the report
carries the evidence.

**Gap:** spec-compliance-reviewer procedure includes running/reading verify
output. That is sometimes right (maker ≠ checker on the oracle) and
sometimes waste (double suite). loop-spec's post-merge `verifyCommand` on
the integrated candidate (`integrate-task.sh`) is the real oracle; the
reviewer's re-run is extra.

**Mechanism:** if S1 lands, the report file holds the command + output; the
reviewer judges that evidence and the diff. Illegible evidence → ask the
lead for a fresh capture, do not re-run. Keep `integrate-task.sh`'s
verify-before-publish as the scripted double-check.

**Tests:** reviewer prompt coverage; do not remove `integrate-task.sh`
verify.

---

## Suggested first PR (if we pick a bundle)

Shipped in one implementation change: **S1, S3, S4, S11** (the original first
bundle) plus **S2, S5, S6, S7, S9, S10**. S8 remains a product decision about
interactive vs autonomous. S12's table is S6's `lib/plan-conflicts.sh`. S13 is
contributor-facing and unpicked. S14 folded into S1's reviewer contract (the
report file holds evidence; `integrate-task.sh` remains the scripted oracle).

## What this scan did not do

- Did not re-run Superpowers' evals; token/wall-clock claims are theirs,
  cited as claims.
- Did not score v5.0.x (March 2026, outside the four-month window) except
  where v5.1.0/v6.0.0 completed that work.
- Did not propose porting Superpowers' live `evals/`/drill harness; see
  `docs/loop-spec/external-scan-proposals.md` (eval-guide) for loop-spec's
  own evidence-loop design.
