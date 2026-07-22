# VERIFY workspace-mode variants (reference)

Extracted verbatim from `skills/verify/SKILL.md`; the per-step stubs point here.
Single-repo mode is unchanged in the SKILL; apply these only when `feature.workspace` is non-null.

## Step 1 - Unresolved marker scan

**Workspace mode (additive):** loop over `feature.workspace.repos[]` and run the scan per repo. The abs repo path is `feature.workspace.root + "/" + repo.path`.

```bash
for repo_entry in $(echo "$workspace_repos_json" | jq -c '.[]'); do
  rname="$(echo "$repo_entry" | jq -r '.name')"
  rpath="$(echo "$repo_entry" | jq -r '.path')"
  rabs="${feature_workspace_root}/${rpath}"
  rbase_sha="$(echo "$repo_entry" | jq -r '.baseSha')"
  git -C "$rabs" diff --diff-filter=ACMR "${rbase_sha}..HEAD" --name-only \
    | grep -E '\.(py|ts|js|go|rs|java|rb|sh)$' \
    | while IFS= read -r changed; do
        [[ -n "$changed" ]] && grep -Hwn 'TBD\|FIXME\|XXX' "$rabs/$changed" 2>/dev/null || true
      done
done
```

(Shared fail rules and notes for this step live in the SKILL's Step 1 — they apply to both modes.)

## Step 4 - Spawn verifier-1

**Workspace mode (additive):** include the per-repo command map and per-repo absolute paths. The verifier runs each repo's commands with cwd = that repo's absolute path.

```
SendMessage({
  to: "verifier-1",
  message: "Apply skills/shared/verification-grounding.md, then run every acceptance criterion's verify command from PLAN.md. This is a workspace feature. For each repo inspect git -C <abs-path> diff <baseSha>..HEAD, re-read changed files and integration context, then run its commands with cwd set to that repo. For every Good Enough criterion write exactly one VERIFICATION.md row: '- criterion: <id> | implementation: <workspace-relative-file>:<line> - <what it proves> | integration: <workspace-relative-file>:<line> - <what it proves>'; only use 'integration: none - <concrete reason>' when no separate site exists. Gate ONLY on Good Enough. Write VERIFICATION.md to {workspace_root}/docs/loop-spec/features/{slug}/VERIFICATION.md. When complete, SendMessage({to: 'lead', message: 'VERIFIER DONE: <ALL_PASS|FAIL> <Test suite status: PASS|FAIL|N/A> <summary>'})."
  // also include: slug, spec_path, plan_path, workspace_root,
  //   and per-repo entries for each workspace.repos[]:
  //     repo name, abs path ({workspace_root}/{repo.path}), branch (repo.branch), baseSha (repo.baseSha),
  //     commands: test=<repo.commands.test>, lint=<repo.commands.lint>, typecheck=<repo.commands.typecheck>
})
```

verifier-1 works independently. Lead waits for its completion signal.
The lead then runs `lib/verification-grounding-lint.sh` with `--repo {workspace_root}`
and `--spec {spec_path}` so `GE-NNN` rows derive from SPEC order before accepting `ALL_PASS`.

## Step 6 - Spawn code-reviewer-1

**Workspace mode (additive):** include the per-repo absolute paths and each repo's baseSha. The code-reviewer reviews each repo's diff over its own baseSha (i.e., `git -C <abs repo> diff <repo.baseSha>..HEAD`).

```
SendMessage({
  to: "code-reviewer-1",
  message: "Review the feature branch diff for this workspace feature against SPEC.md and PLAN.md acceptance criteria. For each repo listed, review its diff over its baseSha using git -C <abs-repo-path> diff <baseSha>..HEAD. Check each SPEC '## Boundaries (what NOT to do)' anti-goal against each repo's diff; flag violations Critical. Rank findings by the fixed rule: Critical + Important block; Minor is recorded but never blocks. When complete, SendMessage({to: 'lead', message: 'CODE-REVIEWER DONE: <PASS|PASS_WITH_MINOR|BLOCK> <summary of findings>'})."
  // also include: slug, spec_path, plan_path, workspace_root,
  //   and per-repo entries: name, abs path, branch, baseSha
})
```

code-reviewer-1 works independently in parallel with verifier-1. Lead waits for both.

## Step 9 - map-codebase refresh

**Workspace mode (additive):** do not run a separate Graphify workflow in VERIFY. The invoked map-codebase skill detects workspace mode and applies `skills/shared/graphify-lifecycle.md` to every selected participating repository before committing each repository's refreshed shared graph outputs.

Do NOT resolve `WORKTREE_ABS` via `git rev-parse --show-toplevel` in workspace mode; the workspace root may not be a git repo and that command would abort. Instead, pass the per-repo absolute paths to the map-codebase skill:

```bash
# Build repo list for map-codebase workspace dispatch
repo_list=""
for repo_entry in $(echo "$workspace_repos_json" | jq -c '.[]'); do
  rname="$(echo "$repo_entry" | jq -r '.name')"
  rpath="${feature_workspace_root}/$(echo "$repo_entry" | jq -r '.path')"
  repo_list="${repo_list}${rname}=${rpath}, "
done
repo_list="${repo_list%, }"
# Pass repo_list to map-codebase; mappers cover each repo with per-repo sections.
Skill(loop-spec:map-codebase) with mode: "incremental", workspace_repos: repo_list
```

## Step 10 - Commit VERIFICATION.md

**Workspace mode (additive):** the workspace root is orchestration state, not a delivery
target. Leave VERIFICATION.md local there even when the parent happens to be a git repo;
never commit to an unbranched parent. Issue a checkpoint tag per participating repo using
`lib/checkpoint.sh -C <abs repo>`.

```bash
echo "workspace root is not a delivery target; leaving VERIFICATION.md as local orchestration evidence"

# Checkpoint tag per repo.
for repo_entry in $(echo "$workspace_repos_json" | jq -c '.[]'); do
  rpath="${feature_workspace_root}/$(echo "$repo_entry" | jq -r '.path')"
  bash "${CLAUDE_SKILL_DIR}/../../lib/checkpoint.sh" -C "$rpath" tag post-verify
done
```

Workspace VERIFY stops after committing evidence and checkpoint tags. DELIVER later
counts each repo's commits, skips zero-commit repos, persists every per-repo PR result
under ignored `delivery.json.targets[]`, and blocks readiness on each changed repo's
required checks.
