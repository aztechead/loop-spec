---
name: watch
description: Use after a cycle PR merges, when cron/CI should watch the default branch for the watch window. Appends the verdict to the feature's committed run digest. Do not use this to reopen or continue a cycle — it never starts one.
argument-hint: '<slug> [--window-hours 24]'
---

# Watch Skill

Invoked as `/loop-spec:watch <slug>`.

Check Git and CI evidence after the feature merges.
`lib/watch.sh` performs the check and records the result.

## Run it

From the project root (the directory containing `.loop-spec/`):

```bash
bash "${LOOP_SPEC_SKILL_DIR}/../../lib/watch.sh" run --slug <slug> [--window-hours 24]
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
- **`clean=false`** — the check found a regression signal.
  The script queues a `watch-regression` entry in `.loop-spec/BACKLOG.md`, once per slug and PR.
  The sentinel triages it as a bug. Do not start a fix cycle here.
- **`clean=null`** — unknowable (no CI runs in the window, or the merge
  commit is unresolvable locally). Fail-closed: null never promotes trust.

The verdict lands in `docs/loop-spec/telemetry/runs/<slug>.json` as the
`watch` object (re-runs overwrite it — latest wins, so run it again after the
window closes if you ran early). The digest is machine-local by default; on a
volatile agent set `LOOP_SPEC_COMMIT_TELEMETRY=1` and commit the digest change
(`git add -f` — the path is runtime-ignored) so the signal survives the
workspace.

## Unattended

Run it from the same cron/CI recipe that drives the sentinel — one bounded
check per merged feature after the window elapses, no daemon. Recipes:
`docs/loop-spec/sentinel.md`.
