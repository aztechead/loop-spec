# Adopting loop-spec

## Prerequisites

- One supported harness: Claude Code, OpenCode, Codex, or Google ADK
- The [base runtime dependencies](loop-spec/PREREQUISITES.md)
- A project where you have full git push access
- An authenticated GitHub CLI and `origin` remote when the cycle should open a PR

No model pin is required. Every role inherits the model active in its harness unless
you deliberately add a harness-native route; see the
[model matrix](../skills/shared/model-matrix.md).

## Install

Choose the instructions for the harness you already use.

### Claude Code

```bash
claude plugin marketplace add https://github.com/aztechead/loop-spec.git
claude plugin install loop-spec@loop-spec-marketplace
```

Open a new session and run `/loop-spec:cycle <goal>`. Agent teams are optional;
without them, the same gates run through bounded one-shot agents and loop-fleet.

### Google ADK

```bash
python3 -m pip install 'google-adk>=2.7,<3'
bash loop-spec/lib/adk-install.sh install --project .
LOOP_SPEC_NON_INTERACTIVE=1 adk run "$PWD/adk_agents/loop_spec" \
  "Load the loop-spec auto skill and run: <goal>" --jsonl
```

### OpenCode

```bash
git clone https://github.com/aztechead/loop-spec
bash loop-spec/lib/opencode-install.sh install
opencode run --format json "Load the loop-spec-auto skill and run: <goal>"
```

Use `bash loop-spec/lib/opencode-install.sh install --project .` instead when the
generated skills and agents should live only in the current project.

### Codex

```bash
git clone https://github.com/aztechead/loop-spec
bash loop-spec/lib/codex-install.sh install
LOOP_SPEC_NON_INTERACTIVE=1 codex exec --json --sandbox workspace-write \
  "Load the loop-spec-auto skill and run: <goal>"
```

Use `bash loop-spec/lib/codex-install.sh install --project .` instead when the
generated skills and custom agents should live only in the current project.
Plugin install from a clone that already contains `.codex-plugin/plugin.json`:
`codex plugin marketplace add https://github.com/aztechead/loop-spec.git` then
`codex plugin add loop-spec`. Plugin-bundled hooks stay skipped until `/hooks`
trusts them; the installer-written env block does not wait on that review.

## First cycle

1. Pick a small feature (1-3 file changes).
2. Start it with the harness-specific command above.
3. Pick `quick` tier + `auto` style for an interactive first run.
4. Answer the discuss-phase questions (up to six rounds).
5. Watch the graph proceed through SPEC, DISCUSS, PLAN, EXECUTE, VERIFY, ITERATE,
   and DELIVER.
6. Review the resulting PR.

## What to expect

- A `docs/loop-spec/features/{slug}/` dir created with SPEC.md, PLAN.md, VERIFICATION.md
- A `feat/{slug}` branch with one commit per task plus spec/plan/verify commits
- A PR opened on completion
- A `docs/loop-spec/codebase/` dir with TECH.md / ARCH.md / QUALITY.md / CONCERNS.md / DOMAIN.md (refreshed at end)
- A `.loop-spec/` runtime dir (gitignored except `codebase/index.json`)

## Common pitfalls

- **An explicit model route is unavailable**: remove the override to inherit the
  session model, or replace it with a selector native to that harness. Claude accepts
  its aliases/full IDs; OpenCode accepts `provider/model`; Codex accepts its
  own slugs (`gpt-5.4`, `o3`, …); ADK accepts `gemini-*` or
  `provider/model` through LiteLLM.
- **A Claude alias does nothing in OpenCode or Codex**: this is intentional.
  OpenCode generated agents inherit unless installed with
  `--model role=provider/model`; Codex custom agents inherit unless installed
  with `--model role=<codex-slug>`. Claude aliases are never translated into
  guessed provider routes.
- **Marketplace name confusion**: The marketplace name (`loop-spec-marketplace`) differs from the plugin name (`loop-spec`). Install command MUST use `plugin@marketplace` form.
- **Critique gate keeps bouncing**: spec is genuinely ambiguous. Pick STEP style next time so you can review SPEC.md before plan starts.
- **Worktree disk usage spikes**: EXECUTE self-claims up to `tier.execute.maxParallelImplementers` worktrees (2 on quick, 3 on balanced, 4 on quality), each a full checkout. Acceptable on modern SSDs; adjust the tier matrix if low-disk.
- **Claude Code agent teams are unavailable**: this is not fatal. The cycle records
  `teamsMode=none` and uses its parity fallback.

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
- VERIFY commits evidence without pushing. DELIVER then opens or reuses one PR per changed repo, binds it to the exact checked SHA, waits for required checks, and persists every per-repo result; repos with no commits are recorded as skipped.

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
