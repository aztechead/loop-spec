# ROADMAP-3.0 — from autonomous execution to autonomous operation

**Status:** draft plan (2026-07-09). Nothing here is committed work; every item goes
through the cycle when it is picked up.

**Semver stance:** 3.0 is NOT a breaking change. Every 2.x invocation, artifact,
config file, and hook keeps working unchanged. The major bump marks an identity
change: the 2.x line is *a spec-driven cycle you invoke*; 3.0 is *a development
agent that runs the loop itself, with trust it has to earn*. A user who never
enables the new surfaces sees 2.x behavior forever.

## Thesis

Every 2.x release made a single invoked run more self-sufficient: the `autonomous`
token removed mid-run questions (decisions recorded via `lib/decisions.sh`),
`lib/autonomous-chain.sh` made bounded backlog chaining deterministic, RULES.md +
`lib/retro.sh` gave the loop memory, and `lib/run-digest.sh` made telemetry survive
volatile agents. But the plugin is still fundamentally **reactive**: a human hands
it one assignment and it runs until PR.

3.0 closes three loops that today end at a human:

| Loop | Today ends at | 3.0 closes it with |
|---|---|---|
| Work intake | a human pasting into `/intake` | Pillar A — self-sourcing (sentinel) |
| Learning | a human running `/retro` and curating rules | Pillar B — closed learning loop |
| Verification | a green test suite + a PR | Pillar C — reality-grounded VERIFY |
| Authority | every merge needs a human | Pillar D — graduated trust (the governor) |

## Design constraints (carried forward, non-negotiable)

1. **Lean deps.** Everything ships as bash + jq + python3 + markdown. No daemons
   that require installation; "scheduling" means documented cron/launchd/CI recipes
   invoking existing entry points.
2. **Dual harness.** Every new capability keys on `lib/harness.sh`; pi gets the
   inline/headless equivalent or a documented degradation, pinned in
   `tests/pi-harness-coverage.test.sh`.
3. **Deterministic predicates for autonomous decisions.** Anything that decides
   *whether the loop may act without a human* is a script with unit tests, never
   prose in a skill (the `autonomous-chain.sh` precedent). The model proposes;
   scripts authorize.
4. **Fail-open accelerators, fail-closed authority.** Directives and telemetry
   never block a session. Trust escalation (Pillar D) fails **closed**: any doubt
   resolves to the lower trust level.
5. **Seams, not speculation.** Each pillar lands as an interface with one shipped
   implementation; adapters others can add later, none built "just in case".

---

## Pillar A — Self-sourcing work (the sentinel)

**Goal:** loop-spec watches its work sources, triages, drafts specs, and starts
cycles on a cadence — the plugin operates a development queue instead of waiting
for an invocation.

### A1. Source adapters (`lib/sentinel-sources.sh`)

One script, one subcommand per source, each emitting a normalized JSON array of
candidate work items `{source, id, title, body, url, kind, updatedAt}`:

- `gh-issues` — `gh issue list --json ...` filtered by a label (default
  `loop-spec`); reuses the auth the user already has (`gh` is already a dependency
  of checkpoint-PR).
- `ci-failures` — `gh run list --status failure` on the default branch, most
  recent per workflow; body carries the failing job log tail.
- `backlog` — `.loop-spec/BACKLOG.md` entries via `lib/backlog.sh` (already
  machine-readable; ITERATE queues gaps here today).
- `assessment` — top-N findings from `docs/loop-spec/assessment/ASSESSMENT.md`
  when it exists and is fresher than a staleness bound.

The adapter list is the seam. Jira/Slack/email adapters are explicitly deferred —
they arrive through `/intake` today and can become adapters when someone needs
them.

### A2. Triage policy (`lib/sentinel-triage.sh` + `.loop-spec/sentinel.conf`)

Deterministic scoring, no LLM calls: source weight × recency × kind (bug > gap >
chore) with per-source enable flags and a max-queue-depth in `sentinel.conf`.
Output: an ordered queue file `.loop-spec/sentinel-queue.json`. Items the policy
cannot classify are queued as `needs-human` and surfaced in `/loop-spec:status` —
never silently dropped, never silently run.

### A3. The drive loop (`/loop-spec:sentinel` + recipes)

