---
name: sentinel
description: "Use when scanning work sources into the sentinel queue or running its eligible work through autonomous cycles. Use /loop-spec:cycle for a specific task and /loop-spec:assess for codebase health."
argument-hint: 'scan | run'
---

# Sentinel Skill

Invoked as `/loop-spec:sentinel scan` or `/loop-spec:sentinel run`.

`scan` reads repository work sources and updates the triaged queue.
`run` selects eligible queue items and starts autonomous cycles.

All mechanics live in scripts; this skill is the thin command surface and
obeys their verdicts verbatim:
`lib/sentinel-sources.sh` (source adapters), `lib/sentinel-triage.sh`
(deterministic scoring), `lib/sentinel-run.sh` (pop + decision ledger),
`lib/autonomous-chain.sh --scope queue` (the chain predicate),
`lib/trust.sh authorize` (the batch governor).

## scan

Run from the project root (the directory containing `.loop-spec/`):

```bash
LIB="${LOOP_SPEC_SKILL_DIR}/../../lib"
for src in $(bash "$LIB/sentinel-triage.sh" sources); do
  bash "$LIB/sentinel-sources.sh" "$src" || echo "[]"
done | jq -cs 'add // []' | bash "$LIB/sentinel-triage.sh" run
```

Print the resulting queue JSON as-is — do not paraphrase scores or reorder
entries. Then summarize in one or two sentences: how many items queued, how
many need a human, and what sits at the head. If an adapter failed (e.g. `gh`
not authenticated), say which one and that the scan proceeded without it.

## run

Sentinel runs are autonomous. Never ask a question during the run.
Pass `autonomous` to every conversion and cycle below.

**Safety rails (A4 — non-negotiable, all enforced by scripts, not by you):**

- **PR-terminated, always.** A sentinel-started cycle ends at its PR (or
  checkpoint PR). Never merge anything, never set `LOOP_SPEC_CHECKPOINT_PR=0`
  for a sentinel run. (`lib/trust.sh authorize --action auto-merge` is denied
  at every level in this release — do not attempt it.)
- **Never chain past a failure.** Chaining is decided exclusively by
  `lib/autonomous-chain.sh --scope queue`; a paused/escalated cycle stops the
  batch. Obey the verdict verbatim.
- **Every decision is recorded.** Picks are recorded by `sentinel-run.sh
  next`; if you skip an item for any reason, record it:
  `bash "$LIB/sentinel-run.sh" record skipped --id <id> --source <src> --reason "<why>"`.

**Flow** (repeat from step 1 while the chain predicate says chain):

1. **Scan** — exactly the `scan` block above (the queue is a re-derived view;
   always refresh before popping).
2. **Pop** — `item="$(bash "$LIB/sentinel-run.sh" next)"`. Exit 1 means
   nothing is eligible: report the stderr reason (`queue-empty`,
   `all-cooling-down`, `no-queue-file`) and stop. The pick is recorded, and a
   just-processed item cannot be re-picked inside the cooldown
   (`PICK_COOLDOWN_HOURS`, default 24).
3. **Claim (gh-issues items only)** — same lifecycle labels as
   `lib/issue-intake.sh`, best-effort:
   `gh issue edit <number> --add-label loop-spec:in-progress`
   (the item id `gh-N` carries the number).
4. **Convert** — `Skill(loop-spec:intake)` with arguments:
   `autonomous --no-run <item title, body, and url from the popped JSON>`. Intake's
   fidelity rule applies: the draft restructures the item, never invents
   scope. Note the draft path it prints.
5. **Cycle** — `Skill(loop-spec:cycle)` with arguments:
   `autonomous <draft path>`.
6. **Close out the source (gh-issues items only)** — read
   `.loop-spec/last-result.json`; comment its PR URL or, for a validated
   `outcome: no-change-needed`, its `summary` plus `noChangeReason`. A completed
   no-PR record without a known no-change code fails closed. Then swap the lifecycle label:
   `--add-label loop-spec:done|loop-spec:failed --remove-label loop-spec:in-progress`.
   Backlog-sourced items are checked off by the cycle itself; ci-failures and
   assessment items have nothing to mutate.
7. **Chain or stop** — with the just-finished feature dir and the count of
   items completed this invocation:

   Replace `<slug>` with that feature's slug and `<n>` with the completed item count.

   ```bash
   bash "$LIB/autonomous-chain.sh" should-chain .loop-spec/features/<slug> \
     --scope queue --completed <n>
   ```
   `{"chain": true, ...}` → go to step 1. `{"chain": false, "reason": ...}` →
   stop and report the reason verbatim. The batch bound inside is the trust
   governor: L0 repos process exactly ONE item per invocation;
   `LOOP_SPEC_MAX_FEATURES` is honored (capped) only once the repo has earned
   L1 (`lib/trust.sh level` shows the evidence).
8. **Report** — one summary: items processed with their PR URLs or intentional
   no-change conclusions, decisions
   recorded, why the batch stopped, and what now sits at the head of the queue.

Unattended cadence (cron/launchd/GitHub Actions invoking this skill headlessly)
is a documented recipe, not a daemon: `docs/loop-spec/sentinel.md`.

## What the output means

- **queue** — candidate work items ordered by the deterministic policy
  (source weight × kind × recency; see `lib/sentinel-triage.sh` header). The
  head of the queue is what `sentinel run` picks first.
- **needsHuman** — items the policy refused to classify (unknown kind,
  unknown source, missing id/title). They are surfaced here and by
  `/loop-spec:status`; a script never guesses their class and never runs them.
- The queue file is **re-derived from sources on every scan** — it is a view,
  not a store. Editing it by hand changes nothing durable. What HAS been
  attempted lives in `.loop-spec/sentinel-events.jsonl` (picked / skipped /
  needs-human decisions — mined by `/loop-spec:retro` and the metrics
  contract).

## Configuration

Optional `.loop-spec/sentinel.conf` (KEY=VALUE lines; all keys optional):

```
ENABLE_GH_ISSUES=1   ENABLE_CI_FAILURES=1   ENABLE_BACKLOG=1   ENABLE_ASSESSMENT=1
WEIGHT_GH_ISSUES=5   WEIGHT_CI_FAILURES=8   WEIGHT_BACKLOG=3   WEIGHT_ASSESSMENT=2
MAX_QUEUE_DEPTH=10   PICK_COOLDOWN_HOURS=24
```

Sources: `gh-issues` needs `gh` authenticated and picks up open issues labeled
`loop-spec` (skipping lifecycle-labeled ones, same rule as `lib/issue-intake.sh`);
`ci-failures` needs `gh` and reports the most recent failed run per workflow on
the default branch; `backlog` reads `.loop-spec/BACKLOG.md` (including
`watch-regression` entries queued by the post-merge watch — they triage as
bugs); `assessment` reads the top findings of
`docs/loop-spec/assessment/ASSESSMENT.md` when it is fresher than 30 days. The
offline sources keep the sentinel useful without GitHub.

Batch bound: `.loop-spec/trust.conf` `BATCH_L1` (default 5) caps how far
`LOOP_SPEC_MAX_FEATURES` can raise an L1 repo's batch; L0 is always 1.
