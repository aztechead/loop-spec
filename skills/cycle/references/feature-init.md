# Cycle Step 5 — new-feature initialization (reference)

Extracted verbatim from `skills/cycle/SKILL.md` Step 5; the SKILL stub points here.
Run once per NEW feature, before any phase. Apply as written.

Contents: resolve base and adopt (PR adoption, clean guard, base SHA) · choose the
execution root (worktree vs in-place, `EnterWorktree`) · finalize
(`lib/feature-bootstrap.sh` — environment prep, opt-in baseline, feature.json write).

If resuming: load feature.json into memory.

If new feature: resolve a clean, current base in the control checkout, then choose the
execution-root strategy from the deterministic harness probe. Claude Code keeps native
feature-worktree isolation. OpenCode and ADK have no session-root switch, so their additive
branch uses a clean in-place feature branch instead of pretending `git worktree add`
changed the running session's cwd.

A request that names an open PR (`#114`, a GitHub pull URL, or "this/the PR" on a
branch that already has one) is adopted: `lib/adopt-pr.sh resolve` is the probe.
The cycle checks out that head instead of minting `feat/{slug}`, so conflict
resolution and re-review land on the PR DELIVER will update. Workspace mode does
not adopt (it still mints `feat/{slug}` in every participating repo). Dirt on the
adopted branch is the work; dirt on any other branch still aborts.

## Resolve base and adopt

```bash
slug="$(bash "${CLAUDE_SKILL_DIR}/../../lib/git-ops.sh" slugify "$title")"
repo_root="$workspace_root"
harness_name="$(jq -r '.harness.name' <<<"$pf")"
feature_branch="feat/${slug}"
adopted_pr="false"

adopt_json="$(bash "${CLAUDE_SKILL_DIR}/../../lib/adopt-pr.sh" resolve \
  --repo "$repo_root" --request "$title")"
if [[ "${workspaceMode:-single}" == "single" ]] \
   && jq -e '.adopt == true' >/dev/null 2>&1 <<<"$adopt_json"; then
  adopted_pr="true"
  feature_branch="$(jq -r '.branch' <<<"$adopt_json")"
  base_branch="$(jq -r '.baseBranch' <<<"$adopt_json")"
  echo "loop-spec: adopting PR $(jq -r '.number' <<<"$adopt_json") on $feature_branch (base $base_branch)."
else
  base_branch="$(bash "${CLAUDE_SKILL_DIR}/../../lib/git-ops.sh" -C "$repo_root" detect-base-branch)"
fi

# Never build a feature from an unrelated dirty checkout. Dirt on the adopted PR
# branch is the requested work (merge conflicts already in progress).
bash "${CLAUDE_SKILL_DIR}/../../lib/runtime-ignore.sh" ensure "$repo_root"
current_branch="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD)"
if [[ "$adopted_pr" == "true" && "$current_branch" == "$feature_branch" ]]; then
  clean_state="clean"
else
  clean_state="$(bash "${CLAUDE_SKILL_DIR}/../../lib/git-ops.sh" -C "$repo_root" ensure-clean-or-stash)"
  [[ "$clean_state" == "clean" ]] || {
    echo "loop-spec: source checkout is dirty; commit or stash changes before starting autonomous delivery." >&2
    exit 1
  }
fi
if git -C "$repo_root" remote get-url origin >/dev/null 2>&1; then
  git -C "$repo_root" fetch --quiet origin "$base_branch" || {
    echo "loop-spec: failed to fetch origin/$base_branch; refusing a stale PR base." >&2
    exit 1
  }
  base_ref="origin/$base_branch"
  if [[ "$adopted_pr" == "true" ]]; then
    git -C "$repo_root" fetch --quiet origin "$feature_branch" || true
  fi
else
  base_ref="$base_branch"
fi
if [[ "$adopted_pr" == "true" ]]; then
  pr_head="$(git -C "$repo_root" rev-parse --verify "refs/heads/${feature_branch}^{commit}" 2>/dev/null \
    || git -C "$repo_root" rev-parse --verify "refs/remotes/origin/${feature_branch}^{commit}")" || {
    echo "loop-spec: cannot resolve adopted PR branch '$feature_branch'." >&2
    exit 1
  }
  base_sha="$(git -C "$repo_root" merge-base "$pr_head" "$base_ref")" || {
    echo "loop-spec: adopted PR branch '$feature_branch' does not share history with '$base_ref'." >&2
    exit 1
  }
else
  base_sha="$(git -C "$repo_root" rev-parse --verify "${base_ref}^{commit}")" || {
    echo "loop-spec: cannot resolve base branch '$base_ref'." >&2
    exit 1
  }
fi

active_autonomous=false
[[ "${autonomous:-0}" == "1" ]] && active_autonomous=true
bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-result.sh" begin \
  --result-root "$repo_root" --cycle-type full --title "$title" --slug "$slug" \
  --branch "$feature_branch" --base-branch "$base_branch" --phase startup \
  --autonomous "$active_autonomous"
```

