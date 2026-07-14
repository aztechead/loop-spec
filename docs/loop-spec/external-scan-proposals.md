# External scan — eval-guide + CLAUDE.md-retro proposals

**Status:** draft proposals (2026-07-13). Nothing here is committed work; every item
goes through the cycle when picked up.

**Sources scanned:**

1. [Netflix/metaflow-nflx-extensions `CLAUDE.md`](https://github.com/Netflix/metaflow-nflx-extensions/blob/main/CLAUDE.md)
   — the file is entirely an auto-generated `<!-- claude-retro-auto -->` block:
   model-authored qualitative lessons mined from past sessions, appended into a
   human-owned instructions file by a retro automation.
2. [microsoft/eval-guide](https://github.com/microsoft/eval-guide) — a Claude Code
   plugin implementing Microsoft's 10-step agent-eval playbook: versioned eval
   sets, gates vs regression suites, baseline comparison, grader validation,
   failure triage with a two-bucket root-cause taxonomy, and a 5-pillar × 5-level
   maturity scorecard.

**Fit:** loop-spec already owns the *learning* loop (retro/rules, closed template
set) and the *authority* loop (trust.sh). What eval-guide has and loop-spec lacks
is the *evidence* loop: acceptance criteria that persist as versioned, re-runnable
eval assets with per-case history, plus calibration evidence for the LLM judges
whose verdicts gate ships. The CLAUDE.md contributor rule "don't restructure
tested skill content without eval evidence" currently has no harness behind it —
these proposals build one.

---

## Proposals

### E1. Feature eval sets as versioned artifacts (SPEC → eval set)

**Source:** playbook Steps 2–4 — one eval set per capability dimension, versioned,
each case tagged by intended use (gate / regression / both).

**Gap:** SPEC acceptance criteria become ephemeral verify probes (the C1
live-verify rung) and die with the run. There is no per-case artifact, so nothing
can be re-run after merge, compared across runs, or accumulated into a regression
suite.

**Mechanism:** `lib/eval-set.sh` (new). During SPEC, acceptance criteria are also
emitted as a machine-runnable eval set — one case per criterion:
`{id, criterion, command, expect, use: gate|regression}` — written to the feature
dir and committed alongside run digests
(`docs/loop-spec/telemetry/evals/{slug}.json`) so it survives volatile agents.
VERIFY runs gate cases; `regression` cases become the durable suite that E3
scopes and `/loop-spec:watch` can re-run post-merge. The model authors cases
inside SPEC where the existing critique gate + human review already inspect them;
execution and recording are script-only. Degrades to today's behavior when a
criterion has no runnable probe (case recorded as `manual`).

**Tests:** schema unit tests; generate→run→record round-trip on a fixture repo.

### E2. Baseline comparison — four-bucket per-case delta in VERIFY

**Source:** rerun protocol + baseline-comparison workbook — every case vs the
prior run is exactly Pass-Pass, Fail-Pass, Pass-Fail, or Fail-Fail; Pass-Fail
(regression) is highest priority; never re-run only the failing cases.

**Gap:** VERIFY's signal is boolean ("suite green"). Run digests reserve
verify-failure classes (ROADMAP-3.0 B1) but nothing computes a per-case delta, so
a fix that breaks two previously-passing cases looks identical to progress.

**Mechanism:** `lib/eval-set.sh run` records per-case results with timestamp +
commit into the feature's eval history; `lib/eval-set.sh delta` prints the four
buckets vs the previous recorded run. VERIFY treats any Pass-Fail as a hard stop
(fail-closed, same placement rule as trust: the script decides, prose can't talk
past it). The bucket counts land in run digests — raw signal for retro (recurring
Pass-Fail classes) and trust (D1 already consumes digest facts).

**Tests:** table-driven delta computation; regression-blocks-verify predicate.

### E3. Change-scoped rerun protocol

**Source:** the rerun-protocol trigger table — change type determines *which
subset* re-runs, not just whether to run; trust-and-safety/impacted sets first.

**Gap:** every VERIFY runs everything (or, for `/micro`, nearly nothing). No
deterministic mapping from what changed to what must re-run.

**Mechanism:** reuse the D2/D3 deterministic diff classifier (already planned as
the auto-merge guard) as the scoping seam: docs-only diff → skip the live rung;
lib change → full suite + all eval sets touching that lib's features; skill-text
change → the dogfood evals for that skill (E7). Mapping lives in a versioned conf,
decision in a script, fail-closed to "run everything". Invariant carried over
verbatim: a scoped re-run always includes the previously-passing cases in scope —
never only the failures.

**Tests:** classifier→scope golden files; fail-closed default.

### E4. Failure root-bucket taxonomy (eval-setup vs agent-quality)

**Source:** playbook Step 7 — every failure lands in exactly one of two buckets:
*eval-setup problem* (the output is acceptable; the test/probe/rubric is wrong →
fix the eval) or *agent-quality problem* (real defect → log the pattern, fix,
regression-proof).

**Gap:** the iterate judge classifies *which phase* leaked a gap (spec/plan/
execute) but not the orthogonal question of whether the check itself was wrong.
Today a bad probe gets silently "fixed" by weakening it, indistinguishable from a
real fix.

**Mechanism:** when VERIFY/ITERATE resolves a failure, the resolution records the
bucket in `events.jsonl` (closed enum, two values). Retro gains a deterministic
detector: the same eval-set case flipping to eval-setup ≥ N times → rule candidate
"probe quality" (template-set addition, same only-tightens construction). This is
also the honest ledger for weakened tests — the existing test-tamper scan catches
deletion; this catches rationalized loosening.

**Tests:** enum-closed event schema; retro detector fixture corpus.

### E5. Judge calibration record

**Source:** playbook Step 6 — "every pass rate inherits the credibility of the
grader that produced it"; LLM judges must carry a validation record (agreement
with human labels, date last checked) before their scores gate anything.

**Gap:** loop-spec's critique gates and the iterate judge are LLM graders whose
verdicts gate ships, with zero calibration evidence. Trust (D1) tracks *outcomes*
(post-merge fixups) but never attributes them back to the judge that said ACCEPT.

**Mechanism:** no human-labeling ceremony — reuse signals that already exist as
disagreement events: a `/loop-spec:revise` that reverses a gate verdict, a
post-merge watch fixup touching files a verifier accepted, a human rejecting a
checkpoint PR. `lib/status.sh stats --json` grows per-gate disagreement counts;
retro emits a *suggestion* (never auto-applied) when a gate's disagreement rate
crosses a threshold — e.g. "verify acceptance gate overridden 3× this quarter;
consider raising its model tier or adding a probe". Read-only telemetry first;
any tuning stays inside the B2 template construction.

**Tests:** disagreement-event derivation unit tests; stats schema pin.

### E6. Maturity scorecard (`/loop-spec:status orient`)

**Source:** the 5-pillar × 5-level per-agent maturity model — an outcome
scorecard, deterministic, showing where you stand and what the next level
requires; explicitly separate from the process itself.

**Gap:** `/status` reports run-level facts and trust reports authority, but
nothing tells a repo owner "here is your loop discipline, here is what unlocks
next." Adoption guidance lives only in prose (`docs/adopting.md`).

**Mechanism:** `lib/status.sh orient` — a deterministic scorecard computed
entirely from files and telemetry, one row per pillar, loop-spec-native pillars:
*criteria* (grill/spec usage, eval sets present per E1), *evidence assets*
(committed eval sets + digests), *lifecycle* (live rung enabled, watch recipe
installed), *learning* (RULES.md populated, retro cadence), *change confidence*
(trust level, baseline history depth). Each row: current level, evidence line,
next-level requirement. Pure read-only; complements trust.sh (authority earned)
with capability (discipline practiced). No dashboards, no HTML — a table.

**Tests:** table-driven level computation from fixture repos; empty-repo = all-L1
invariant.

### E7. Dogfood eval suite for loop-spec's own skills

**Source:** eval-guide dogfoods itself — its repo carries `evals/eval-plan.md` +
`evals/test-cases.json` for its own skills.

**Gap:** CLAUDE.md's "don't restructure tested skill content without eval
evidence" has no harness. Skill-text changes are currently guarded only by
structural tests (frontmatter, coverage pins), not behavior.

**Mechanism:** `evals/` at repo root: an eval plan + scenario cases for the
highest-risk skill behaviors (intake classification, iterate judge verdict on
fixture gaps, retro threshold decisions, micro stop-guard). Runner is the
existing headless pattern (`claude -p` / `pi -p` via `lib/harness.sh cli`) —
LIVE and opt-in exactly like `tests/e2e/`, never part of the default offline
suite. E3's classifier maps skill-file diffs → the eval cases that must re-run,
which is the enforcement teeth for the CLAUDE.md rule.

**Tests:** the suite *is* the test; offline schema check on `test-cases.json`.

### N1. Model-authored retro suggestions — quarantined tier + fenced block

**Source:** the Netflix `CLAUDE.md`: an automation appends model-authored
behavioral lessons ("check the data source first", "when the user says 'do it',
work autonomously") inside `<!-- claude-retro-auto -->` markers in a human-owned
file.

**Gap (and the line not to cross):** loop-spec's retro auto-apply is deliberately
a closed template set — the model cannot author rule text on the autonomous path,
and that stays. But the *suggestion* tier is also template-only today: qualitative
lessons visible in ITERATION.md, review findings, and DECISIONS (the exact class
Netflix captures) have no channel into retro at all.

**Mechanism:** a third finding kind in `/loop-spec:retro report`:
`proposed-candidate` — model-mined free-text lessons from the run corpus, written
ONLY into RETRO.md's dated section, each with its evidence pointer. They are
never auto-applied, never injected, and `retro apply` ignores them; promotion is
an explicit human `/loop-spec:rules add`. Borrow the fenced-marker mechanic for
the file surface: proposed candidates live inside a
`<!-- loop-spec-retro-proposed -->` block that the next retro run may rewrite
(drop stale, keep unpromoted), so automation curates its own region without ever
touching human-authored text — today's append-only bullets can't retract a stale
suggestion.

**Tests:** apply-ignores-proposed predicate; marker-block rewrite idempotence;
the existing closed-template test must keep passing untouched.

---

## Considered and rejected

- **Risk-tier-driven gate strictness** (playbook Step 1's five risk factors →
  stricter gates): re-treads the rigor dial declined in v2.10; modelTier +
  tier-inference already cover the useful part.
- **Netflix's individual lessons as rules:** already codified — probe-before-assert
  covers "check the data source first"; the `autonomous` token covers "'do it'
  means don't ask"; grill covers "validate the core problem before big rewrites".
  The portable idea is the *channel* (N1), not the content.
- **Trust-and-safety eval sets, CSV contract, docx/dashboard artifacts:** Copilot
  Studio product specifics; loop-spec's guard hooks + test-tamper scan already
  own the safety-check niche, and artifacts stay markdown/JSON per lean-deps.
- **Customer-facing maturity coaching** (formative callouts, orient HTML
  dashboard): only the deterministic scorecard ports (E6); coaching prose is
  model-facing ceremony the plugin doesn't do.

## Suggested release train

Read-only/observation items are safe to ship while 3.0.0 soaks on 2.18; anything
touching the cycle's write path waits behind it.

| Version | Ships | Risk gate |
|---|---|---|
| 2.19.0 | E4 taxonomy + E5 calibration telemetry + E6 scorecard + N1 proposed tier | all read-only additions to events/status/retro report; nothing gates, nothing auto-applies |
| 2.20.0 | E1 eval-set artifact + E2 four-bucket delta in VERIFY | delta starts advisory, flips to hard-stop after one clean self-host cycle |
| 2.21.0 | E3 change-scoped reruns + E7 dogfood suite | scoping fail-closed to run-everything; dogfood suite live/opt-in like e2e |
