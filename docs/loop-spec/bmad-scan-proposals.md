# External scan — BMAD-METHOD

**Status:** audit + shipped imports (2026-08-05). Items marked *shipped* are in this
repository; items marked *proposal* are not committed work and go through the cycle when
picked up.

**Source scanned:** [bmad-code-org/BMAD-METHOD](https://github.com/bmad-code-org/BMAD-METHOD)
v6.10.0 at `05e295f`, read from a full clone rather than its documentation. BMAD v6 is
skill-based like loop-spec: `src/core-skills/` and `src/bmm-skills/` hold `SKILL.md` +
`customize.toml` + step files, installed by `npx bmad-method install` and rendered through
`src/scripts/render_skill.py`. Prerequisites are Node 20.12+, Python 3.10+, and `uv`.

## Fit

The two projects solve the same problem from opposite ends, and each is thin exactly where
the other is strong.

BMAD optimizes the **human–AI collaboration surface**. Its agents are named characters with
written voices (`src/bmm-skills/module.yaml`), its planning skills are facilitation flows
that refuse to generate without user input, its review output is built for a person to walk
through, and almost every behavior is overridable by a project without forking anything.

loop-spec optimizes **unattended correctness**. Its authority decisions are unit-tested
scripts, its gates are deterministic, its state is resumable, its result contract is
machine-readable, and its ladders are bounded so a run ships or escalates rather than
looping. The human is asked for as little as possible.

That difference explains the whole audit. Everything loop-spec is missing is on the human's
side of the seam: what the reviewer receives, what a team can change without forking, and
whether the context loaded into every design phase is still true.

## What loop-spec already does, and does better

Recorded so the imports below are not mistaken for a general verdict.

| Concern | BMAD | loop-spec |
|---|---|---|
| Work decomposition | Stories in prose, with the rule "stories MUST NOT depend on future stories" stated as a directive (`plan/bmad-create-epics-and-stories/steps/step-03-create-stories.md`) | A task DAG with explicit `blockedBy` edges, per-task verify commands, and synthetic edges derived from `files[]` overlap — the constraint is structural, not asked for |
| Autonomy | No governor; a human drives each workflow | `lib/trust.sh` computes an earned level from committed git/CI facts; `lib/autonomous-chain.sh` bounds chaining; acting scripts obey exit codes |
| Memory | One append-only `.memlog.md` per run (`src/scripts/memlog.py`) | Eight typed append-only ledgers — `events.jsonl` alone carries 12 event kinds — plus `EVIDENCE.md` with machine-checked `EVID-NNN` grounding |
| Maker/checker | Context-free review subagents by convention | Same, plus tool-level enforcement: reviewer agents have no `Write`/`Edit` in their allow-list |
| Machine consumption | Workflows end by talking to a person | `result.json` schema 1, `LOOP_SPEC_RESULT {...}`, `events.jsonl`, and per-run digests |
| Resumability | Resume by reading the memlog | Durable `feature.json` + `PROGRESS.md` + atomic writes; DELIVER is idempotent against an existing PR |
| Portability | Web bundles for Gemini/ChatGPT | One source tree installs to Claude Code, pi, and opencode with a tested harness seam |

BMAD's memlog is a good idea that loop-spec independently landed harder. Its persona voices
are the most visible thing about it and the least portable — loop-spec's roles are already
separated by tool allow-list and model tier, which is what actually changes behavior.

## Shipped in this change

### B1. The reviewer's guide — `lib/review-trail.sh`, `skills/walkthrough/` *(shipped)*

**Source:** `ship/bmad-build/step-05-present.md` ("Suggested Review Order": stops ordered by
concern, entry point first, peripherals last, ≤15 words of framing each, clickable
anchors) and `ship/bmad-checkpoint-preview/` (the same trail presented as a guided human
walkthrough).

**Gap:** the PR body is an index, not a tour. `lib/pr-body.sh` renders a fixed section set —
Goal, Summary, Acceptance criteria, Spec quality, Verification, Convergence, warnings, and
a flat bullet list of artifact paths — and states its own contract as "bounded excerpts,
never whole artifacts". Nothing in `lib/`, `agents/`, or `skills/` produces a reading order,
a "start here", or a mapping from diff hunks to spec intent. After seven phases of machine
rigor the reviewer re-derives, unaided, structure the loop already knew. Nothing on
ROADMAP-3.0 addresses this: all four pillars move work *away* from the human.

**Mechanism:** `lib/review-trail.sh surface` reports the change surface as facts — per file,
`core` or `peripheral` by path rules, the anchor line of its first change, and churn. The
concern grouping and the framing prose stay model work, which is correct: which files
changed is a fact, why they belong together is a judgment. `lib/review-trail.sh lint` then
measures the written trail against the diff: every core file has a stop, every stop
resolves to a real `path:line` inside the surface, framing is within the word cap, and no
peripheral stop precedes the last core stop. The `uncovered` finding is the important one —
a guide that silently omits part of the change is worse than no guide, because it reads as
complete.

**Deliberate non-gate:** a missing or failing trail never blocks delivery. Blocking a
verified change over prose would cost a reviewer more time than the trail saves.

**Fail-safe:** in a repo whose product is markdown or config — this plugin is one — every
file would classify peripheral, which would tell a reviewer the change has no substance.
The classification stands down and says so instead.

### B2. The verification-gap pass — `lib/verification-gap-scan.sh` + review prompt *(shipped)*

**Source:** `ship/bmad-build/review-prompts/verification-gap.md`, the most portable single
artifact in the BMAD tree: one question ("if the behavior this change produces broke where
it is used, would verification fail?"), three named gap shapes, and hard evidence rules.

**Gap:** loop-spec's verification defenses each answer a different question.
`lib/test-tamper-scan.sh` defends existing tests against deletion, skip annotations, and
swallowed exit codes. `lib/criteria-coverage.sh` checks that criteria carry verify commands.
`lib/verification-grounding-lint.sh` rejects ungrounded *claims about the review itself*.
`agents/code-reviewer.md` lists "missed test coverage" as one Important-bucket item. None
traces new behavior out to the sites that observe it, so a change can ship green with its
behavior pinned nowhere.

**Mechanism:** the BMAD prompt instructs the reviewer to "search the whole repo by the
symbol under test and by import references" before claiming no test exists. That is a model
performing a search from memory to select a finding — exactly the shape this repository
turns into a probe. `lib/verification-gap-scan.sh` extracts the definitions the diff added
or edited in non-test files and reports, per symbol, which test files name it and how large
the corpus searched was. The corpus is the *post-change* tree, so a test added by the same
diff counts as the evidence that closes the gap.

The prompt (`skills/shared/review-prompts/verification-gap.md`) is explicit that the probe
answers reachability of a name and nothing else: `covered=no` is a starting point, not a
finding, and `covered=yes` is not proof, because a test that names a symbol may assert
nothing about the behavior that changed. Whether an assertion would fail stays judgment.

### B3. Extension points as data — `lib/extension-points.sh` *(shipped)*

**Source:** BMAD's `customize.toml` layer — every skill ships defaults, a project overrides
them in `_bmad/custom/<skill>.toml`, and `resolve_customization.py` merges base → team →
user. Review layers are *data*: `[[workflow.review_layers]]` entries with an `id`, a `when`
gate, and an `instruction` that can dispatch a subagent or shell out to an external
reviewer. `activation_steps_prepend/append` inject instructions around a skill's activation,
and `persistent_facts` names files loaded as standing context for a whole run.

**Gap:** loop-spec is configurable but not extensible. `.loop-spec/workflow.json` consumes
exactly three keys. `lib/tuning.sh` is a deliberately closed template set. `RULES.md` is
session-global prose, never phase-scoped, and its `--check "<cmd>"` is recorded as text that
nothing executes. A team wanting one review layer of its own, or one standing fact in front
of every planner, has no move short of forking the skill markdown.

**Mechanism:** `.loop-spec/extensions.json` declares `reviewLayers[]` (id, name, promptFile,
phase, enabled), `phaseInstructions.<phase>.{prepend,append}`, and `persistentFacts[]` with
`file:` globs resolved to real paths before a phase sees them.

**Where this diverges from BMAD, deliberately:** extensions *add*, never subtract. BMAD lets
a user set a review layer's `instruction` to empty and switch it off; loop-spec must not,
because its gates are what let the loop act without a human — a config that could disable
one would be an authority control wearing an accelerator's clothes. `validate` refuses any
layer claiming a built-in gate id, the layer count and instruction length are capped so a
config cannot quietly become a context budget, and a test asserts that no authority script
(`trust.sh`, `autonomous-chain.sh`, `task-route.sh`, `execute-rung.sh`) reads the file.

Read paths fail **open** — a malformed config yields no extensions and a stderr note, never
a blocked phase. `validate` fails **closed**, so a project can find out on purpose. That
split is the existing "fail-open accelerators, fail-closed authority" rule.

### B4. Map audit — `lib/map-audit.sh` *(shipped)*

**Source:** `plan/bmad-project-context/`, whose governing thesis is stated as measured, not
asserted: *"generated documentation makes agents worse; a curated minimum of verified,
non-derivable truths makes them better."* Its context system is a size-budgeted kernel plus
a bundle where every entry is marked `verified` (a human confirmed it) or `generated` (the
model inferred it), `sweep` path-checks every claim, and `audit` **must end smaller or
equal, never larger**. See *The map challenge* below.

**Gap:** the codebase map is loop-spec's one regenerated artifact and nothing measures it.
No size ceiling, no per-claim trust marking, no check that a cited path still exists, and
an index that only ever gains entries.

**Mechanism:** four measurements, no rewriting — what to cut is a judgment and the refresh
path owns it. `budget` totals the map against a ceiling (default 1000 lines, ~20k tokens
across the five domains). `sweep` path-checks every cited path, skipping globs,
placeholders, URLs, and `e.g.` illustrations, because a pattern is not a claim. `orphans`
reports index entries whose file is gone. `staleness` reports per-domain age and — the one
that matters most — flags a document that declares itself STALE while the index records it
as fresh.

## The map challenge

The user asked for this one hard, so: **BMAD's thesis is probably right, and loop-spec's map
is currently evidence for it rather than against it.**

Running the new audit against this repository's own map, unmodified:

```
budget=under lines=902 ceiling=1000     # 70 KB, ~17.5k tokens, loaded into design phases
sweep=stale  checked=49                 # 9 cited paths no longer exist
orphans=28   indexed=76                 # of 447 files in the tree
staleness: all five domains last refreshed 2026-05-12 (85 days)
finding=trust-disagreement docs/loop-spec/codebase/CONCERNS.md
```

Read that carefully. The map asserts `lib/state-write.sh`, `skills/shared/preset-matrix.md`,
`commands/cycle.md`, `commands/map-codebase.md`, `tests/smoke.sh`, and
`tests/lib/state-write.test.sh` exist. None of them do. `TECH.md` describes two Python
fixture files that were deleted. The index still maps fourteen `agents/loop-spec-*.md` paths
that were renamed to bare role names — the rename `CLAUDE.md` itself documents. And
`CONCERNS.md` carries a hand-written "STALE — pre-v1.0.0 snapshot" banner while
`index.json` records that domain as refreshed, so the machine state and the prose disagree
and only the prose is honest.

This is not an argument that mapping is worthless. It is an argument that **generated prose
with no trust marking, no budget, and no verification decays into confident wrongness**,
which is the specific failure BMAD measured. A stale claim in a map is worse than a missing
one: the design phases load it as ground truth and it costs nothing to believe.

Where loop-spec's design is genuinely stronger: it does not rely on the map alone. Graphify
gives the design phases a code graph derived from AST extraction rather than prose, and the
grounding protocol makes external-system premises probe-before-assert with a committed
`EVIDENCE.md` ledger. The map is a navigational aid on top of a real index, not the index.
BMAD has no graph.

Where BMAD is ahead and loop-spec should follow: the **verified/generated distinction**. BMAD
writes `verified` only when a human confirmed the claim, and its auto mode marks everything
`generated` no matter how confident. loop-spec has no such field at any granularity, so a
claim a human ratified and a claim a mapper inferred at 2 a.m. are indistinguishable
forever. B4 measures decay; it does not yet mark trust. That is B6.

**Not proposed:** deleting the map. It is 17.5k tokens against a 200k window, it is the only
artifact carrying cross-cutting concerns the graph cannot express, and the fix for a stale
map is refreshing and pruning it, not removing the navigation.

## Proposals — not implemented

### B5. Skill catalog as data *(proposal)*

**Source:** `src/bmm-skills/module-help.csv` — every skill as a row with a menu code, phase,
`preceded-by`, `followed-by`, `required`, output location, and outputs. It is what lets BMAD
answer "what should I do next?" without a model guessing.

**Gap:** loop-spec has no machine-readable catalog of its own skills. `plugin.json` is
identity only, `package.json` points at a directory, no `SKILL.md` frontmatter declares
phase or ordering, and the README table is the only catalog. `lib/status.sh` prints state
and never recommends an action. The one phase enumeration in the codebase is an
ordering-free `case` guard in `lib/feature-init.sh`.

**Mechanism:** `skills/catalog.json` (or frontmatter fields plus a generator), a
`lib/skill-catalog.sh` reader, and a `/loop-spec:status next` that names the next action
from durable state. A validator test keeps the catalog in step with the directory, the way
`tests/validate-pi-manifest.test.sh` keeps the manifests in lockstep.

### B6. Trust marking on map claims *(proposal)*

**Source:** the `verified` / `generated` frontmatter split above.

**Mechanism:** per-domain frontmatter carrying `trust`, `verifiedAt`, and `verifiedBy`;
mappers write `generated` unconditionally; a human ratifying a domain during `map-codebase`
or `assess` promotes it. `lib/map-audit.sh` grows a `trust` subcommand and reports the
generated share. This is the field that makes B4's decay numbers actionable rather than
merely alarming.

### B7. Fresh-eyes pruning pass over prose artifacts *(proposal)*

**Source:** BMAD's ingest closes with a subagent holding only the written artifacts and the
contracts — none of the authoring conversation — returning proposed cuts, on the stated
grounds that "the writer who just heard every line justified cannot honestly run the pruning
test on it."

**Gap:** loop-spec already has exactly this pass for code. `agents/code-reviewer.md`'s
over-engineering pass ("the diff's best outcome is getting shorter") lists cuts and never
rewrites, and `tests/ponytail-coverage.test.sh` pins it into every code-producing dispatch.
Nothing equivalent exists for SPEC.md, PLAN.md, or the map: those get structural and
grounding lints, which catch malformed and ungrounded content but never *surplus* content.

**Mechanism:** reuse the ponytail construction on prose — a context-free reviewer holding
only the artifact and its template contract, returning `cut:` / `merge:` / `shrink:` lines
with the test each line fails, listing only. It fits the existing maker/checker rule and
needs no new authority.

### B8. Elicitation method catalog *(proposal)*

**Source:** `core-skills/bmad-advanced-elicitation` — a method catalog served by
`pick_methods.py` (`categories`, `list`, `show`, `random --spread`) so it never enters
context whole, behind a stable menu other skills invoke at natural pauses.

**Gap:** loop-spec's SPEC interview runs a fixed perspective per round, hardcoded in
`skills/spec/SKILL.md`, and grill mode asks 2–4 clarifying questions with no catalog behind
it. Both would benefit from a wider bank that stays out of context until selected.

**Considered and not proposed:** BMAD's persona voices and party mode. The voices are
cosmetic, and loop-spec's advocate/challenger debate with an escalation ladder is a stronger
mechanism than a roundtable for the same purpose.

## Defects surfaced by this audit

Not BMAD imports — things the comparison exposed in loop-spec.

**Fixed in this change:**

- **F1. A declared review dimension was never dispatched.** *(fixed)*
  `lib/workflows/code-review-dimensions.js` declared `correctness`, `security`,
  `performance`, `style` and sliced to `params.dimensionReviewers`, fixed at 3, so `style`
  was dead code that read like coverage. The list is now exactly the three dispatched
  dimensions, with a guard that throws if the list and the fan-out ever disagree again.
  `style` stays out deliberately: the code-for-humans pass owns it and is probe-backed by
  `lib/house-style.sh`, which measures the house convention rather than asking a fourth
  agent's taste.
- **F2. `learnings.jsonl` was write-only.** *(fixed)* The SessionEnd hook had appended to it
  since 2.x and nothing ever read it. `lib/retro.sh` now mines it as a third B1 corpus
  alongside the micro-cycle ledger and sentinel history: task types whose sessions
  repeatedly end partial or errored, counted across *distinct* sessions, become a rule
  candidate from a fixed template.

**Open — each needs its own change:**

- **F3. The map index never prunes.** `skills/map-codebase/SKILL.md` updates the index by
  adding domains to a file's entry; there is no removal step, so deleted files keep voting
  on which domains are stale. 28 of 76 entries in this repo are orphans.
  `lib/map-audit.sh orphans` now *detects* this and the map skill is instructed to drop the
  keys, but nothing enforces it — the pruning itself should be a script, not an instruction.
- **F4. `CONCERNS.md` and `index.json` disagree about staleness** (detected by
  `map-audit.sh staleness`); the map is 85 days old against a documented 90-day advisory
  that only warns. Not fixed here on purpose: the honest repair is re-deriving that domain
  with the mappers, and editing the timestamp to match the prose would launder the very
  claim the check exists to catch.

## Portability defects found by running the suite on Linux

Unrelated to BMAD, found because this audit ran `tests/run-all.sh` on a Linux container
and compared against the merge base. All three are fixed; the suite is now green.

- **`skills/loop-runner/tests/run_tests.sh`** probed `.loop/perm-<mode>/result.json` using
  the raw camelCase task id, but `loop.py` slugifies task ids to lowercase
  (`LoopState.resolved_task_id`). The directory was found only on a case-insensitive
  filesystem, so the check passed on macOS and failed on Linux for exactly the three
  camelCase permission modes. The test now resolves the id the way the runner does.
- **`tests/lib/revise-branch.test.sh`** cloned an empty bare repo and pushed `main`, which
  only works when the host has `init.defaultBranch=main`; git still defaults to `master`
  when that config is unset. The fixture now names the branch explicitly.
- **`tests/lib/cycle-result.test.sh`** simulated a publication failure with `chmod 555`,
  which does not constrain uid 0. Under root — the normal case in CI containers — the
  writes succeeded and five assertions reported a product bug that did not exist. Those
  cases now skip loudly when running as root.
