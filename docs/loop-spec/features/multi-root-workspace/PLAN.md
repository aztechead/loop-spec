# Multi-root workspace support + assess and quality-loop skills - Implementation Plan

**Spec:** `docs/loop-spec/features/multi-root-workspace/SPEC.md`
**Created:** 2026-06-12

## Architecture overview

Three workstreams sharing one foundation. Workstream A introduces a workspace resolver (`lib/workspace.sh`) and threads an optional repo target (`-C <path>`) through the three git-touching lib scripts, then teaches the cycle/plan/execute/verify skills a workspace branch alongside the existing single-repo branch. The feature state schema gains an optional `workspace` block (v7); absence means single mode, so v6 features and all current behavior are untouched. Workstreams B and C are additive skills plus deterministic lib helpers, both consuming `lib/workspace.sh` so they are workspace-aware from day one. No existing skill content is restructured; workspace paths are added as clearly-marked conditional sections.

Concept provenance note: workstreams B and C adapt ideas (iterative review convergence, review independence, severity-gated blocking, churn-based fragility ranking, synthesized assessment reporting) from two proprietary reference skills. All text, structure, and code are written fresh for loop-spec; no proprietary content, identifiers, or framework references may appear (SPEC criterion bans "Viasat", "MAF", "maf.paths", "Proprietary" strings in new files).

## Assumptions

