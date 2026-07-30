# Cycle workspace-mode procedures (reference)

Extracted verbatim from `skills/cycle/SKILL.md`; the SKILL stubs point here. Apply as written.

## Step 5 variant -- workspace state init

#### Workspace mode Step 5 variant

In workspace mode (`workspaceMode == "workspace"`), do NOT call `create-feature-worktree` and do NOT call `EnterWorktree`. All work stays at the workspace root. Replace the single-repo branch setup above with the following two-phase procedure.

**Phase 1 -- pre-flight every repository (ALL repos, before ANY branch is created):**

```bash
dirty_repos=()
for repo_entry in $(echo "$workspace_repos_json" | jq -c '.[]'); do
  rname="$(echo "$repo_entry" | jq -r '.name')"
  rpath="${workspace_root}/$(echo "$repo_entry" | jq -r '.path')"
  bash "${CLAUDE_SKILL_DIR}/../../lib/runtime-ignore.sh" ensure "$rpath"
  clean_state="$(bash "${CLAUDE_SKILL_DIR}/../../lib/git-ops.sh" -C "$rpath" ensure-clean-or-stash 2>/dev/null)"
  if [[ "$clean_state" != "clean" ]]; then
    dirty_repos+=("$rname ($rpath)")
  fi
done
if [[ ${#dirty_repos[@]} -gt 0 ]]; then
  echo "loop-spec: cannot create feature branches -- the following repos have uncommitted changes:"
  for r in "${dirty_repos[@]}"; do echo "  $r"; done
  echo "Please commit or stash changes in each repo above, then re-invoke cycle."
  exit 1
fi

# Resolve every base and reject branch collisions before switching any repo.
declare -A repo_base_sha repo_base_branch
for repo_entry in $(echo "$workspace_repos_json" | jq -c '.[]'); do
  rname="$(echo "$repo_entry" | jq -r '.name')"
  rpath="${workspace_root}/$(echo "$repo_entry" | jq -r '.path')"
  base_branch_r="$(bash "${CLAUDE_SKILL_DIR}/../../lib/git-ops.sh" -C "$rpath" detect-base-branch)"
  if git -C "$rpath" remote get-url origin >/dev/null 2>&1; then
    git -C "$rpath" fetch --quiet origin "$base_branch_r" || {
      echo "loop-spec: failed to fetch ${rname} origin/${base_branch_r}; no feature branches were created." >&2
      exit 1
    }
    base_ref_r="origin/$base_branch_r"
  else
    base_ref_r="$base_branch_r"
  fi
  base_sha_r="$(git -C "$rpath" rev-parse --verify "${base_ref_r}^{commit}")" || {
    echo "loop-spec: cannot resolve ${rname} base '${base_ref_r}'; no feature branches were created." >&2
    exit 1
  }
  if git -C "$rpath" show-ref --verify --quiet "refs/heads/feat/${slug}"; then
    echo "loop-spec: ${rname} already has branch feat/${slug}; no feature branches were created." >&2
    exit 1
  fi
  repo_base_sha["$rname"]="$base_sha_r"
  repo_base_branch["$rname"]="$base_branch_r"
done
```

If any repo is dirty, unfetchable, missing its base, or already has the feature branch,
abort before switching any repository.

**Phase 2 -- per-repo branch creation (only when all repos are clean):**

```bash
for repo_entry in $(echo "$workspace_repos_json" | jq -c '.[]'); do
  rname="$(echo "$repo_entry" | jq -r '.name')"
  rpath="${workspace_root}/$(echo "$repo_entry" | jq -r '.path')"
  git -C "$rpath" checkout -b "feat/${slug}" "${repo_base_sha[$rname]}"
done
```

Prepare and baseline every repository now, while each feature branch `HEAD` is still its
exact untouched base and before the workspace state directories exist. Setup and
validation must leave each repository clean. A failure aborts initialization; never
record setup failure as a known test failure.