- `/loop-spec:sentinel scan` — run adapters + triage, print the queue (read-only).
- `/loop-spec:sentinel run` — pop the head item, convert via the existing
  `lib/issue-intake.sh` → `/loop-spec:intake --no-run` path, then start
  `/loop-spec:cycle <draft> autonomous`. Chaining beyond one item stays governed
  by `lib/autonomous-chain.sh` (extended with a `--queue` scope so
  `LOOP_SPEC_MAX_FEATURES` bounds sentinel batches exactly like backlog drains).
- **No daemon.** Unattended cadence is a documented recipe
  (`docs/loop-spec/sentinel.md`): cron/launchd/GitHub Actions invoking
  `claude -p "/loop-spec:sentinel run"` (or `pi -p`, via `lib/harness.sh cli`).
  The e2e smoke (`tests/e2e/`) gets a sentinel scenario.

### A4. Safety rails

- Never chain past a failure (existing `autonomous-chain.sh` invariant, reused).
- Sentinel runs are always PR-terminated until Pillar D grants more (see D2).
- Every sentinel decision (picked, skipped, needs-human) appends to
  `events.jsonl` via `lib/events.sh` so `/status` and `/retro` see it.

**Tests:** unit suites for both new libs (fixture `gh` shim like
`skills/loop-runner/tests/fakepi`); queue-bound and never-chain-past-failure
predicates pinned like `tests/lib/autonomous-chain.test.sh`.

---

## Pillar B — The closed learning loop

**Goal:** telemetry → retro → rules/parameters happens without a human in the
loop, within the existing safety construction (closed template set, deterministic
triggers, only-tightens-discipline).

### B1. Widen the corpus

- `lib/retro.sh` learns two new sources: the micro-cycle ledger
  (`.loop-spec/adhoc-ledger.md`, shipped in 2.15.0 — repeated `fail`/`partial`
  results on the same area are a rule trigger) and sentinel events (items that
  bounced `needs-human` repeatedly are a policy-gap signal).
- `lib/run-digest.sh` grows convergence fields it currently leaves implicit:
  iterate rounds to converge, gate rounds by phase, verify-failure classes.

### B2. Parameter tuning, not just rules

Today retro's closed template set emits prose rules. 3.0 adds a second closed
set: **parameter adjustments** written to `.loop-spec/tuning.json` (new, read by
the cycle at startup next to `runtime.json`):

- Repo converges first-pass ≥ N consecutive runs → widen the trivial fast-path
  bound (fewer plan critiques).
- A verify-failure class recurs ≥ 3 runs → add a mandatory probe/check to that
  phase for this repo.
- An iterate gap type recurs → raise the gate rounds for the phase that owns it.

Same construction as rule auto-apply: deterministic trigger, bounded delta,
template-only (the model cannot author an adjustment), every change recorded in
`DECISIONS`-style audit, `LOOP_SPEC_TUNING=0` kill switch, and the user curates
the file. Loosening adjustments (the fast-path widening) demote automatically on
the first contrary signal — loosening is always one bad run from reverting.

### B3. Metrics as a first-class contract

`lib/status.sh stats` already aggregates; formalize the numbers the other pillars
consume (convergence rate, first-pass rate, post-merge fix rate) into a stable
`--json` schema so trust (D1) and tuning (B2) read one contract instead of
re-deriving. Pin with a schema test.

**Tests:** golden-file corpus fixtures for each new trigger; a
"tuning-only-from-templates" test mirroring the existing retro closed-set test.

---

## Pillar C — Reality-grounded VERIFY

**Goal:** extend probe-before-assert from the design phases into VERIFY and past
the merge: the loop ends at "observed working", not "suite green".

### C1. Live-run verify rung (opt-in per repo)

