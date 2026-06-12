# Adopting loop-spec

## Prerequisites

- Claude Code v{minimum-required-version} or later (check release notes)
- A project where you have full git push access
- `CLAUDE.md` model policy allowing `claude-opus-4-7`, `claude-sonnet-4-6`, `claude-haiku-4-5`

## Install

1. Register the marketplace:
   ```bash
   claude plugin marketplace add git@git.viasat.com:cbobrowitz/loop-spec.git
   ```
2. Install the plugin:
   ```bash
   claude plugin install loop-spec@loop-spec-marketplace
   ```
3. Verify: open a new Claude Code session and run `Skill(loop-spec:cycle)`. You should see the entry prompt.

## First cycle

1. Pick a small feature (1-3 file changes).
2. Run `Skill(loop-spec:cycle)`.
3. Pick `quick` tier + `auto` style for first run.
4. Answer the discuss-phase questions (<=5 rounds).
5. Watch the cycle proceed: SPEC -> PLAN -> EXECUTE -> VERIFY.
6. Review the resulting PR.

## What to expect

- A `docs/loop-spec/features/{slug}/` dir created with SPEC.md, PLAN.md, VERIFICATION.md
- A `feat/{slug}` branch with one commit per task plus spec/plan/verify commits
- A PR opened on completion
- A `docs/loop-spec/codebase/` dir with TECH.md / ARCH.md / QUALITY.md / CONCERNS.md / DOMAIN.md (refreshed at end)
- A `.loop-spec/` runtime dir (gitignored except `codebase/index.json`)

## Common pitfalls

- **Health check fails on opus-4-7**: your CLAUDE.md probably bans it. Update model policy.
- **Marketplace name confusion**: The marketplace name (`loop-spec-marketplace`) differs from the plugin name (`loop-spec`). Install command MUST use `plugin@marketplace` form.
- **Critique gate keeps bouncing**: spec is genuinely ambiguous. Pick STEP style next time so you can review SPEC.md before plan starts.
- **Worktree disk usage spikes**: EXECUTE self-claims up to `tier.execute.maxParallelImplementers` worktrees (2 on quick, 3 on balanced, 4 on quality), each a full checkout. Acceptable on modern SSDs; adjust the tier matrix if low-disk.
- **Sonnet 1M context unavailable**: warning logged in `feature.json.warnings[]`. Plans/specs above 200k tokens fall back gracefully but planner may need decomposition help.

## Tier picking

See `docs/tier-guide.md`.

## Workspace (multi-repo) adoption

loop-spec can span multiple sibling repositories in a single cycle using workspace mode.

### How to start

**Option A -- automatic discovery.** If your repos live as immediate children of a parent directory that is not itself a git repo, just `cd` to that parent and run `Skill(loop-spec:cycle)`. Cycle Step 0 discovers child repos (depth-1 scan, hidden dirs skipped), announces the list, and asks you to confirm before proceeding.

**Option B -- explicit pin.** If the parent directory is itself a git repo, or if you want to select a subset of child repos, create `.loop-spec/workspace.json` at the parent:

```json
{"schemaVersion": 1, "repos": [{"name": "frontend", "path": "frontend"}, {"name": "backend", "path": "backend"}]}
```

Then run `Skill(loop-spec:cycle)` from that parent. The pin takes precedence over auto-detection. If the parent is or becomes a git repo, add `.loop-spec/` to its `.gitignore`.

Non-interactive: set `LOOP_SPEC_ANSWER_REPOS=frontend,backend` to skip the confirmation prompt.

### What changes vs. single-repo mode

- State and artifacts land at the workspace root (`.loop-spec/` and `docs/loop-spec/features/{slug}/`).
- PLAN tasks each carry a `repo` field; `files[]` paths are workspace-relative (`<repo>/<path>`). Cross-repo work splits across multiple tasks with `blockedBy` edges.
- EXECUTE is capped at the subagent rung (team/loop-fleet/Workflow rungs are single-repo only in v1).
- VERIFY pushes and opens one PR per repo that has commits; repos with no commits are left untouched.

### In-place branch caveat

In workspace mode each participating repo gets a `feat/{slug}` branch created directly in its working checkout -- there are no feature worktrees. The cycle scans every repo for uncommitted changes before creating any branch; a dirty repo aborts with a clear message listing which repos need to be committed or stashed. Resume from an interrupted workspace cycle by re-invoking `Skill(loop-spec:cycle)` from the workspace root; invoking from any other directory will prompt you to return there first.

## Resuming

Re-invoke `Skill(loop-spec:cycle)`. It scans for in-progress features and offers to resume.

## Aborting

```bash
rm -rf .loop-spec/features/{slug}/
git branch -D feat/{slug}
git worktree prune
```

## Next steps

- Read `docs/design.md` for architecture detail
- Read `tests/README.md` for test matrix coverage
- Contribute: see CLAUDE.md