- Workspace discovery is depth-1 only: immediate children of the invocation dir with a `.git` entry (dir or file). Hidden dirs (dotfiles) are skipped.
- `workspace.json` lives at `.loop-spec/workspace.json` relative to the invocation dir. It is runtime config (the `.loop-spec/` dir is gitignored in repos; at a non-repo workspace root gitignore is moot).
- In workspace mode the harness session cwd stays at the workspace root for the whole cycle. Subagents receive absolute repo paths in their prompts (the existing "subagents do not inherit cwd" rule).
- `git -C` semantics: relative paths passed to git resolve against the `-C` dir; this is what makes the flag sufficient without `cd`.
- Per-repo feature branches are created in place (the user's checkout switches branches). This is documented loudly in README; a dirty repo aborts cycle Step 5 with instructions.
- `gh` CLI may be absent or a repo may have no `origin` remote; VERIFY's per-repo push/PR step degrades to printing the manual commands (same spirit as current single-repo behavior on push failure).

## File map

Create:
- `lib/workspace.sh` - workspace mode resolver
- `tests/lib/workspace.test.sh` - unit tests (single/discover/pin/pin-invalid/none/resolve + checkpoint -C case)
- `lib/fragility-scan.sh` - git churn/bugfix fragility ranking (JSON out)
- `tests/lib/fragility-scan.test.sh` - fixture-repo tests
- `lib/quality-loop-state.sh` - quality-loop round/convergence state CLI
- `tests/lib/quality-loop-state.test.sh` - unit tests
- `skills/assess/SKILL.md` - assessment skill
- `skills/quality-loop/SKILL.md` - quality loop skill
- `agents/security-reviewer.md` - adversarial/security review persona (read-only)

Modify:
- `lib/git-ops.sh` - global `-C <path>` option
- `tests/lib/git-ops.test.sh` - `-C` cases
- `lib/checkpoint.sh` - `-C <path>` option
- `lib/worktree-commit-check.sh` - `-C <path>` option
- `tests/lib/worktree-commit-check.test.sh` - `-C` case
- `lib/validate-task-metadata.sh` - optional `repo` field
- `tests/lib/validate-task-metadata.test.sh` - `repo` cases
- `lib/pause-snapshot.sh` - per-repo uncommitted section
- `lib/pause-snapshot.test.sh` - workspace case
- `skills/shared/feature-state-schema.md` - schema v7 + workspace.json format
- `skills/cycle/SKILL.md` - Step 0 detection + workspace branches of Steps 4/5/5.4/5.5 + v7 resume
- `skills/map-codebase/SKILL.md` - workspace-safe project_id + repo-list dispatch
- `skills/shared/cycle-resume-escalation.md` - workspace resume note
- `tests/validate-agents.sh` - EXPECTED default 12 -> 13
- `skills/plan/SKILL.md` - per-task `repo` field rules
- `agents/planner.md` - repo-tagging instructions
- `skills/execute/SKILL.md` - workspace dispatch path
- `skills/shared/execute-subagent.md` - workspace wave rules (one implementer per repo)
- `skills/verify/SKILL.md` - per-repo verify/push/PR path
- `hooks/restrict-agent-paths.test.sh` - workspace-root path case
- `agents/README.md` - security-reviewer row
- `tests/run-all.sh` - register 3 new suites
- `README.md` - workspace mode + 2 new skills
- `CHANGELOG.md` - [Unreleased] entries
- `docs/adopting.md` - workspace adoption note

## Task DAG

| ID | Subject | BlockedBy | Files | Scope |
|----|---------|-----------|-------|-------|
| task-001 | lib/workspace.sh + tests | - | lib/workspace.sh, tests/lib/workspace.test.sh | medium |
| task-002 | git-ops.sh -C support | - | lib/git-ops.sh, tests/lib/git-ops.test.sh | small |
| task-003 | checkpoint.sh + worktree-commit-check.sh -C | - | lib/checkpoint.sh, lib/worktree-commit-check.sh, tests/lib/worktree-commit-check.test.sh | small |
| task-004 | schema v7 docs | - | skills/shared/feature-state-schema.md | small |
| task-005 | validate-task-metadata optional repo | - | lib/validate-task-metadata.sh, tests/lib/validate-task-metadata.test.sh | small |
| task-006 | lib/fragility-scan.sh + tests | - | lib/fragility-scan.sh, tests/lib/fragility-scan.test.sh | medium |
| task-007 | lib/quality-loop-state.sh + tests | - | lib/quality-loop-state.sh, tests/lib/quality-loop-state.test.sh | medium |
| task-008 | cycle SKILL workspace path | task-001, task-002, task-004 | skills/cycle/SKILL.md, skills/map-codebase/SKILL.md, skills/shared/cycle-resume-escalation.md | medium |
| task-009 | plan SKILL + planner repo field | task-004, task-005 | skills/plan/SKILL.md, agents/planner.md | small |
| task-010 | execute SKILL workspace path | task-004, task-008 | skills/execute/SKILL.md, skills/shared/execute-subagent.md | medium |
| task-011 | verify SKILL workspace path | task-003, task-004, task-008 | skills/verify/SKILL.md | medium |
| task-012 | pause-snapshot workspace + hook test case | task-001, task-004 | lib/pause-snapshot.sh, lib/pause-snapshot.test.sh, hooks/restrict-agent-paths.test.sh | small |
| task-013 | assess skill | task-001, task-006 | skills/assess/SKILL.md | medium |
| task-014 | quality-loop skill + security-reviewer agent | task-001, task-007 | skills/quality-loop/SKILL.md, agents/security-reviewer.md, agents/README.md, tests/validate-agents.sh | medium |
| task-015 | run-all.sh registration | task-001, task-006, task-007, task-012 | tests/run-all.sh | small |
| task-016 | docs (README/CHANGELOG/adopting) | task-008, task-009, task-010, task-011, task-013, task-014 | README.md, CHANGELOG.md, docs/adopting.md | small |

Implementation waves (one sonnet subagent per task; no two concurrent tasks share a file):
- Wave 1: task-001 .. task-007 (7 parallel)
- Wave 2: task-008, task-009, task-012, task-013, task-014 (5 parallel)
- Wave 3: task-010, task-011, task-015 (3 parallel)
- Wave 4: task-016

## Tasks

---

### task-001: lib/workspace.sh + tests

**Goal:** Workspace mode resolver with deterministic JSON output.

**CLI contract:**

```
workspace.sh detect [dir]
  -> {"mode":"single","root":"<abs toplevel>"}
   | {"mode":"workspace","root":"<abs dir>","source":"config|discovered","repos":[{"name":"frontend","path":"frontend"}, ...]}
   | {"mode":"none","root":"<abs dir>"}
workspace.sh list-repos [dir]      -> one "name<TAB>path" line per repo (workspace mode); exit 1 + message otherwise
workspace.sh resolve-repo <root> <path>  -> repo name owning <path> (longest prefix match over configured/discovered repos), or empty output if none
```

Detection order for `detect`:
1. `dir` defaults to `$PWD`; normalize to absolute.
2. If `<dir>/.loop-spec/workspace.json` exists: mode=workspace, source=config. Parse with jq: `.repos[] | {name, path}`. Validate each: path exists, is a dir, and `git -C <abs path> rev-parse --is-inside-work-tree` succeeds; on any invalid entry exit 1 with `workspace.json: repo '<name>' invalid: <reason>`.
3. Else if `git -C "$dir" rev-parse --is-inside-work-tree` succeeds: mode=single, root=`git -C "$dir" rev-parse --show-toplevel`.
4. Else scan immediate children (skip names starting with `.`): child qualifies when `<child>/.git` exists (dir OR file). One or more children -> mode=workspace, source=discovered, repos sorted by name, path = child basename. Zero -> mode=none.

House style: `set -euo pipefail`, subcommand case dispatch, stdout answers, usage exit 1. JSON built with jq.

**Tests** (`tests/lib/workspace.test.sh`, temp-dir fixtures, pattern from `tests/lib/worktree-commit-check.test.sh` using `git -C`): cases `single` (run `detect` from a nested subdir of the fixture repo; root must be the toplevel), `discover` (2 child repos + 1 plain dir + 1 hidden dir), `pin` (workspace.json subset wins inside a parent that IS a git repo), `pin-invalid` (nonexistent path -> exit 1; duplicate repo names -> exit 1; missing schemaVersion tolerated; unknown extra fields tolerated), `none`, `resolve` (file in repo, file outside, absolute and relative inputs).

**Verify:** `bash tests/lib/workspace.test.sh`

**Acceptance criteria:**
- [ ] All 6 test cases pass.
- [ ] `detect` output is valid JSON (`jq .` accepts) in all modes.
- [ ] No em-dash in new files.

---

### task-002: git-ops.sh -C support

**Goal:** Global `-C <path>` option; default behavior byte-identical.

Parse optional leading `-C <path>` before the subcommand: build `G=(git)` or `G=(git -C "$path")` and replace every bare `git ` invocation with `"${G[@]}"`. `create-feature-worktree`: when `-C` is given, the worktree path printed/created must be `<path>/.claude/worktrees/<slug>` (pass the absolute path to `git worktree add` to avoid cwd-relative surprises); without `-C`, keep the literal relative `.claude/worktrees/<slug>` output (existing callers and tests depend on it). `list-feature-worktrees` honors `-C`. Update usage string.

**Tests:** extend `tests/lib/git-ops.test.sh`: `-C` from outside the fixture repo for `detect-base-branch`, `current-sha`, `ensure-clean-or-stash`, `create-feature-worktree` (worktree lands inside fixture repo), `list-feature-worktrees`. Existing no-flag cases must pass unmodified.

**Verify:** `bash tests/lib/git-ops.test.sh`

**Acceptance criteria:**
- [ ] All pre-existing cases pass without edits to their assertions.
- [ ] New `-C` cases pass from an unrelated cwd.

---

### task-003: checkpoint.sh + worktree-commit-check.sh -C

**Goal:** Same `-C <path>` pattern in both scripts.

`lib/checkpoint.sh`: leading `-C <path>` option; all `git tag`/`git checkout`/`git add`/`git commit` calls go through `"${G[@]}"`. The `git checkout "$tag" -- .` path-spec `.` must become the repo root when `-C` is set (use `"${G[@]}" checkout "$tag" -- :/` or an absolute path) so it restores the target repo's tree, not the caller cwd.
`lib/worktree-commit-check.sh`: leading `-C <path>`; both `rev-parse --verify` calls and the `rev-list --count` go through `"${G[@]}"`. Update usage strings in both.

**Tests:** extend `tests/lib/worktree-commit-check.test.sh` with a `-C` case run from outside the fixture repo (the file already builds repos with `git -C`). checkpoint `-C` is covered by a case added here or in tests/lib/workspace.test.sh (author's choice; state where).

**Verify:** `bash tests/lib/worktree-commit-check.test.sh`

**Acceptance criteria:**
- [ ] Existing cases pass unmodified; new `-C` cases pass.
- [ ] `checkpoint.sh -C` restore path affects only the target repo (assert a file outside it is untouched).

---

### task-004: schema v7 docs

**Goal:** Document schemaVersion 7 in `skills/shared/feature-state-schema.md`.

Add to the schema JSON block and prose:

```json
"schemaVersion": 7,
"workspace": {
  "root": "absolute path of the workspace parent",
  "repos": [
    {"name": "frontend", "path": "frontend", "branch": "feat/{slug}",
     "baseSha": "sha", "baseBranch": "main",
     "commands": {"test": "", "lint": "", "typecheck": ""}}
  ]
}
```

Rules to state: `workspace` absent or null = single mode (v6 features load unchanged; no migration); in workspace mode top-level `branch`/`baseSha`/`baseBranch`/`worktreePath` are null and the per-repo values are authoritative; top-level `commands` holds empty strings. Document `.loop-spec/workspace.json` format (`{"schemaVersion": 1, "repos": [{"name","path"}]}`) and when to pin (parent is itself a git repo, or subset selection). Document the new optional task-metadata field `repo` (string, workspace mode only) in the "Harness task list usage" section.

**Verify:** `grep -n "schemaVersion" skills/shared/feature-state-schema.md | head -3` shows 7; `grep -c "workspace" skills/shared/feature-state-schema.md` >= 5.

**Acceptance criteria:**
- [ ] v7 block, workspace.json format, `repo` metadata field all documented.
- [ ] Explicit "absent/null = single mode, no migration" sentence present.

---

### task-005: validate-task-metadata optional repo

**Goal:** Accept (never require) `repo` as a string field.

Read `lib/validate-task-metadata.sh` first; follow its existing optional-field pattern (the user-gate fields). Reject non-string `repo` values.

**Tests:** extend `tests/lib/validate-task-metadata.test.sh`: present-valid, absent, present-invalid (number) -> reject.

**Verify:** `bash tests/lib/validate-task-metadata.test.sh`

---

### task-006: lib/fragility-scan.sh + tests

**Goal:** Deterministic per-file fragility ranking from git history. No LLM.

**CLI contract:**

```
fragility-scan.sh <repo-path> [--since <date|sha>] [--top <N>]
  -> {"repo":"<abs path>","generatedAt":"ISO-8601","window":"<since or 'all'>",
      "files":[{"path":"src/x.py","commits":12,"bugfixCommits":5,"lastTouched":"ISO-8601","score":0.83}, ...]}
```

Implementation: one `git -C <repo> log --numstat --date=iso-strict --pretty=format:...` pass piped to inline python3 that aggregates per file: total commits touching it, bugfix commits (subject matches `^fix[(!:]` or contains word `bug`/`regression`/`hotfix`, case-insensitive), last-touched date. Score = normalized `0.5*churn_rank + 0.35*bugfix_density + 0.15*recency` (each component scaled 0..1 over the scanned set); sort desc, stable tiebreak by path. `--top` truncates (default 50). Exclude deleted files (skip paths absent from `git -C <repo> ls-files`). Non-repo path -> exit 1 with message. Empty history -> `"files": []`.

**Tests** (`tests/lib/fragility-scan.test.sh`): build a fixture repo with scripted commits (3 commits to a.py, 1 `fix:` commit to b.py, deleted file c.py); assert valid JSON, a.py ranks first by churn, c.py absent, deterministic across two runs (byte-equal after dropping `generatedAt`), exit 1 on non-repo.

**Verify:** `bash tests/lib/fragility-scan.test.sh`

---

### task-007: lib/quality-loop-state.sh + tests

**Goal:** Round/finding/convergence tracker at `.loop-spec/quality-loop.json`.

**CLI contract** (state file path from `$LOOP_SPEC_QL_STATE` else `.loop-spec/quality-loop.json`; atomic write tmp+rename like `lib/feature-write.sh`):

```
quality-loop-state.sh scope <file>...            # set current scope; resets rounds for files whose entry is missing; prints count
quality-loop-state.sh record-round <file> <round> <findings-json>
    # findings-json: [{"source":"code-reviewer|security-reviewer|deterministic","category":"...","severity":"CRITICAL|HIGH|MEDIUM|LOW","claim":"...","line":N}]
quality-loop-state.sh status [<file>]            # JSON: per-file {rounds, lastFindingCount, blockingCount, clean}
quality-loop-state.sh mark-clean <file> <round>  # refuses (exit 2) if last round has blocking findings (any deterministic finding, any code-reviewer finding, security CRITICAL/HIGH)
quality-loop-state.sh systemic <file>            # prints category names appearing in the last 2 consecutive rounds; exit 0 with output = systemic, no output = none
```

**Tests** (`tests/lib/quality-loop-state.test.sh`): scope init; record two rounds; mark-clean refused while blocking findings exist then succeeds on a zero-blocking round; security MEDIUM does not block, HIGH does; systemic fires on repeated category across rounds 2 and 3; state file is valid JSON after every command; `LOOP_SPEC_QL_STATE` override honored.

**Verify:** `bash tests/lib/quality-loop-state.test.sh`

---

### task-008: cycle SKILL workspace path

**Goal:** Add workspace mode to `skills/cycle/SKILL.md` (plus map-codebase and resume-escalation touch-ups) without restructuring existing single-repo content.

Edits (surgical, additive):
1. New "Step 0 - Workspace detection" before Step 1: run `bash "${CLAUDE_SKILL_DIR}/../../lib/workspace.sh" detect`, merge `workspaceMode` / `workspaceRoot` / `workspaceRepos` into `.loop-spec/runtime.json` (same python3 merge-write pattern as the workflow probe). `mode == "none"` -> abort with: not a git repo and no child repos found; cd into a repo or create `.loop-spec/workspace.json`. `mode == "workspace"` -> announce repo list; interactively confirm via one AskUserQuestion whose question text explicitly states that a `feat/{slug}` branch will be created IN PLACE in each listed repo (options: all repos / customize); non-interactive: `LOOP_SPEC_ANSWER_REPOS` csv filter, default all. Also print a one-line advisory that `.loop-spec/` at the workspace root should be gitignored if the root is (or becomes) a repo.
2. Step 4: in workspace mode run the same detection per repo (`<root>/<path>` as the probe dir) and collect per-repo commands; single confirmation question listing all.
3. Step 5: workspace branch -- TWO-PHASE: phase 1 scans ALL participating repos with `git-ops.sh -C <abs repo> ensure-clean-or-stash` and aborts (listing every dirty repo, asking the user to commit/stash) before ANY branch is created; phase 2 only runs when all repos are clean -- per repo: `base_sha=$(git -C <abs repo> rev-parse HEAD)`, `base_branch=$(git-ops.sh -C <abs repo> detect-base-branch)`, `git -C <abs repo> checkout -b "feat/${slug}" "$base_sha"`. NO `create-feature-worktree`, NO `EnterWorktree`. feature.json: in the existing Step 5 jq blob, change the literal `schemaVersion: 6` to `schemaVersion: 7`, add `workspace: null` for single mode, and in workspace mode set `--arg`-driven nulls for top-level `branch`/`baseSha`/`baseBranch`/`worktreePath` plus an `--argjson workspace` block per task-004 schema (commands top-level empty strings). Single-mode features keep all current top-level values (only the version number and the `workspace: null` key change). State and `docs/loop-spec/features/{slug}/` dirs created at the workspace root.
4. Step 5.4/5.5: workspace mode skips graphify and GSD ingest with one log line each; mapper dispatch passes the repo list (`Repos: name=abs-path, ...`) instead of a single WT_ROOT (do NOT run `git rev-parse --show-toplevel` at a non-repo root), instructing mappers to cover each repo with per-repo sections; doc commits happen only when `git -C "$workspaceRoot" rev-parse --is-inside-work-tree` succeeds, else log `workspace root not a git repo; leaving codebase docs uncommitted`.
5. Step 1 resume: add an explicit branch -- `schemaVersion == 7` AND `workspace != null` resumes IN PLACE at the workspace root: no worktree probe, no `EnterWorktree`; assert cwd == `workspace.root` (else tell the user to cd there and re-invoke). `schemaVersion == 7` with `workspace == null` follows the existing v6 worktree-resume path unchanged. Mirror this rule with a short "Workspace features" note in `skills/shared/cycle-resume-escalation.md`.
6. `skills/map-codebase/SKILL.md`: derive `project_id` from `basename "$(lib/workspace.sh detect | jq -r .root)"` style logic (workspace root basename in workspace mode; repo toplevel basename in single mode -- never bare `git rev-parse --show-toplevel` without a repo check), and pass the repo list to mappers in workspace mode.

Number the new step "Step 0" and keep all existing step numbers stable.

**Verify:** `grep -c "workspace" skills/cycle/SKILL.md` >= 8; existing step headings unchanged (`grep -c "^### Step" skills/cycle/SKILL.md` increases by exactly 1); `grep -c "workspace" skills/map-codebase/SKILL.md` >= 2.

---

### task-009: plan SKILL + planner repo field

**Goal:** Repo-tagged tasks in workspace mode.

`skills/plan/SKILL.md`: add a workspace subsection to the task-format rules: when `feature.workspace` is non-null every task MUST carry `repo: <name>` matching a `workspace.repos[].name`, `files[]` are workspace-relative (`<repo>/<path>`), and every file in a task must resolve (via `lib/workspace.sh resolve-repo`) to that task's repo (one task = one repo; cross-repo work = multiple tasks with `blockedBy` edges). The `repo` field must be added in BOTH places the plan is expressed: the PLAN.md task-block format (a `repo:` line per task block) AND the planner's `tasks[]` JSON shape. `agents/planner.md`: extend the two task-shape lines ("tasks array returned in the completion message" and the "Each task has: id, subject, files, ..." list) with `repo` (workspace mode only), state the one-task-one-repo rule, and include an example task block with `repo`. Note: `lib/plan-to-loop.sh`, `lib/dag-width.sh`, and `lib/plan-adherence.sh` ignore unknown task keys, so no changes there.

**Verify:** `grep -c "repo" skills/plan/SKILL.md` and `grep -c "repo" agents/planner.md` both >= 2 in the added sections; `bash tests/validate-agents.sh` exits 0.

---

### task-010: execute SKILL workspace path

**Goal:** Workspace dispatch in `skills/execute/SKILL.md` + `skills/shared/execute-subagent.md`.

`skills/execute/SKILL.md` additive edits:
1. Step 1: workspace branch check -- for each `workspace.repos[]`: `git -C <abs repo> branch --show-current` must equal `feat/{slug}`, else abort (mirror of the existing schema-6 assert).
2. Step 3 entry: when `feature.workspace` non-null, hard-pin the rung BEFORE anything else in Step 3: skip the `featureWorktreeRoot=$(git rev-parse --show-toplevel)` line entirely (the workspace root may not be a git repo; under skill-level `set -e` semantics that command aborts the phase), skip Step 3a/3b ladder evaluation, set `rung = "subagent"`, announce `[EXECUTE] workspace mode -> rung capped at subagent (repos: N)`. If `LOOP_SPEC_EXECUTE_LOOPS=1` is set in workspace mode, refuse with an escalation message (loop-fleet rung is single-repo only) instead of silently ignoring it.
3. Step 2 conflict detection: unchanged logic; note that workspace-relative paths make cross-repo overlaps naturally disjoint.

`skills/shared/execute-subagent.md` additive section "Workspace mode": wave construction must never schedule two tasks with the same `repo` concurrently (group ready tasks by repo, take at most one per repo per wave, still capped by maxParallelImplementers); implementer prompts include `repo`, the absolute repo path, and the branch, and instruct: edit files directly in that repo (NO task worktree), run the task's verifyCommand with cwd = repo path, commit with `git -C <abs repo>` using the house commit format; the lead's per-task merge/ff steps are skipped in workspace mode (commits land on `feat/{slug}` directly); the lead verifies completion per task via `lib/worktree-commit-check.sh -C <abs repo> <baseSha> feat/{slug}` style commit-presence checks (commits over the repo's baseSha grew).

**Verify:** `grep -c "workspace" skills/execute/SKILL.md` >= 5; `grep -c "workspace" skills/shared/execute-subagent.md` >= 3.

---

### task-011: verify SKILL workspace path

**Goal:** Per-repo VERIFY in `skills/verify/SKILL.md`.

Additive workspace branches:
- Step 1 marker scan: loop repos, `git -C <abs repo> diff --diff-filter=ACMR <repo.baseSha>..HEAD --name-only` with the same grep pipeline.
- Steps 4/6 briefs: include the per-repo command map and repo paths; verifier runs each repo's commands with cwd = that repo.
- Step 9 map-codebase refresh: pass the repo list; skip graphify in workspace mode; guard `WORKTREE_ABS="$(git rev-parse --show-toplevel)"` so it only runs in single mode (workspace mode passes the per-repo absolute paths instead; the workspace root may not be a repo).
- Step 10: per repo with commits over baseSha: `git -C <abs repo> push -u origin feat/{slug}` and `gh pr create` run with cwd = repo (or `--repo` resolution); a repo with zero commits is skipped, its branch deleted (`git -C <abs repo> checkout <baseBranch> && git -C <abs repo> branch -d feat/{slug}`); push/PR failure degrades to printing manual commands, never aborts the loop over other repos.
- Step 11: commit VERIFICATION.md only when the workspace root is a git repo; checkpoint tag per repo via `lib/checkpoint.sh -C`.
- Step 13: skip ExitWorktree when `feature.workspace` non-null.
- Step 14 summary: per-repo table (repo, commits, PR URL or skip reason).

**Verify:** `grep -c "workspace" skills/verify/SKILL.md` >= 5.

---

### task-012: pause-snapshot workspace + hook test case

**Goal:** Workspace-aware pause snapshots; prove the path guard at a workspace root.

`lib/pause-snapshot.sh`: when the feature json has a non-null `workspace`, the uncommitted-files section iterates `workspace.repos[]` running `git -C <abs repo> diff --name-only HEAD` (and status porcelain) under a `### <repo name>` heading each. Single mode output unchanged. Extend `lib/pause-snapshot.test.sh` with a workspace fixture: the existing fixture pattern is `mktemp -d` + heredoc `feature.json` + `--feature-dir` invocation, but it never builds a real git repo -- the workspace case MUST `git init -q` two temp repos (with one committed file and one uncommitted edit each) so the per-repo git path is genuinely exercised.

`hooks/restrict-agent-paths.test.sh`: add a case where the file path is an absolute path under a workspace root (`/tmp/.../workspace/docs/loop-spec/features/x/SPEC.md`) with caller spec-writer -> allowed, and a workspace-repo source path (`/tmp/.../workspace/frontend/src/app.py`) with caller spec-writer -> denied. No hook code change expected; if the case fails, fix `path_allowed` minimally.

**Verify:** `bash lib/pause-snapshot.test.sh && bash hooks/restrict-agent-paths.test.sh`

---

### task-013: assess skill

**Goal:** `skills/assess/SKILL.md` per SPEC workstream B.

Frontmatter: `name: assess`, description (codebase fragility/health assessment, workspace-aware, writes ASSESSMENT.md), `allowed-tools: Bash Read Glob Grep Agent AskUserQuestion Write`.

Procedure: (1) `lib/workspace.sh detect` -> repo set (single repo or workspace repos; mode none -> abort). (2) Per repo: `bash "${CLAUDE_SKILL_DIR}/../../lib/fragility-scan.sh" <abs repo> --top 20`, print top table. (3) Reviewer dispatch: top `LOOP_SPEC_ASSESS_TOP_N` (default 5) files per repo, one-shot `Agent` calls `subagent_type: "loop-spec:code-reviewer"`, model `claude-sonnet-4-6` (hardcoded literal in the skill with a one-line note: assess runs standalone with no feature.json, so there is no `feature.models` map to read; keep in sync with `skills/shared/model-matrix.md`), parallel, prompts carrying absolute file path + fragility stats, asking for severity-ranked findings (read-only; output findings as JSON in the reply). (4) Synthesize `docs/loop-spec/assessment/ASSESSMENT.md`: header with scan metadata; per-repo fragility heat map table; reviewer findings table (file, line, severity, claim); cross-repo ranked findings (CRITICAL>HIGH>MEDIUM>LOW, then fragility score); prioritized fix recommendations; explicit "advisory, no gate" note. (5) Only that one file is written; nothing is committed.

**Verify:** `grep -c "fragility-scan.sh\|ASSESSMENT.md\|LOOP_SPEC_ASSESS_TOP_N\|CLAUDE_SKILL_DIR" skills/assess/SKILL.md` >= 4; no banned strings (`grep -il "viasat\|maf" skills/assess/SKILL.md` empty).

---

### task-014: quality-loop skill + security-reviewer agent

**Goal:** `skills/quality-loop/SKILL.md`, `agents/security-reviewer.md`, agents/README row, validate-agents count bump.

Agent file: `name: security-reviewer`, description (adversarial security review persona: input handling, authz, injection, secrets, unsafe defaults; severity-ranked findings; never suppresses). Tools allow-list is `Read`, `Glob`, `Grep` ONLY (no Bash, no Write/Edit -- strictly read-only, so no `hooks/restrict-agent-paths.sh` case is needed per the contributor rules), written in the same YAML frontmatter syntax as `agents/code-reviewer.md` and `agents/planner.md` (read both first and match exactly: list vs csv form). `model: claude-sonnet-4-6` matching the other agent files' convention. Role boundary: reports findings only; never edits files; never acknowledges/suppresses its own findings; CRITICAL/HIGH are blocking by contract.

`tests/validate-agents.sh`: bump the hardcoded default `EXPECTED="${EXPECTED:-12}"` to `EXPECTED="${EXPECTED:-13}"`.

Skill frontmatter: `name: quality-loop`, description (iterative pre-commit review convergence loop), `allowed-tools: Bash Read Write Edit Glob Grep Agent AskUserQuestion`.

Procedure: (0) scope: explicit `$ARGUMENTS` file paths win; else `lib/workspace.sh detect` and union of modified code files per repo (`git -C <abs repo> status --porcelain`, filter code extensions .py .ts .tsx .js .jsx .go .rs .c .h .cpp .hpp .sh, exclude deleted); empty scope -> "nothing to review", stop. Persist via `quality-loop-state.sh scope`. (1) deterministic pass: per affected repo run detected lint/typecheck (and test command when scope touches tested code) plus the unresolved-marker grep from VERIFY Step 1; record as `source:"deterministic"` findings; fix them (main thread edits) before any persona dispatch; re-run until deterministic-clean, capped at 3 inner iterations -- if still failing after 3, stop and escalate to the user (an unfixable upstream lint/test failure must not spin the loop). (2) persona pass: parallel one-shot Agents `loop-spec:code-reviewer` + `loop-spec:security-reviewer` per file batch; prompts contain file contents/paths and the independence rule: NO prior-round findings, NO fix summaries, NO "check whether X was fixed". (3) `record-round`; blocking = any deterministic finding, any code-reviewer finding, security CRITICAL/HIGH; security MEDIUM/LOW advisory. (4) `systemic` check -> if systemic, stop and escalate listing the recurring category. (5) fix blocking findings, increment round, loop to (1) while rounds < `LOOP_SPEC_QUALITY_LOOP_MAX_ROUNDS` (default 3). (6) convergence -> `mark-clean` per file + summary table; budget exhausted -> escalate with remaining findings. Security findings are NEVER self-suppressed: present and wait.

agents/README.md: add security-reviewer row matching table format.

**Verify:** `bash tests/validate-agents.sh` exits 0 printing `All 13 agents validated.`; `grep -c "independence\|CRITICAL\|LOOP_SPEC_QUALITY_LOOP_MAX_ROUNDS\|systemic\|quality-loop-state.sh" skills/quality-loop/SKILL.md` >= 5.

---

### task-015: run-all.sh registration

**Goal:** Register the three new suites immediately after the line `run_suite "lib/detect-test-cmd"       "bash tests/lib/detect-test-cmd.test.sh"` in `tests/run-all.sh`:

```
run_suite "lib/workspace"          "bash tests/lib/workspace.test.sh"
run_suite "lib/fragility-scan"     "bash tests/lib/fragility-scan.test.sh"
run_suite "lib/quality-loop-state" "bash tests/lib/quality-loop-state.test.sh"
```

**Verify:** `bash tests/run-all.sh` exits 0.

---

### task-016: docs

**Goal:** README + CHANGELOG + adopting.

README: new "Workspaces (multi-repo)" section (detection rules incl. depth-1 and the pin file, in-place `feat/{slug}` branches with the dirty-repo abort, subagent-rung cap stated as a KNOWN LIMITATION of v1 (team/loop-fleet/Workflow rungs are single-repo only, deliberately deferred), per-repo PRs, workspace resume requires re-invoking from the workspace root); add `assess` and `quality-loop` to the skills list with one-line descriptions; update the existing "Multi-repo setups" worktree sentence to reference workspace mode. CHANGELOG `[Unreleased]`: Added entries for workspace mode (lib/workspace.sh, -C flags, schema v7, skill workspace paths), assess skill + lib/fragility-scan.sh, quality-loop skill + lib/quality-loop-state.sh + security-reviewer agent; note concept provenance as "adapted concepts, clean-room text". docs/adopting.md: short workspace adoption subsection.

**Verify:** grep counts per SPEC criteria; `bash tests/run-all.sh` still green.

## Acceptance

The SPEC "Success criteria" checklist is the acceptance gate. Final check: `bash tests/run-all.sh` exits 0, and `git status` shows only intended files.
