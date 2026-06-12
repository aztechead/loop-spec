# Multi-root workspace support + assess and quality-loop skills

**Slug:** `multi-root-workspace`
**Created:** 2026-06-12
**Tier:** quality
**Execution style:** auto

## Problem

loop-spec assumes the current working directory is (inside) a single git repository. Every git invocation in `lib/git-ops.sh`, `lib/checkpoint.sh`, `lib/worktree-commit-check.sh`, and the cycle/execute/verify skills runs against the cwd repo; the feature worktree, branches, commits, pushes, and PRs all target that one repo.

A developer working on a product split across sibling repositories (e.g. `frontend/`, `backend/`, `db/` under one parent directory) cannot run one loop-spec cycle that plans, implements, and verifies a feature spanning all of them. The parent directory may or may not itself be a git repository.

Separately, two proven review workflows exist only as proprietary external skills (a vendor framework's `quality-loop` and `assessment-pipeline`) that depend on a Python framework unavailable here. Their concepts -- an iterative pre-commit review convergence loop, and a codebase fragility assessment with synthesized reporting -- fit loop-spec's gap between EXECUTE and VERIFY and its codebase-mapping capability, but must be re-derived clean on loop-spec's runtime (bash + git + jq + python3 stdlib) with no proprietary text or code copied.

## Goals

### Workstream A -- multi-root workspace core

- Add `lib/workspace.sh` with subcommands `detect`, `list-repos`, and `resolve-repo` that classify the invocation directory as one of three modes: `single` (cwd is inside a git repo), `workspace` (cwd is a parent directory containing N immediate-child git repos, or an explicit `.loop-spec/workspace.json` pin), or `none` (neither).
- Support an optional `.loop-spec/workspace.json` config that pins workspace mode and the participating repo list (needed when the parent itself is a git repo, or to select a subset of discovered repos).
- Add a global `-C <path>` option to `lib/git-ops.sh`, `lib/checkpoint.sh`, and `lib/worktree-commit-check.sh` so every git operation can target an arbitrary repo root. Default behavior (no flag) is byte-identical to today.
- Extend the feature state schema to v7: a new optional `workspace` block (`root`, `repos[]` with per-repo `name`, `path`, `branch`, `baseSha`, `baseBranch`, `commands`). Absent or null `workspace` means single mode; v6 features load unchanged.
- Teach `skills/cycle/SKILL.md` a workspace path: detection step, per-repo project-command detection, per-repo in-place feature branches (`git -C <repo> checkout -b feat/{slug}`), state and artifacts rooted at the workspace root, no feature worktree and no `EnterWorktree`/`ExitWorktree` in workspace mode.
- Teach `skills/plan/SKILL.md` and `agents/planner.md` a per-task `repo` field (workspace mode only) with workspace-relative `files[]` paths (`<repo>/<path>`).
- Teach `skills/execute/SKILL.md` a workspace dispatch path: the concurrency ladder is capped at the subagent rung; at most one implementer works per repo concurrently (serialize within a repo, parallelize across repos); implementers edit in place on the repo's `feat/{slug}` branch and commit via `git -C <repo>`; no per-task worktrees.
- Teach `skills/verify/SKILL.md` a workspace path: unresolved-marker scan, test/lint/typecheck, checkpoint tag, push, and PR creation run per repo (only repos with commits over their `baseSha`); VERIFICATION.md is written at the workspace root and committed only when the workspace root is itself a git repo.
- `lib/validate-task-metadata.sh` accepts an optional `repo` string field.
- `lib/pause-snapshot.sh` reports uncommitted changes per workspace repo when the feature carries a `workspace` block.
- `hooks/restrict-agent-paths.sh` continues to work unchanged at a workspace root (its path-fragment matching is already location-independent); a regression test case proves it.

### Workstream B -- assess skill (adapted from assessment-pipeline concepts)

- New `skills/assess/SKILL.md`: a standalone, read-only codebase health assessment. Workspace-aware: in workspace mode it scans every configured repo; in single mode, just the one.
- New `lib/fragility-scan.sh <repo-path>`: deterministic git-history fragility scoring (per-file commit churn, bugfix-commit density from conventional-commit `fix:` prefixes and fix-like keywords, recency weighting), emitting ranked JSON. Pure git + python3 stdlib; no LLM.
- The skill dispatches bounded reviewer subagents (existing `loop-spec:code-reviewer`) at the top-N hotspots, then synthesizes `docs/loop-spec/assessment/ASSESSMENT.md` with per-repo sections, a cross-repo ranked findings table, and prioritized fix recommendations.

### Workstream C -- quality-loop skill (adapted from quality-loop concepts)

- New `skills/quality-loop/SKILL.md`: an iterative review convergence loop over modified files, invocable standalone before committing. Workspace-aware scope resolution: explicit file args take precedence, else union of `git -C <repo> status --porcelain` modified code files across all repos in scope.
- Each iteration: (1) deterministic checks first -- project lint/typecheck/test commands plus the unresolved-marker scan; fix before personas run; (2) independent parallel persona reviews -- `loop-spec:code-reviewer` (engineering quality) and a new `loop-spec:security-reviewer` agent (adversarial/security) -- each blind to prior-round findings (review independence protocol); (3) fix findings; (4) repeat until convergence (zero blocking findings) or the round budget (default 3, `LOOP_SPEC_QUALITY_LOOP_MAX_ROUNDS`) is exhausted.
- Severity gate: security findings CRITICAL/HIGH block convergence; MEDIUM/LOW are advisory. Agents never self-suppress security findings; unresolved blockers are escalated to the user.
- New `lib/quality-loop-state.sh`: round/finding/convergence state tracker at `.loop-spec/quality-loop.json` (subcommands `scope`, `record-round`, `mark-clean`, `status`, `systemic`), with systemic-issue detection (same finding category in 2+ consecutive rounds escalates instead of looping).
- New `agents/security-reviewer.md` (sonnet, read-only tools) added per the contributor agent rules.

## Non-goals

- Porting any text, code, templates, or checker implementations from the proprietary vendor framework. Everything in workstreams B and C is re-derived behavior on loop-spec's stack; no proprietary content appears in any new file.
- AST/tree-sitter static analysis checkers. Deterministic checks are the project's own detected commands plus existing marker scans.
- Workspace-mode parity for the team, loop-fleet, and Workflow EXECUTE rungs. Workspace mode v1 runs the subagent rung only; the other rungs remain single-repo and are explicitly deferred.
- Feature worktrees or `EnterWorktree` in workspace mode. Workspace repos get in-place `feat/{slug}` branches.
- graphify and GSD ingestion in workspace mode (skipped with a log line; single-repo behavior unchanged).
- Cross-repo atomic commits or a meta-repo abstraction. Each repo keeps its own history, branch, and PR.
- A migration script for v6 features (none needed: `workspace` is optional and absent means single mode).
- Nested workspace discovery beyond immediate children (depth 1 only; deeper layouts use the explicit `workspace.json`).

## Constraints

- Runtime stack: `bash >= 4`, `git`, `jq >= 1.5`, `python3 >= 3.6` stdlib only. No npm, pip, or brew dependencies.
- Single-repo behavior is byte-compatible: with no `workspace.json` and cwd inside a git repo, every script and skill behaves exactly as today; all existing tests pass unmodified except where extended.
- All new lib scripts follow the house pattern: `set -euo pipefail`, subcommand dispatch, answers on stdout, usage errors exit 1.
- New skills use `${CLAUDE_SKILL_DIR}/../../lib/...` to reach bundled scripts (never `${CLAUDE_PLUGIN_ROOT}`).
- New agent file follows the contributor rules: bare role filename `agents/security-reviewer.md`, frontmatter `name`/`description`/`tools`/`model`, role boundary documented; referenced as `subagent_type: "loop-spec:security-reviewer"`.
- `tests/run-all.sh` stays green; every new lib script ships a test suite registered there.
- Commit format: `<type>: NO_JIRA <message>`.
- No em-dash character (U+2014) in any new or modified file.

## User-facing behavior

**Single repo (unchanged).** A user runs `/loop-spec:cycle add dark mode` inside a git repo. Everything works exactly as before; `feature.json` gains `"workspace": null` implicitly by absence and nothing else changes.

**Workspace parent.** A user has `~/product/{frontend,backend,db}` where each child is a git repo and `~/product` is not. From `~/product` they run `/loop-spec:cycle add audit logging end to end`. Cycle Step 0 runs `lib/workspace.sh detect`, announces `workspace mode: 3 repos (frontend, backend, db)`, and (interactively) confirms the repo list, or honors `LOOP_SPEC_ANSWER_REPOS=frontend,backend` non-interactively. State lands in `~/product/.loop-spec/`, artifacts in `~/product/docs/loop-spec/features/{slug}/`. Step 4 detects test/lint/typecheck per repo. Step 5 records per-repo `baseSha`/`baseBranch` and creates `feat/{slug}` in each participating repo in place. PLAN tasks each carry a `repo` field and workspace-relative file paths. EXECUTE announces `workspace mode -> rung capped at subagent` and runs waves where no two concurrent implementers share a repo; each implementer works directly in `<workspace>/<repo>` on the feature branch and commits with `git -C`. VERIFY scans markers, runs each repo's commands, pushes, and opens one PR per repo that has commits; it prints a per-repo summary table. A repo with no task commits is left untouched (no push, no PR, branch deleted on completion).

**Parent that is itself a git repo.** Detection prefers single mode. The user opts into workspace mode by writing `.loop-spec/workspace.json` listing the child repos; detection then honors the pin.

**Assessment.** From either mode the user runs `/loop-spec:assess`. The skill runs `lib/fragility-scan.sh` per repo (no LLM), prints the top hotspots, dispatches code-reviewer subagents to the top-N files (N bounded by tier-like budget, default 5 per repo, `LOOP_SPEC_ASSESS_TOP_N`), and writes `docs/loop-spec/assessment/ASSESSMENT.md` containing: scan metadata, per-repo fragility heat map tables, reviewer findings with severity, a cross-repo ranked findings table, and prioritized fix recommendations. Read-only with respect to source code; only the assessment doc is written.

**Quality loop.** After editing code (in either mode) the user runs `/loop-spec:quality-loop` (optionally with explicit file paths). The skill resolves scope, runs deterministic checks first and has findings fixed, then dispatches code-reviewer and security-reviewer in parallel with file content but zero prior-round context, records findings via `lib/quality-loop-state.sh record-round`, drives fixes, and repeats. It stops on convergence (zero blocking findings -> `mark-clean`), on round-budget exhaustion, or on systemic detection (same category 2+ consecutive rounds), escalating to the user in the non-clean cases. Security CRITICAL/HIGH always block; the agent presents them and waits for the user rather than suppressing.

## Success criteria

- [ ] `lib/workspace.sh detect` inside a git repo prints JSON with `"mode":"single"` and the repo toplevel as `root`.
  Verify: covered by `bash tests/lib/workspace.test.sh` case "single".
- [ ] `lib/workspace.sh detect` in a non-repo parent with two child git repos prints `"mode":"workspace"` with both repos listed (sorted by name); `list-repos` prints one `name<TAB>path` line per repo.
  Verify: `bash tests/lib/workspace.test.sh` case "discover".
- [ ] `lib/workspace.sh detect` honors `.loop-spec/workspace.json` (pin wins over single-mode detection; invalid entries fail with exit 1 and a clear message).
  Verify: `bash tests/lib/workspace.test.sh` cases "pin" and "pin-invalid".
- [ ] `lib/workspace.sh detect` in a directory that is neither a repo nor a parent of repos prints `"mode":"none"`.
  Verify: `bash tests/lib/workspace.test.sh` case "none".
- [ ] `lib/workspace.sh resolve-repo <root> <path>` maps a workspace-relative or absolute file path to its owning repo name (longest-prefix match) and prints empty for paths outside all repos.
  Verify: `bash tests/lib/workspace.test.sh` case "resolve".
- [ ] `lib/git-ops.sh -C <path> <cmd>` runs every subcommand against `<path>`; without `-C` behavior is unchanged (existing tests pass unmodified).
  Verify: `bash tests/lib/git-ops.test.sh` (extended with `-C` cases).
- [ ] `lib/checkpoint.sh -C <path> ...` and `lib/worktree-commit-check.sh -C <path> ...` target `<path>`; no-flag behavior unchanged.
  Verify: `bash tests/lib/worktree-commit-check.test.sh` extended `-C` case passes; checkpoint `-C` exercised in `tests/lib/workspace.test.sh` or its own case.
- [ ] `skills/shared/feature-state-schema.md` documents schemaVersion 7 with the optional `workspace` block and the `.loop-spec/workspace.json` format; absent/null workspace explicitly means single mode.
  Verify: `grep -c "workspace" skills/shared/feature-state-schema.md` returns 5 or more and `grep -nE '^\s*"schemaVersion": 7' skills/shared/feature-state-schema.md` matches at least once.
- [ ] `lib/validate-task-metadata.sh` accepts metadata with and without an optional `repo` string.
  Verify: `bash tests/lib/validate-task-metadata.test.sh` passes with new `repo` cases.
- [ ] `skills/cycle/SKILL.md` contains a workspace detection step that runs `lib/workspace.sh detect`, persists the result to `.loop-spec/runtime.json`, aborts with a clear message on `mode == "none"`, and branches Step 4/Step 5 per-repo in workspace mode (per-repo commands, per-repo `feat/{slug}` in-place branches, no `EnterWorktree`, graphify/GSD skipped with a log line).
  Verify: `grep -c "workspace" skills/cycle/SKILL.md` returns 8 or more.
- [ ] `skills/plan/SKILL.md` and `agents/planner.md` require a `repo` field per task (in both the planner's `tasks[]` JSON shape and the PLAN.md task-block format) and workspace-relative `files[]` in workspace mode.
  Verify: `grep -cE '"repo"|repo:' skills/plan/SKILL.md` returns 2 or more and `grep -cE '"repo"|repo:' agents/planner.md` returns 2 or more.
- [ ] `skills/execute/SKILL.md` documents the workspace dispatch path: rung hard-pinned to subagent BEFORE `featureWorktreeRoot` is resolved (the `git rev-parse --show-toplevel` line must not run at a non-repo workspace root), `LOOP_SPEC_EXECUTE_LOOPS=1` is refused with an escalation in workspace mode, one implementer per repo concurrently, in-place commits via `git -C`, no per-task worktrees.
  Verify: `grep -c "workspace" skills/execute/SKILL.md` returns 5 or more (smoke check; behavior asserted by opus verification pass).
- [ ] `skills/verify/SKILL.md` documents per-repo marker scan, per-repo commands, per-repo push/PR for repos with commits, VERIFICATION.md at workspace root committed only when the root is a git repo, no `ExitWorktree` in workspace mode, and a workspace guard on Step 9's `WORKTREE_ABS=$(git rev-parse --show-toplevel)` (resolved only in single mode).
  Verify: `grep -c "workspace" skills/verify/SKILL.md` returns 5 or more (smoke check; behavior asserted by opus verification pass).
- [ ] `skills/map-codebase/SKILL.md` handles workspace mode: `project_id` derives from the workspace root basename (not `git rev-parse --show-toplevel`, which fails at a non-repo root) and mappers receive the repo list.
  Verify: `grep -c "workspace" skills/map-codebase/SKILL.md` returns 2 or more.
- [ ] `hooks/restrict-agent-paths.test.sh` includes a case proving spec-writer/planner writes are still correctly scoped when paths are workspace-rooted.
  Verify: `bash hooks/restrict-agent-paths.test.sh` passes with the new case.
- [ ] `lib/pause-snapshot.sh` emits a per-repo uncommitted-changes section when the feature has a workspace block.
  Verify: `bash lib/pause-snapshot.test.sh` passes with the new case.
- [ ] `lib/fragility-scan.sh <repo>` emits valid JSON ranking files by a fragility score derived from churn, bugfix density, and recency; deterministic across runs on a fixed fixture repo.
  Verify: `bash tests/lib/fragility-scan.test.sh`.
- [ ] `skills/assess/SKILL.md` exists with frontmatter (`name: assess`, non-empty description), is workspace-aware, bounds reviewer dispatch by `LOOP_SPEC_ASSESS_TOP_N` (default 5), writes only `docs/loop-spec/assessment/ASSESSMENT.md`, and references `${CLAUDE_SKILL_DIR}` for lib access.
  Verify: `grep -c "fragility-scan.sh\|ASSESSMENT.md\|LOOP_SPEC_ASSESS_TOP_N\|CLAUDE_SKILL_DIR" skills/assess/SKILL.md` returns 4 or more.
- [ ] `lib/quality-loop-state.sh` supports `scope`, `record-round`, `mark-clean`, `status`, `systemic` against `.loop-spec/quality-loop.json` with atomic writes; systemic detection fires on the same category in 2 consecutive rounds.
  Verify: `bash tests/lib/quality-loop-state.test.sh`.
- [ ] `skills/quality-loop/SKILL.md` exists with frontmatter (`name: quality-loop`), documents scope precedence (explicit args > modified files across workspace repos), deterministic-checks-first ordering, the review independence protocol (no prior findings in reviewer prompts), the severity gate (security CRITICAL/HIGH block; MEDIUM/LOW advisory; never self-suppress), round budget `LOOP_SPEC_QUALITY_LOOP_MAX_ROUNDS` (default 3), and systemic escalation.
  Verify: `grep -c "independence\|CRITICAL\|LOOP_SPEC_QUALITY_LOOP_MAX_ROUNDS\|systemic\|quality-loop-state.sh" skills/quality-loop/SKILL.md` returns 5 or more.
- [ ] `agents/security-reviewer.md` exists with `name: security-reviewer`, a read-only tool allow-list (`Read`, `Glob`, `Grep` only; no Bash, no Write/Edit) in YAML-list syntax matching the other agent files, sonnet default model, and a documented role boundary; `tests/validate-agents.sh` `EXPECTED` default bumped from 12 to 13.
  Verify: `bash tests/validate-agents.sh` exits 0 and prints `All 13 agents validated.`
- [ ] New test suites (`workspace`, `fragility-scan`, `quality-loop-state`) are registered in `tests/run-all.sh`.
  Verify: `grep -c "workspace.test.sh\|fragility-scan.test.sh\|quality-loop-state.test.sh" tests/run-all.sh` returns 3.
- [ ] `bash tests/run-all.sh` exits 0 with no failed suites.
  Verify: `bash tests/run-all.sh`.
- [ ] README documents: workspace mode (detection rules, `workspace.json`, per-repo branches/PRs, subagent-rung cap), the assess skill, and the quality-loop skill; both new skills appear in the skills list. CHANGELOG `[Unreleased]` documents all additions.
  Verify: `grep -c "workspace" README.md` returns 6 or more; `grep -c "assess\|quality-loop" README.md` returns 4 or more; `grep -c "workspace\|assess\|quality-loop" CHANGELOG.md` returns 6 or more.
- [ ] No file under `skills/assess/`, `skills/quality-loop/`, `agents/security-reviewer.md`, `lib/fragility-scan.sh`, or `lib/quality-loop-state.sh` contains vendor-identifying strings from the proprietary reference material or the word "Proprietary".
  Verify: `grep -ril "proprietary" skills/assess skills/quality-loop agents/security-reviewer.md lib/fragility-scan.sh lib/quality-loop-state.sh` returns no matches.
- [ ] No em-dash (U+2014) in any new or modified file.
  Verify: `python3 -c "import sys,pathlib; bad=[p for p in map(pathlib.Path, sys.argv[1:]) if '—' in p.read_text()]; sys.exit(1 if bad else 0)" lib/workspace.sh lib/fragility-scan.sh lib/quality-loop-state.sh skills/assess/SKILL.md skills/quality-loop/SKILL.md agents/security-reviewer.md` exits 0.

## Out of scope

- Team/loop-fleet/Workflow rungs in workspace mode (deferred; subagent rung only).
- Feature worktrees in workspace mode (in-place branches by design; revisit if branch pollution proves painful).
- Porting MAF's LSP warm pool, tree-sitter checks, validation-pass subagent fan-out, or the 13-deliverable assessment report suite. The adapted skills produce one deliverable each.
- Pre-commit blocking hooks for quality-loop (MAF gates commits via hooks; loop-spec v1 keeps quality-loop advisory and user-invoked).
- map-codebase per-repo doc trees (`docs/loop-spec/codebase/` stays a single set; mappers are told the repo list in workspace mode).

## Open questions

(resolved during planning; none outstanding)
