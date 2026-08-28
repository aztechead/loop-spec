# Cycle Step 5 — new-feature initialization (reference)

Extracted verbatim from `skills/cycle/SKILL.md` Step 5; the SKILL stub points here.
Run once per NEW feature, before any phase. Apply as written.

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

# Prepare the untouched exact-base checkout before any loop-spec files or feature edits
# exist. Repository-wide test/lint/typecheck runs at the END of the cycle (VERIFY Step
# 1.75); startup no longer pays for a full suite on a fresh checkout before a single line
# of the feature exists. Setup must leave both HEAD and the worktree unchanged.
# prepare-environment.sh owns a foreground process watchdog. Never background the command,
# never poll a log with sleep/cat, and never use ps or /proc to infer liveness.
execution_root="$(pwd -P)"
prepare_rc=0
prepare_json="$(bash "${CLAUDE_SKILL_DIR}/../../lib/prepare-environment.sh" run \
  --root "$execution_root" --command "$cmd_prepare")" || prepare_rc=$?
[[ "$prepare_rc" -eq 0 ]] || {
  prepare_reason="$(jq -r --arg fallback "$prepare_rc" \
    '(.failureKind // .status // "unknown") + " (exit " +
     ((.exitCode // ($fallback | tonumber)) | tostring) + ")"' \
    <<<"${prepare_json:-{}}" 2>/dev/null \
    || printf 'environment preparation failed (exit %s)' "$prepare_rc")"
  bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-result.sh" write-terminal \
    --result-root "$repo_root" --cycle-type full --status failed \
    --outcome infrastructure-failed --title "$title" --slug "$slug" \
    --branch "$feature_branch" --base-branch "$base_branch" --phase-reached startup \
    --reason "$prepare_reason" --summary "Environment preparation failed: $prepare_reason" \
    --converged false --verification-status not-run --autonomous "$active_autonomous"
  echo "loop-spec: environment preparation failed before feature initialization: $prepare_reason." >&2
  exit 1
}
prepare_key="$(jq -r '.key // ""' <<<"$prepare_json")"
cmd_prepare="$(jq -r '.command // ""' <<<"$prepare_json")"
# Preparation may create an isolated Python runner. Upgrade the generic auto-detected
# python command even when it is one conjunct in a polyglot join; never overwrite a
# user-pinned LOOP_SPEC_CMD_TEST value.
if [[ "$cmd_test" == *"python -m pytest"* && -z "${LOOP_SPEC_CMD_TEST+x}" ]]; then
  cmd_test="$(bash "${CLAUDE_SKILL_DIR}/../../lib/detect-test-cmd.sh" "$execution_root")"
fi

# Opt-in startup baseline (LOOP_SPEC_STARTUP_BASELINE=1). Default off: no capture runs,
# `verificationBaseline` stays null, and VERIFY's end-of-cycle comparison treats every
# failure it observes as blocking. Turn it on only where the base commit is already red
# and the known-failure oracle is what stops VERIFY from chasing pre-existing failures.
# The capture owns a foreground watchdog and must leave HEAD and the worktree unchanged.
baseline_json=null
if [[ "${LOOP_SPEC_STARTUP_BASELINE:-0}" == "1" && "${greenfield:-0}" != "1" ]]; then
  baseline_git_path="$(git -C "$execution_root" rev-parse --git-path "loop-spec/validation/${slug}/base")"
  [[ "$baseline_git_path" == /* ]] || baseline_git_path="$execution_root/$baseline_git_path"
  mkdir -p "$baseline_git_path"
  baseline_rc=0
  baseline_json="$(bash "${CLAUDE_SKILL_DIR}/../../lib/verification-baseline.sh" capture \
    --root "$execution_root" --base-sha "$base_sha" --prepare-key "$prepare_key" \
    --log-dir "$baseline_git_path" --test "$cmd_test" --lint "$cmd_lint" \
    --typecheck "$cmd_typecheck")" || baseline_rc=$?
  [[ "$baseline_rc" -eq 0 ]] || {
    baseline_reason="$(jq -r '.reason // "exact-base validation baseline could not be captured"' \
      <<<"${baseline_json:-{}}" 2>/dev/null || printf 'exact-base validation baseline failed')"
    bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-result.sh" write-terminal \
      --result-root "$repo_root" --cycle-type full --status failed \
      --outcome infrastructure-failed --title "$title" --slug "$slug" \
      --branch "$feature_branch" --base-branch "$base_branch" --phase-reached startup \
      --reason "$baseline_reason" --summary "Validation baseline failed: $baseline_reason" \
      --converged false --verification-status failed --verification-command "$cmd_test" \
      --autonomous "$active_autonomous"
    echo "loop-spec: exact-base validation baseline could not be captured (exit $baseline_rc): $baseline_reason." >&2
    exit 1
  }
fi

# Create dirs and write feature.json inside the now-active execution root.
mkdir -p ".loop-spec/features/${slug}" .loop-spec/codebase "docs/loop-spec/features/${slug}"
# Startup probes ran in the control checkout. Copy their local runtime cache into
# a Claude feature worktree; in-place harnesses already point at the same file.
if [[ -f "$repo_root/.loop-spec/runtime.json" && "$(pwd -P)" != "$(cd "$repo_root" && pwd -P)" ]]; then
  cp "$repo_root/.loop-spec/runtime.json" .loop-spec/runtime.json
fi

# Build the full schema-7 skeleton from the single source of truth (lib/feature-init.sh).
# Model routes, configured phase defaults, the fixed iterate block, and the artifact scaffold all
# live in that one script -- never hand-build feature.json inline (that drift is what
# previously dropped iterateJudge from the normalized models map). Every phase skill reads
# the activated selector from feature.models.{role} ({role} = its own role name): an
# alias is explicit, while `inherit`
# deliberately omits the Agent model key and uses the session model.
feature_json=$(bash "${CLAUDE_SKILL_DIR}/../../lib/feature-init.sh" skeleton --mode single \
  --slug "$slug" --now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --style "$execStyle" --title "$title" \
  --branch "$feature_branch" --base-sha "$base_sha" --base-branch "$base_branch" \
  --worktree "$worktree_state_path" \
  --prepare "$cmd_prepare" --test "$cmd_test" --lint "$cmd_lint" --typecheck "$cmd_typecheck")
feature_json="$(jq --argjson baseline "$baseline_json" --arg profile "$cycle_profile" \
  '.verificationBaseline = $baseline | .executionProfile = $profile' <<<"$feature_json")"

bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" ".loop-spec/features/${slug}" "$feature_json"
feature_dir_abs="$(cd ".loop-spec/features/${slug}" && pwd -P)"
bash "${CLAUDE_SKILL_DIR}/../../lib/cycle-result.sh" begin \
  --result-root "$repo_root" --cycle-type full --title "$title" --slug "$slug" \
  --branch "$feature_branch" --base-branch "$base_branch" --feature-dir "$feature_dir_abs" \
  --phase spec --autonomous "$active_autonomous"

# Autonomous mode: persist the flag so phase skills and resumed sessions see it
# without re-parsing the invocation (skills/shared/autonomous-mode.md).
# Greenfield mode: persist it the same way (Step 0 greenfield branch set $greenfield).
[[ "${autonomous:-0}" == "1" ]] && bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" set ".loop-spec/features/${slug}" autonomous true
[[ "${greenfield:-0}" == "1" ]] && bash "${CLAUDE_SKILL_DIR}/../../lib/feature-write.sh" set ".loop-spec/features/${slug}" greenfield true

# Move any pre-SPEC assumed decisions (recorded during Steps 0-4) into the feature dir
# so SPEC can render them; no-op when nothing was staged.
bash "${CLAUDE_SKILL_DIR}/../../lib/decisions.sh" migrate \
  "$repo_root/.loop-spec/decisions-staging" ".loop-spec/features/${slug}"
```
