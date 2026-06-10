# Adopting super-spec

## Prerequisites

- Claude Code v{minimum-required-version} or later (check release notes)
- A project where you have full git push access
- `CLAUDE.md` model policy allowing `claude-opus-4-7`, `claude-sonnet-4-6`, `claude-haiku-4-5`

## Install

1. Register the marketplace:
   ```bash
   claude plugin marketplace add git@git.viasat.com:cbobrowitz/super-spec.git
   ```
2. Install the plugin:
   ```bash
   claude plugin install super-spec@super-spec-marketplace
   ```
3. Verify: open a new Claude Code session and run `Skill(super-spec:cycle)`. You should see the entry prompt.

## First cycle

1. Pick a small feature (1-3 file changes).
2. Run `Skill(super-spec:cycle)`.
3. Pick `quick` tier + `auto` style for first run.
4. Answer the discuss-phase questions (<=5 rounds).
5. Watch the cycle proceed: SPEC -> PLAN -> EXECUTE -> VERIFY.
6. Review the resulting PR.

## What to expect

- A `docs/super-spec/features/{slug}/` dir created with SPEC.md, PLAN.md, VERIFICATION.md
- A `feat/{slug}` branch with one commit per task plus spec/plan/verify commits
- A PR opened on completion
- A `docs/super-spec/codebase/` dir with TECH.md / ARCH.md / QUALITY.md / CONCERNS.md / DOMAIN.md (refreshed at end)
- A `.super-spec/` runtime dir (gitignored except `codebase/index.json`)

## Common pitfalls

- **Health check fails on opus-4-7**: your CLAUDE.md probably bans it. Update model policy.
- **Marketplace name confusion**: The marketplace name (`super-spec-marketplace`) differs from the plugin name (`super-spec`). Install command MUST use `plugin@marketplace` form.
- **Critique gate keeps bouncing**: spec is genuinely ambiguous. Pick STEP style next time so you can review SPEC.md before plan starts.
- **Worktree disk usage spikes**: EXECUTE self-claims up to `tier.execute.maxParallelImplementers` worktrees (2 on quick, 3 on balanced, 4 on quality), each a full checkout. Acceptable on modern SSDs; adjust the tier matrix if low-disk.
- **Sonnet 1M context unavailable**: warning logged in `feature.json.warnings[]`. Plans/specs above 200k tokens fall back gracefully but planner may need decomposition help.

## Tier picking

See `docs/tier-guide.md`.

## Resuming

Re-invoke `Skill(super-spec:cycle)`. It scans for in-progress features and offers to resume.

## Aborting

```bash
rm -rf .super-spec/features/{slug}/
git branch -D feat/{slug}
git worktree prune
```

## Next steps

- Read `docs/design.md` for architecture detail
- Read `tests/README.md` for test matrix coverage
- Contribute: see CLAUDE.md
