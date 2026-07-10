---
name: sentinel
description: Watch loop-spec's work sources and triage them into an ordered queue. "scan" runs the source adapters (labeled GitHub issues, CI failures on the default branch, the backlog, fresh assessment findings) through the deterministic triage policy and prints .loop-spec/sentinel-queue.json — read-only, no LLM scoring, nothing is executed. Unclassifiable items are queued as needs-human, never silently dropped.
argument-hint: 'scan'
---

# Sentinel Skill

Invoked as `/loop-spec:sentinel scan`.

The self-sourcing seam (ROADMAP-3.0 Pillar A): instead of waiting for a human
to paste work into `/loop-spec:intake`, the sentinel watches the repo's work
sources and keeps a triaged queue. In this release the sentinel is
**observation only** — `scan` reads sources and writes the queue file; it
never starts a cycle, never mutates an issue, never dispatches an agent.

All mechanics live in `lib/sentinel-sources.sh` (source adapters) and
`lib/sentinel-triage.sh` (deterministic scoring policy); this skill is the
thin command surface.

## scan

Run from the project root (the directory containing `.loop-spec/`):

```bash
LIB="${CLAUDE_SKILL_DIR}/../../lib"
for src in $(bash "$LIB/sentinel-triage.sh" sources); do
  bash "$LIB/sentinel-sources.sh" "$src" || echo "[]"
done | jq -cs 'add // []' | bash "$LIB/sentinel-triage.sh" run
```

Print the resulting queue JSON as-is — do not paraphrase scores or reorder
entries. Then summarize in one or two sentences: how many items queued, how
many need a human, and what sits at the head. If an adapter failed (e.g. `gh`
not authenticated), say which one and that the scan proceeded without it.

## What the output means

- **queue** — candidate work items ordered by the deterministic policy
  (source weight × kind × recency; see `lib/sentinel-triage.sh` header). The
  head of the queue is what a future `sentinel run` would pick first.
- **needsHuman** — items the policy refused to classify (unknown kind,
  unknown source, missing id/title). They are surfaced here and by
  `/loop-spec:status`; a script never guesses their class and never runs them.
- The queue file is **re-derived from sources on every scan** — it is a view,
  not a store. Editing it by hand changes nothing durable.

## Configuration

Optional `.loop-spec/sentinel.conf` (KEY=VALUE lines; all keys optional):

```
ENABLE_GH_ISSUES=1   ENABLE_CI_FAILURES=1   ENABLE_BACKLOG=1   ENABLE_ASSESSMENT=1
WEIGHT_GH_ISSUES=5   WEIGHT_CI_FAILURES=8   WEIGHT_BACKLOG=3   WEIGHT_ASSESSMENT=2
MAX_QUEUE_DEPTH=10
```

Sources: `gh-issues` needs `gh` authenticated and picks up open issues labeled
`loop-spec` (skipping lifecycle-labeled ones, same rule as `lib/issue-intake.sh`);
`ci-failures` needs `gh` and reports the most recent failed run per workflow on
the default branch; `backlog` reads `.loop-spec/BACKLOG.md`; `assessment` reads
the top findings of `docs/loop-spec/assessment/ASSESSMENT.md` when it is fresher
than 30 days. The offline sources keep the sentinel useful without GitHub.
