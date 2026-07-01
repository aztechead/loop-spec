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
    | xargs grep -wn 'TBD\|FIXME\|XXX' 2>/dev/null || true
done
```

(Shared fail rules and notes for this step live in the SKILL's Step 1 — they apply to both modes.)

## Step 4 - Spawn verifier-1

**Workspace mode (additive):** include the per-repo command map and per-repo absolute paths. The verifier runs each repo's commands with cwd = that repo's absolute path.

```
SendMessage({
  to: "verifier-1",
  body: "Run every acceptance criterion's verify command from PLAN.md. This is a workspace feature. For each repo listed below, run its own commands with cwd set to that repo's absolute path. Gate ONLY on the SPEC 'Good Enough' success criteria. Write VERIFICATION.md to {workspace_root}/docs/loop-spec/features/{slug}/VERIFICATION.md. When complete, SendMessage({to: 'lead', body: 'VERIFIER DONE: <ALL_PASS|FAIL> <Test suite status: PASS|FAIL|N/A> <summary>'})."
  // also include: slug, spec_path, plan_path, workspace_root,
  //   and per-repo entries for each workspace.repos[]:
  //     repo name, abs path ({workspace_root}/{repo.path}), branch (repo.branch), baseSha (repo.baseSha),
  //     commands: test=<repo.commands.test>, lint=<repo.commands.lint>, typecheck=<repo.commands.typecheck>
})
```

verifier-1 works independently. Lead waits for its completion signal.

## Step 6 - Spawn code-reviewer-1

**Workspace mode (additive):** include the per-repo absolute paths and each repo's baseSha. The code-reviewer reviews each repo's diff over its own baseSha (i.e., `git -C <abs repo> diff <repo.baseSha>..HEAD`).

```
SendMessage({
  to: "code-reviewer-1",
  body: "Review the feature branch diff for this workspace feature against SPEC.md and PLAN.md acceptance criteria. For each repo listed, review its diff over its baseSha using git -C <abs-repo-path> diff <baseSha>..HEAD. Check each SPEC '## Boundaries (what NOT to do)' anti-goal against each repo's diff; flag violations Critical. Rank findings by the fixed rule: Critical + Important block; Minor is recorded but never blocks. When complete, SendMessage({to: 'lead', body: 'CODE-REVIEWER DONE: <PASS|PASS_WITH_MINOR|BLOCK> <summary of findings>'})."
  // also include: slug, spec_path, plan_path, workspace_root,
  //   and per-repo entries: name, abs path, branch, baseSha
})
```

code-reviewer-1 works independently in parallel with verifier-1. Lead waits for both.

## Step 9 - map-codebase refresh

**Workspace mode (additive):** skip the graphify step entirely (graphify operates on a single repo root; it has no multi-repo mode) and log one line:

```
workspace mode: skipping graphify update (single-repo only)
```

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

## Step 10 - Branch finish

**Workspace mode (additive):** loop over `feature.workspace.repos[]`. For each repo, count commits over its baseSha. Repos with commits get a push and a PR; repos with zero commits are skipped and their feature branch is deleted. Push/PR failure for one repo degrades to printing the manual commands and continues with the remaining repos -- never aborts the loop.

```bash
declare -A repo_pr_urls repo_skip_reasons repo_commit_counts

for repo_entry in $(echo "$workspace_repos_json" | jq -c '.[]'); do
  rname="$(echo "$repo_entry" | jq -r '.name')"
  rpath="${feature_workspace_root}/$(echo "$repo_entry" | jq -r '.path')"
  rbase_sha="$(echo "$repo_entry" | jq -r '.baseSha')"
  rbase_branch="$(echo "$repo_entry" | jq -r '.baseBranch')"
  rbranch="$(echo "$repo_entry" | jq -r '.branch')"

  commit_count=$(git -C "$rpath" rev-list --count "${rbase_sha}..HEAD" 2>/dev/null || echo 0)
  repo_commit_counts["$rname"]="$commit_count"

  if [[ "$commit_count" -eq 0 ]]; then
    # Zero-commit repo: skip push/PR, delete feature branch.
    git -C "$rpath" checkout "$rbase_branch" 2>/dev/null || true
    git -C "$rpath" branch -d "$rbranch" 2>/dev/null || true
    repo_skip_reasons["$rname"]="no commits (branch deleted)"
    continue
  fi

  # Push the feature branch from this repo.
  if ! git -C "$rpath" push -u origin "$rbranch" 2>/dev/null; then
    repo_skip_reasons["$rname"]="push failed -- run manually: git -C ${rpath} push -u origin ${rbranch}"
    continue
  fi

  # Open PR for this repo (cwd = repo path).
  spec_summary=$(awk '/^## Problem/,/^## (Constraints|User-facing)/' \
    "${feature_workspace_root}/docs/loop-spec/features/${slug}/SPEC.md" | head -100)
  verify_table=$(awk '/^## Acceptance criteria/,/^## Verify command outputs/' \
    "${feature_workspace_root}/docs/loop-spec/features/${slug}/VERIFICATION.md")
  pr_body="$(printf '## Spec summary\n\n%s\n\n## Verification\n\n%s\n' "$spec_summary" "$verify_table")"

  pr_url=""
  if ! pr_url=$(cd "$rpath" && gh pr create \
      --base "$rbase_branch" \
      --head "$rbranch" \
      --title "feat: ${slug} (${rname})" \
      --body "$pr_body" 2>/dev/null); then
    repo_skip_reasons["$rname"]="PR creation failed -- run manually: cd ${rpath} && gh pr create --base ${rbase_branch} --head ${rbranch}"
    continue
  fi

  repo_pr_urls["$rname"]="$pr_url"
done
```

## Step 11 - Commit VERIFICATION.md

**Workspace mode (additive):** commit VERIFICATION.md only when the workspace root is itself a git repo. Issue a checkpoint tag per repo using `lib/checkpoint.sh -C <abs repo>`.

```bash
# Commit VERIFICATION.md at workspace root if it is a git repo.
if git -C "$feature_workspace_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "$feature_workspace_root" add \
    "docs/loop-spec/features/${slug}/VERIFICATION.md"
  git -C "$feature_workspace_root" commit \
    -m "verify: NO_JIRA ${slug} (workspace)"
else
  echo "workspace root not a git repo; leaving VERIFICATION.md uncommitted"
fi

# Checkpoint tag per repo.
for repo_entry in $(echo "$workspace_repos_json" | jq -c '.[]'); do
  rpath="${feature_workspace_root}/$(echo "$repo_entry" | jq -r '.path')"
  bash "${CLAUDE_SKILL_DIR}/../../lib/checkpoint.sh" -C "$rpath" tag post-verify
done
```

## Step 14 - Summary

**Workspace mode (additive):** print a per-repo summary table instead of a single PR URL.

```
Workspace verify summary for {slug}:

| Repo     | Commits | Result                   |
|----------|---------|--------------------------|
| frontend |       3 | PR: https://github.com/... |
| backend  |       0 | skipped (no commits; branch deleted) |
| db       |       1 | PR creation failed -- run manually: ... |

Token usage estimate: {N}k
Total elapsed time: {T}
```

Columns:
- Repo: the `workspace.repos[].name`
- Commits: count of commits over `repo.baseSha` on `feat/{slug}`
- Result: PR URL if created; skip reason or manual command if not
