# Cycle workspace-mode procedures (reference)

Extracted verbatim from `skills/cycle/SKILL.md`; the SKILL stubs point here. Apply as written.

## Step 5 variant -- workspace state init

#### Workspace mode Step 5 variant

In workspace mode (`workspaceMode == "workspace"`), do NOT call `create-feature-worktree` and do NOT call `EnterWorktree`. All work stays at the workspace root. Replace the single-repo branch setup above with the following two-phase procedure.

**Phase 1 -- pre-flight cleanliness check (ALL repos, before ANY branch is created):**

```bash
dirty_repos=()
for repo_entry in $(echo "$workspace_repos_json" | jq -c '.[]'); do
  rname="$(echo "$repo_entry" | jq -r '.name')"
  rpath="${workspace_root}/$(echo "$repo_entry" | jq -r '.path')"
  if ! bash "${CLAUDE_SKILL_DIR}/../../lib/git-ops.sh" -C "$rpath" ensure-clean-or-stash 2>/dev/null; then
    dirty_repos+=("$rname ($rpath)")
  fi
done
if [[ ${#dirty_repos[@]} -gt 0 ]]; then
  echo "loop-spec: cannot create feature branches -- the following repos have uncommitted changes:"
  for r in "${dirty_repos[@]}"; do echo "  $r"; done
  echo "Please commit or stash changes in each repo above, then re-invoke cycle."
  exit 1
fi
```

If any repo is dirty, abort with the message above. No branches are created.

**Phase 2 -- per-repo branch creation (only when all repos are clean):**

```bash
declare -A repo_base_sha repo_base_branch
for repo_entry in $(echo "$workspace_repos_json" | jq -c '.[]'); do
  rname="$(echo "$repo_entry" | jq -r '.name')"
  rpath="${workspace_root}/$(echo "$repo_entry" | jq -r '.path')"
  base_sha_r="$(git -C "$rpath" rev-parse HEAD)"
  base_branch_r="$(bash "${CLAUDE_SKILL_DIR}/../../lib/git-ops.sh" -C "$rpath" detect-base-branch)"
  git -C "$rpath" checkout -b "feat/${slug}" "$base_sha_r"
  repo_base_sha["$rname"]="$base_sha_r"
  repo_base_branch["$rname"]="$base_branch_r"
done
```

**State dirs** are created at the workspace root:

```bash
mkdir -p "${workspace_root}/.loop-spec/features/${slug}" \
         "${workspace_root}/.loop-spec/codebase" \
         "${workspace_root}/docs/loop-spec/features/${slug}"
```

If Step 3 resolved a spec-file invocation (`spec_draft_abs` is set), copy the draft in now:

```bash
cp "$spec_draft_abs" "${workspace_root}/.loop-spec/features/${slug}/spec-draft.md"
```

**feature.json construction for workspace mode:**

Build the `workspace.repos` array from the per-repo data collected above, then write feature.json:

```bash
repos_json_array="$(echo "$workspace_repos_json" | jq -c \
  --argjson base_shas "$(for rname in "${!repo_base_sha[@]}"; do
      echo "{\"name\":\"$rname\",\"sha\":\"${repo_base_sha[$rname]}\"}"; done | jq -s .)" \
  --argjson base_branches "$(for rname in "${!repo_base_branch[@]}"; do
      echo "{\"name\":\"$rname\",\"branch\":\"${repo_base_branch[$rname]}\"}"; done | jq -s .)" \
  '[.[] | . as $r |
    ($base_shas[] | select(.name == $r.name) | .sha) as $sha |
    ($base_branches[] | select(.name == $r.name) | .branch) as $bb |
    {
      name: $r.name,
      path: $r.path,
      branch: ("feat/" + env.slug),
      baseSha: $sha,
      baseBranch: $bb,
      commands: {
        test: (env["REPO_TEST_" + ($r.name | gsub("[^A-Za-z0-9]"; "_"))] // ""),
        lint: (env["REPO_LINT_" + ($r.name | gsub("[^A-Za-z0-9]"; "_"))] // ""),
        typecheck: (env["REPO_TYPECHECK_" + ($r.name | gsub("[^A-Za-z0-9]"; "_"))] // "")
      }
    }
  ]')"
# (In practice, per-repo commands detected in Step 4 are substituted in directly
#  rather than via env vars; the structure above is illustrative of the shape.)

# Same single source of truth (lib/feature-init.sh), workspace mode: top-level
# branch/baseSha/baseBranch/worktreePath are null, top-level commands are empty, and the
# workspace block carries the per-repo array built above. Models + tier blocks are
# identical to single-repo mode -- never re-hand-build them here.
workspace_feature_json=$(bash "${CLAUDE_SKILL_DIR}/../../lib/feature-init.sh" skeleton --mode workspace \
  --slug "$slug" --now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --tier "$tier" --style "$execStyle" --title "$title" \
  --ws-root "$workspace_root" --repos "$repos_json_array")

bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" \
  "${workspace_root}/.loop-spec/features/${slug}" "$workspace_feature_json"
```

