# EXECUTE workspace-mode gates (reference)

Read when `feature.workspace` is non-null. Two gates from the EXECUTE skill body run
verbatim here: the Step 1 branch assertion and the Step 3 rung gate. Everything else
about workspace execution (wave construction, prompts, completion verification) is
`skills/shared/execute-subagent.md` "Workspace mode".

## Step 1 — branch check (every participating repo on `feat/{slug}`)

Assert before any other work; if any repo fails, abort with the message below and do
not proceed:

```bash
workspace_root="$(jq -r '.workspace.root' .loop-spec/features/{slug}/feature.json)"
feature_slug="{feature.json.slug}"
jq -c '.workspace.repos[]' .loop-spec/features/{slug}/feature.json | while IFS= read -r repo_entry; do
  rname="$(echo "$repo_entry" | jq -r '.name')"
  rpath="$(echo "$repo_entry" | jq -r '.path')"
  abs_repo="${workspace_root}/${rpath}"
  current="$(git -C "$abs_repo" branch --show-current)"
  if [[ "$current" != "feat/${feature_slug}" ]]; then
    echo "ERROR: workspace repo '$rname' ($abs_repo): expected branch feat/${feature_slug} but current branch is '$current'." >&2
    echo "Ensure every participating repo is on feat/${feature_slug} before running EXECUTE." >&2
    exit 2
  fi
done
```

## Step 3 — rung gate (evaluated BEFORE `featureWorktreeRoot` is resolved)

Workspace mode hard-pins the rung to `subagent` and skips the Step 3a/3b ladder
entirely: the workspace root may not be a git repo, and `git rev-parse
--show-toplevel` at a non-repo root would abort under set -e semantics.

```bash
workspace_block="$(jq -r '.workspace // "null"' .loop-spec/features/{slug}/feature.json)"
if [[ "$workspace_block" != "null" ]]; then
  # Workspace mode: rung is always subagent. No ladder evaluation.
  if [[ "${LOOP_SPEC_EXECUTE_LOOPS:-}" == "1" ]]; then
    echo "[EXECUTE] ERROR: LOOP_SPEC_EXECUTE_LOOPS=1 is not supported in workspace mode." >&2
    echo "  The loop-fleet rung is single-repo only. Unset LOOP_SPEC_EXECUTE_LOOPS or" >&2
    echo "  run EXECUTE without it. Aborting -- resolve this before proceeding." >&2
    exit 2
  fi
  repo_count="$(echo "$workspace_block" | jq '.repos | length')"
  rung="subagent"
  echo "[EXECUTE] workspace mode -> rung capped at subagent (repos: ${repo_count})"
  skillDir="${CLAUDE_SKILL_DIR}"
  # Skip to subagent dispatch; featureWorktreeRoot is not set (not needed in workspace mode).
  # Follow skills/shared/execute-subagent.md "Workspace mode" section.
else
  # --- single-repo path below ---
  featureWorktreeRoot=$(git rev-parse --show-toplevel)
  skillDir="${CLAUDE_SKILL_DIR}"
  # One resolution for every task worktree of this feature, passed to whichever rung
  # runs (Workflow DAG arg, team-prompt {worktreeBase}, subagent worktree_path).
  taskWorktreeBase="$(bash "${CLAUDE_SKILL_DIR}/../../lib/worktree-base.sh" \
    resolve "$featureWorktreeRoot" task "{slug}" | jq -r '.path')"
fi
```

In workspace mode `featureWorktreeRoot` is NOT set; the subagent path uses per-repo
absolute paths from `feature.workspace.repos[]` instead.