A `verifyCommands` block in `.loop-spec/workflow-config` (detected once by
`lib/detect-test-cmd.sh`'s sibling, confirmed by the user or autonomous default):
launch command, readiness probe, N acceptance probes (curl/CLI invocations
derived from SPEC acceptance criteria). VERIFY runs it after the suite, captures
output into EVIDENCE.md via the existing `lib/evidence.sh` ledger, and the
verifier cites `EVID-NNN` ids. Degrades to suite-only when no launch command is
configured — never guesses one.

### C2. Post-merge watch (`/loop-spec:watch`, recipe-driven)

After a cycle PR merges, a bounded follow-up check (again: cron/CI recipe, no
daemon): did the default branch stay green for the watch window? Did a human
push fixup commits touching the feature's files? Results append to the feature's
run digest — this is the raw signal Pillar D consumes. Read-only; it never
reopens a cycle by itself (it queues a backlog entry, which sentinel may pick
up — the loops compose instead of coupling).

**Tests:** fake-server fixture for the live rung; digest-append unit tests for
watch.

---

## Pillar D — Graduated trust (the governor)

**Goal:** an earned-autonomy model that decides, deterministically and auditably,
how much unattended authority the loop has in a given repo. D is what makes A
safe to leave running overnight.

### D1. The track record (`lib/trust.sh`)

Computed, never stored as opinion: reads committed run digests
(`docs/loop-spec/telemetry/runs/*.json`) + post-merge watch results + git history.
`trust.sh level` prints the current level and the evidence lines that produced
it. Inputs per repo: consecutive converged cycles, post-merge human-fix rate,
verify-failure rate, sentinel `needs-human` rate.

### D2. Levels → authority map

| Level | Earned by (defaults, configurable in `.loop-spec/trust.conf`) | Unlocks |
|---|---|---|
| L0 | — (default forever, today's behavior) | PR-and-wait; chain ≤ `LOOP_SPEC_MAX_FEATURES` |
| L1 | 5 consecutive converged cycles, 0 post-merge fixes | larger sentinel batches; auto-chain backlog drains |
| L2 | 10 consecutive, live-verify rung enabled and passing | auto-merge for docs/test-only diffs (deterministic diff classifier) |
| L3 | 20 consecutive at L2, watch window clean | auto-merge for low-risk code class (classifier + full gate ladder + live verify all green) |

- **Demotion is instant and coarse:** any non-converged run, post-merge fixup, or
  watch failure drops the repo one level and resets its streak. Promotion is slow,
  demotion is fast.
- **Every auto-merge is a recorded decision** (`lib/decisions.sh`) linking the
  evidence that authorized it; `/loop-spec:status` shows the current level and
  distance to the next.
- The diff classifier is a deterministic script (path + hunk rules), unit-tested,
  and fails closed to "not low-risk".

### D3. Enforcement placement

Authority checks live in the scripts that act (checkpoint-pr/merge path), not in
skill prose — a skill cannot talk itself past `trust.sh`. The merge step asks
`trust.sh authorize --action auto-merge --diff <range>` and obeys the exit code.

**Tests:** table-driven level computation; demotion-on-any-failure; classifier
golden files; an "L0 default with empty telemetry" invariant.

---

## Release train

Each wave ships through the cycle, keeps `tests/run-all.sh` green, and is
independently useful; 3.0 is the last flip, not a big bang.

| Version | Ships | Risk gate |
|---|---|---|
| 2.16.0 | A1+A2 (adapters + triage, `sentinel scan` read-only); B3 metrics contract; D1 `trust.sh level` read-only | nothing acts autonomously yet — pure observation |
| 2.17.0 | B1+B2 (corpus + tuning templates); C1 live-verify rung (opt-in) | tuning kill switch; live rung opt-in |
| 2.18.0 | A3+A4 (`sentinel run` + recipes); C2 post-merge watch; D2/D3 at L1 only | sentinel PR-only; L1 unlocks batching, never merging |
| 3.0.0 | L2/L3 auto-merge classes; sentinel + watch recipes promoted from docs to `/onboard`; README/identity rewrite | requires a clean 2.18 soak in this repo (self-host) recorded in telemetry |

**Live-run debts carried in:** the pi smoke and the design-latency before/after
run owed from 2.13/2.14 fold into the 2.16 observation wave — the metrics
contract (B3) is how their results get recorded.

## Non-goals

- No resident daemon, no queue service, no database. Files + git + cron recipes.
- No new model-facing ceremony: sentinel and watch are scripts a scheduler calls;
  the cycle itself is unchanged.
- No cross-repo trust transfer (trust is per-repo by construction; a global
  score would launder evidence).
- No Jira/Slack adapters until a real user needs one (the `/intake` path covers
  them manually today).

## Top risks

1. **Runaway autonomy** — mitigated by: never-chain-past-failure, queue bounds,
   L0-by-default, fast demotion, and every authority check being a fail-closed
   script.
2. **Tuning oscillation** (B2 loosening/tightening thrash) — bounded deltas,
   one-contrary-signal demotion, and the tuning file being user-curated.
3. **Trust gaming by the model** (optimizing the streak instead of the work) —
   trust inputs are computed from git/CI facts, not self-reports; the
   test-tamper scan already guards the suite; the diff classifier guards scope.
4. **gh-CLI coupling** (A1/C2 assume GitHub) — adapters are the seam; the
   backlog/assessment sources keep sentinel useful offline.