```bash
declare -A repo_prepare_key repo_baseline_json
for repo_entry in $(echo "$workspace_repos_json" | jq -c '.[]'); do
  rname="$(echo "$repo_entry" | jq -r '.name')"
  rpath="${workspace_root}/$(echo "$repo_entry" | jq -r '.path')"
  prepare_rc=0
  prepare_json="$(bash "${CLAUDE_SKILL_DIR}/../../lib/prepare-environment.sh" run \
    --root "$rpath" --command "${repo_cmds_prepare[$rname]:-}")" || prepare_rc=$?
  [[ "$prepare_rc" -eq 0 ]] || {
    echo "loop-spec: environment preparation failed for $rname (exit $prepare_rc)." >&2
    exit 1
  }
  repo_cmds_prepare["$rname"]="$(jq -r '.command // ""' <<<"$prepare_json")"
  repo_prepare_key["$rname"]="$(jq -r '.key // ""' <<<"$prepare_json")"
  baseline_path="$(git -C "$rpath" rev-parse --git-path "loop-spec/validation/${slug}/base")"
  [[ "$baseline_path" == /* ]] || baseline_path="$rpath/$baseline_path"
  mkdir -p "$baseline_path"
  baseline_rc=0
  repo_baseline_json["$rname"]="$(bash "${CLAUDE_SKILL_DIR}/../../lib/verification-baseline.sh" capture \
    --root "$rpath" --base-sha "${repo_base_sha[$rname]}" \
    --prepare-key "${repo_prepare_key[$rname]}" --log-dir "$baseline_path" \
    --test "${repo_cmds_test[$rname]:-}" --lint "${repo_cmds_lint[$rname]:-}" \
    --typecheck "${repo_cmds_typecheck[$rname]:-}")" || baseline_rc=$?
  [[ "$baseline_rc" -eq 0 ]] || {
    echo "loop-spec: exact-base validation baseline failed for $rname (exit $baseline_rc)." >&2
    exit 1
  }
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
repos_json_array='[]'
while IFS= read -r repo_entry; do
  rname="$(jq -r '.name' <<<"$repo_entry")"
  entry="$(jq -cn --arg name "$rname" --arg path "$(jq -r '.path' <<<"$repo_entry")" \
    --arg branch "feat/${slug}" --arg sha "${repo_base_sha[$rname]}" \
    --arg base "${repo_base_branch[$rname]}" --arg prepare "${repo_cmds_prepare[$rname]:-}" \
    --arg test "${repo_cmds_test[$rname]:-}" --arg lint "${repo_cmds_lint[$rname]:-}" \
    --arg typecheck "${repo_cmds_typecheck[$rname]:-}" \
    --argjson baseline "${repo_baseline_json[$rname]}" \
    '{name:$name,path:$path,branch:$branch,baseSha:$sha,baseBranch:$base,
      commands:{prepare:$prepare,test:$test,lint:$lint,typecheck:$typecheck},
      verificationBaseline:$baseline}')"
  repos_json_array="$(jq -c --argjson entry "$entry" '. + [$entry]' <<<"$repos_json_array")"
done < <(jq -c '.[]' <<<"$workspace_repos_json")

# Same single source of truth (lib/feature-init.sh), workspace mode: top-level
# branch/baseSha/baseBranch/worktreePath are null, top-level commands are empty, and the
# workspace block carries the per-repo array built above. Models + the fixed iterate block are
# identical to single-repo mode -- never re-hand-build them here.
workspace_feature_json=$(bash "${CLAUDE_SKILL_DIR}/../../lib/feature-init.sh" skeleton --mode workspace \
  --slug "$slug" --now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --style "$execStyle" --title "$title" \
  --ws-root "$workspace_root" --repos "$repos_json_array")

bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" \
  "${workspace_root}/.loop-spec/features/${slug}" "$workspace_feature_json"
```

Schema notes for workspace feature.json:
- `schemaVersion: 7`; top-level `branch`, `baseSha`, `baseBranch`, `worktreePath` are `null`; top-level `commands` holds empty strings.
- `workspace.root` is the absolute workspace parent path.
- `workspace.repos[]` carries `name`, `path` (relative to workspace root), `branch` (`feat/{slug}`), `baseSha`, `baseBranch`, `commands` (including prepare), and its exact-base `verificationBaseline` -- matching the schema in `skills/shared/feature-state-schema.md`.
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
  questions: [{
    question: "Workspace repos: {list each repo name and relative path}. A feat/{slug} branch will be created IN PLACE in each participating repo (no worktree; the checkout switches branches). Proceed with all repos, or customize?",
    header: "Repos",
    options: [
      { label: "All repos", description: "Create feat/{slug} in every discovered repo" },
      { label: "Customize", description: "Name the participating repos; the rest are left untouched" }
    ],
    multiSelect: false
  }]
})
```

If "Customize": ask the user to list repo names (comma-separated); filter `workspace_repos_json` to only those named.

Non-interactive (`LOOP_SPEC_NON_INTERACTIVE=1`): read `LOOP_SPEC_ANSWER_REPOS`
(comma-separated repo names, default = all). Trim surrounding whitespace, reject any
name not present in the discovered set, reject an empty resulting selection, preserve
discovery order, and skip AskUserQuestion. Do not silently drop misspelled names.

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