## Choose the execution root

`EnterWorktree` is a harness tool call, not Bash — this section cannot move into a
script. Everything after it can, and does (next section).

```bash
worktree_state_path=""
worktrees_enabled="${LOOP_SPEC_WORKTREES:-1}"
case "$worktrees_enabled" in
  0|1) ;;
  *) echo "loop-spec: LOOP_SPEC_WORKTREES must be 0 or 1." >&2; exit 2 ;;
esac
if [[ "$adopted_pr" == "true" ]]; then
  case "$harness_name" in
    claude)
      if [[ "$worktrees_enabled" == "0" ]]; then
        git -C "$repo_root" checkout "$feature_branch" \
          || git -C "$repo_root" checkout -b "$feature_branch" --track "origin/$feature_branch"
        echo "loop-spec: LOOP_SPEC_WORKTREES=0; using the adopted PR branch in place."
      else
        worktree_abs="$(bash "${CLAUDE_SKILL_DIR}/../../lib/git-ops.sh" -C "$repo_root" \
          attach-feature-worktree "$slug" "$feature_branch")" || {
          echo "loop-spec: could not attach a worktree to $feature_branch (see the helper's diagnostic above)." >&2
          exit 1
        }
        worktree_state_path="$worktree_abs"
        EnterWorktree({ path: worktree_abs })
      fi
      ;;
    opencode|adk)
      git -C "$repo_root" checkout "$feature_branch" \
        || git -C "$repo_root" checkout -b "$feature_branch" --track "origin/$feature_branch"
      ;;
  esac
else
# Mint feat/{slug} when adopt-pr.sh did not select an existing PR.
case "$harness_name" in
  claude)
    if [[ "$worktrees_enabled" == "0" ]]; then
      git -C "$repo_root" checkout -b "feat/${slug}" "$base_sha"
      echo "loop-spec: LOOP_SPEC_WORKTREES=0; using the in-place feature branch with serial one-shot subagents."
    else
      worktree_abs="$(bash "${CLAUDE_SKILL_DIR}/../../lib/git-ops.sh" -C "$repo_root" create-feature-worktree "$slug" "$base_sha")" || {
        echo "loop-spec: could not create the feature worktree (see the helper's diagnostic above)." >&2
        exit 1
      }
      # Record the path the helper actually used. The default is
      # <repo>/.claude/worktrees/{slug}; lib/worktree-base.sh relocates it outside the
      # repository when that base cannot hold the checkout (a sandboxed harness denying
      # harness-config paths in-repo) or when LOOP_SPEC_WORKTREE_DIR is set.
      worktree_state_path="$worktree_abs"
      EnterWorktree({ path: worktree_abs })
    fi
    ;;
  opencode|adk)
    git -C "$repo_root" checkout -b "feat/${slug}" "$base_sha"
    # Session cwd stays at repo_root; every later relative path remains valid.
    ;;
esac
fi
```

## Finalize (deterministic — `lib/feature-bootstrap.sh`)

Everything from here on has no decision in it, so it runs as one script: environment
preparation (foreground watchdog; leaves HEAD and the worktree unchanged), the
python-runner test-command upgrade, the opt-in startup baseline
(`LOOP_SPEC_STARTUP_BASELINE=1` — default off; see the script header), the schema-7
`feature.json` skeleton write via `lib/feature-init.sh`, the cycle-result `begin`
marker, the autonomous/greenfield flags, and the staged-decisions migration. On a
preparation or baseline failure the script has already written a terminal cycle
result — surface its stderr and stop.

```bash
cmd_test="$(bash "${CLAUDE_SKILL_DIR}/../../lib/feature-bootstrap.sh" finalize \
  --repo-root "$repo_root" --execution-root "$(pwd -P)" \
  --slug "$slug" --title "$title" \
  --branch "$feature_branch" --base-branch "$base_branch" --base-sha "$base_sha" \
  --worktree "$worktree_state_path" --style "$execStyle" --profile "$cycle_profile" \
  --autonomous "${autonomous:-0}" --greenfield "${greenfield:-0}" \
  --prepare "$cmd_prepare" --test "$cmd_test" --lint "$cmd_lint" --typecheck "$cmd_typecheck")" || {
  echo "loop-spec: feature bootstrap failed; a terminal cycle result was written (see stderr above)." >&2
  exit 1
}
```

The script prints the (possibly upgraded) test command on stdout; keep the captured
`cmd_test` for the rest of the session.
