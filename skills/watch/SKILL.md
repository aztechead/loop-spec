---
name: watch
description: Bounded post-merge watch for a shipped loop-spec feature (ROADMAP-3.0 C2). After a cycle PR merges, checks whether the default branch stayed green for the watch window and whether fixup commits touched the feature's files, appends the verdict to the feature's committed run digest (the raw signal the trust governor consumes), and queues a watch-regression backlog entry on a dirty window — it never reopens a cycle itself. Recipe-driven (cron/CI), no daemon.
argument-hint: '<slug> [--window-hours 24]'
---

# Watch Skill

Invoked as `/loop-spec:watch <slug>`.

The reality check past the merge (ROADMAP-3.0 C2): a cycle that ends at
"suite green + PR merged" has still only been *predicted* to work. This skill
asks what actually happened afterwards, from git/CI facts. All mechanics live
in `lib/watch.sh`; this skill is the thin command surface.

## Run it

From the project root (the directory containing `.loop-spec/`):

```bash
bash "${CLAUDE_SKILL_DIR}/../../lib/watch.sh" run --slug <slug> [--window-hours 24]
```

Pass the user's arguments through (`--window-hours`, `--repo`, `--branch` if
they gave one). Print the script output as-is, then summarize the verdict in
one sentence. Needs `gh` authenticated; the feature branch defaults to the
digest's `branch` field (else `feat/<slug>`).

- **"no merged PR ... nothing to watch yet"** — the PR is still open (or the
  branch never had one). Not an error; re-run after the merge.
- **`clean=true`** — CI green in the window AND zero post-merge commits
  touched the feature's files. This is the signal that promotes trust
  (`lib/trust.sh`: `postMergeFixRate`, `watchWindowClean`).
- **`clean=false`** — the window was dirty. The script has already queued a
  `watch-regression` entry in `.loop-spec/BACKLOG.md` (deduped per slug+PR);
  the sentinel will triage it as a bug. Do NOT start a fix cycle from here —
  the loops compose through the backlog, they do not couple.
- **`clean=null`** — unknowable (no CI runs in the window, or the merge
  commit is unresolvable locally). Fail-closed: null never promotes trust.

The verdict lands in `docs/loop-spec/telemetry/runs/<slug>.json` as the
`watch` object (re-runs overwrite it — latest wins, so run it again after the
window closes if you ran early). Commit the digest change so the signal
survives volatile agents — the metrics contract reads committed digests.

## Unattended

Run it from the same cron/CI recipe that drives the sentinel — one bounded
check per merged feature after the window elapses, no daemon. Recipes:
`docs/loop-spec/sentinel.md`.