Schema notes for workspace feature.json:
- `schemaVersion: 7`; top-level `branch`, `baseSha`, `baseBranch`, `worktreePath` are `null`; top-level `commands` holds empty strings.
- `workspace.root` is the absolute workspace parent path.
- `workspace.repos[]` carries `name`, `path` (relative to workspace root), `branch` (`feat/{slug}`), `baseSha`, `baseBranch`, and `commands` (per-repo detected commands) -- matching the schema in `skills/shared/feature-state-schema.md`.
```

No initial commit of `feature.json` is forced here: `create-feature-worktree` already pointed `feat/{slug}` at a real commit (`base_sha`), and the first state commit lands at the first phase transition (Step 6). Phase artifacts under `docs/loop-spec/features/{slug}/` are committed by each phase as it writes them (SPEC, PLAN, VERIFY).

> **feature.json is the committed resume contract.** Unlike the rest of `.loop-spec/`
> runtime state, `feature.json` is tracked in git (see `.gitignore`: the feature dir's
> contents are ignored EXCEPT `feature.json`). The cycle commits the updated state on every
> phase transition (Step 6), so a `git clone` or a branch hand-off to another machine
> carries the in-flight phase state and Step 1 resume detection can pick it up. The volatile
> siblings (`feature.json.bak`, `gate-logs/`, transcripts) stay gitignored as per-machine
> churn. In workspace mode, where the root may not be a git repo, the state commit is a
> guarded no-op and resume remains local to that machine.

## Step 0 detail -- workspace announcement, confirmation, runtime.json merge

Announcement (print to user):
```
workspace mode: {N} repos ({name1}, {name2}, ...}
  State and artifacts will be rooted at: {workspace_root}
Advisory: if {workspace_root} is or becomes a git repo, add .loop-spec/ to its .gitignore.
```

Confirmation (interactive):
```
AskUserQuestion({
  question: "Workspace repos: {list each repo name and relative path}. A feat/{slug} branch will be created IN PLACE in each participating repo (no worktree; the checkout switches branches). Proceed with all repos, or customize?",
  options: ["All repos", "Customize"]
})
```

If "Customize": ask the user to list repo names (comma-separated); filter `workspace_repos_json` to only those named.

Non-interactive (`LOOP_SPEC_NON_INTERACTIVE=1`): read `LOOP_SPEC_ANSWER_REPOS` (comma-separated repo names, default = all). Skip AskUserQuestion.

After confirmation, `workspace_repos_json` holds only the participating repos.

Merge workspace fields into `.loop-spec/runtime.json` (same python3 merge-write pattern as the workflow probe):

```bash
mkdir -p .loop-spec
python3 -c "
import json, sys, os
path = '.loop-spec/runtime.json'
data = {}
if os.path.exists(path):
    try:
        data = json.load(open(path))
    except Exception:
        data = {}
data['workspaceMode']  = sys.argv[1]
data['workspaceRoot']  = sys.argv[2]
data['workspaceRepos'] = json.loads(sys.argv[3])
json.dump(data, open(path, 'w'))
" "$workspace_mode" "$workspace_root" "$workspace_repos_json"
```
