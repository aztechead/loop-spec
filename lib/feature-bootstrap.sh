#!/usr/bin/env bash
# Shared cycle Step 5: per-repo prepare/baseline (prepare-repo) and single-repo
# skeleton+flags+decisions (finalize). Workspace mode used to inline the same
# prepare-environment.sh / verification-baseline.sh sequence without writing a
# terminal result; this script is the one fail-terminal path both layouts call,
# so the procedure never enters the model's context.
#
# Usage:
#   bash lib/feature-bootstrap.sh prepare-repo \
#       --root PATH --result-root PATH \
#       --slug S --title "ORIGINAL GOAL" \
#       --branch feat/S --base-branch BB --base-sha SHA \
#       --autonomous 0|1 --greenfield 0|1 \
#       --prepare CMD --test CMD --lint CMD --typecheck CMD \
#       [--repo-label NAME]
#     -> prepares one repository, upgrades a generic python test command, and
#        captures the opt-in baseline. Prints one JSON object on stdout:
#        {command, key, test, baseline}. Chatter on stderr.
#
#   bash lib/feature-bootstrap.sh finalize \
#       --repo-root PATH --execution-root PATH \
#       --slug S --title "ORIGINAL GOAL" \
#       --branch feat/S --base-branch BB --base-sha SHA \
#       --worktree PATH_OR_EMPTY --style ST --profile PROFILE \
#       --autonomous 0|1 --greenfield 0|1 \
#       --prepare CMD --test CMD --lint CMD --typecheck CMD
#     -> runs prepare-repo against the execution root, writes the schema-7
#        feature.json (via lib/feature-init.sh skeleton), records the
#        cycle-result begin marker, and migrates staged pre-SPEC decisions.
#        Prints the updated test command on stdout.
#
# Exit codes: 0 success; 1 preparation or baseline failure (a terminal cycle
# result has already been written); 2 bad invocation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { sed -n '2,33p' "${BASH_SOURCE[0]}" >&2; exit 2; }

need() {
  local val="$1" flag="$2"
  [[ -n "$val" ]] || { echo "feature-bootstrap: $flag is required" >&2; exit 2; }
}

# Shared prepare + pytest rewrite + opt-in baseline. Sets cmd_prepare, cmd_test,
# prepare_key, baseline_json. prep_root is the repository being prepared;
# result_root is where write-terminal publishes (control checkout / workspace root).
_prepare_repo() {
  local prefix="" active_autonomous="false"
  [[ -n "${repo_label:-}" ]] && prefix="${repo_label}: "
  [[ "$autonomous" == "1" ]] && active_autonomous="true"

  local prepare_rc=0
  local prepare_json
  prepare_json="$(bash "$SCRIPT_DIR/prepare-environment.sh" run \
    --root "$prep_root" --command "$cmd_prepare")" || prepare_rc=$?
  [[ "$prepare_rc" -eq 0 ]] || {
    local prepare_reason
    prepare_reason="$(jq -r --arg fallback "$prepare_rc" \
      '(.failureKind // .status // "unknown") + " (exit " +
       ((.exitCode // ($fallback | tonumber)) | tostring) + ")"' \
      <<<"${prepare_json:-{}}" 2>/dev/null \
      || printf 'environment preparation failed (exit %s)' "$prepare_rc")"
    bash "$SCRIPT_DIR/cycle-result.sh" write-terminal \
      --result-root "$result_root" --cycle-type full --status failed \
      --outcome infrastructure-failed --title "$title" --slug "$slug" \
      --branch "$feature_branch" --base-branch "$base_branch" --phase-reached startup \
      --reason "${prefix}${prepare_reason}" \
      --summary "${prefix}Environment preparation failed: $prepare_reason" \
      --converged false --verification-status not-run --autonomous "$active_autonomous"
    echo "loop-spec: environment preparation failed before feature initialization: ${prefix}${prepare_reason}." >&2
    exit 1
  }
  prepare_key="$(jq -r '.key // ""' <<<"$prepare_json")"
  cmd_prepare="$(jq -r '.command // ""' <<<"$prepare_json")"
  # Preparation may create an isolated Python runner. Upgrade the generic auto-detected
  # python command even when it is one conjunct in a polyglot join; never overwrite a
  # user-pinned LOOP_SPEC_CMD_TEST value.
  if [[ "$cmd_test" == *"python -m pytest"* && -z "${LOOP_SPEC_CMD_TEST+x}" ]]; then
    cmd_test="$(bash "$SCRIPT_DIR/detect-test-cmd.sh" "$prep_root")"
  fi

  # Opt-in startup baseline (LOOP_SPEC_STARTUP_BASELINE=1). Default off: no capture runs,
  # `verificationBaseline` stays null, and VERIFY's end-of-cycle comparison treats every
  # failure it observes as blocking. Turn it on only where the base commit is already red
  # and the known-failure oracle is what stops VERIFY from chasing pre-existing failures.
  # The capture owns a foreground watchdog and must leave HEAD and the worktree unchanged.
  baseline_json=null
  if [[ "${LOOP_SPEC_STARTUP_BASELINE:-0}" == "1" && "${greenfield:-0}" != "1" ]]; then
    local baseline_git_path baseline_rc=0
    baseline_git_path="$(git -C "$prep_root" rev-parse --git-path "loop-spec/validation/${slug}/base")"
    [[ "$baseline_git_path" == /* ]] || baseline_git_path="$prep_root/$baseline_git_path"
    mkdir -p "$baseline_git_path"
    baseline_json="$(bash "$SCRIPT_DIR/verification-baseline.sh" capture \
      --root "$prep_root" --base-sha "$base_sha" --prepare-key "$prepare_key" \
      --log-dir "$baseline_git_path" --test "$cmd_test" --lint "$cmd_lint" \
      --typecheck "$cmd_typecheck")" || baseline_rc=$?
    [[ "$baseline_rc" -eq 0 ]] || {
      local baseline_reason
      baseline_reason="$(jq -r '.reason // "exact-base validation baseline could not be captured"' \
        <<<"${baseline_json:-{}}" 2>/dev/null || printf 'exact-base validation baseline failed')"
      bash "$SCRIPT_DIR/cycle-result.sh" write-terminal \
        --result-root "$result_root" --cycle-type full --status failed \
        --outcome infrastructure-failed --title "$title" --slug "$slug" \
        --branch "$feature_branch" --base-branch "$base_branch" --phase-reached startup \
        --reason "${prefix}${baseline_reason}" \
        --summary "${prefix}Validation baseline failed: $baseline_reason" \
        --converged false --verification-status failed --verification-command "$cmd_test" \
        --autonomous "$active_autonomous"
      echo "loop-spec: exact-base validation baseline could not be captured (exit $baseline_rc): ${prefix}${baseline_reason}." >&2
      exit 1
    }
    baseline_json="$(jq -c . <<<"$baseline_json")"
  fi
}

cmd="${1:-}"
case "$cmd" in
  prepare-repo|finalize) shift ;;
  *) usage ;;
esac

repo_root="" execution_root="" prep_root="" result_root="" slug="" title=""
feature_branch="" base_branch="" base_sha="" worktree_state_path="" execStyle=""
cycle_profile="" autonomous="0" greenfield="0" cmd_prepare="" cmd_test=""
cmd_lint="" cmd_typecheck="" repo_label=""
prepare_key="" baseline_json=null

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)           prep_root="$2"; shift 2 ;;
    --repo-root)      repo_root="$2"; shift 2 ;;
    --execution-root) execution_root="$2"; shift 2 ;;
    --result-root)    result_root="$2"; shift 2 ;;
    --slug)           slug="$2"; shift 2 ;;
    --title)          title="$2"; shift 2 ;;
    --branch)         feature_branch="$2"; shift 2 ;;
    --base-branch)    base_branch="$2"; shift 2 ;;
    --base-sha)       base_sha="$2"; shift 2 ;;
    --worktree)       worktree_state_path="$2"; shift 2 ;;
    --style)          execStyle="$2"; shift 2 ;;
    --profile)        cycle_profile="$2"; shift 2 ;;
    --autonomous)     autonomous="$2"; shift 2 ;;
    --greenfield)     greenfield="$2"; shift 2 ;;
    --prepare)        cmd_prepare="$2"; shift 2 ;;
    --test)           cmd_test="$2"; shift 2 ;;
    --lint)           cmd_lint="$2"; shift 2 ;;
    --typecheck)      cmd_typecheck="$2"; shift 2 ;;
    --repo-label)     repo_label="$2"; shift 2 ;;
    *) echo "feature-bootstrap: unknown argument '$1'" >&2; usage ;;
  esac
done

need "$slug" --slug
need "$title" --title
need "$feature_branch" --branch
need "$base_branch" --base-branch
need "$base_sha" --base-sha

if [[ "$cmd" == "prepare-repo" ]]; then
  need "$prep_root" --root
  need "$result_root" --result-root
  _prepare_repo
  jq -cn --arg command "$cmd_prepare" --arg key "$prepare_key" \
    --arg test "$cmd_test" --argjson baseline "$baseline_json" \
    '{command:$command,key:$key,test:$test,baseline:$baseline}'
  exit 0
fi

need "$repo_root" --repo-root
need "$execution_root" --execution-root
need "$execStyle" --style
need "$cycle_profile" --profile

prep_root="$execution_root"
result_root="$repo_root"
cd "$execution_root" || { echo "feature-bootstrap: cannot cd to '$execution_root'" >&2; exit 2; }

_prepare_repo

active_autonomous=false
[[ "$autonomous" == "1" ]] && active_autonomous=true

# Create dirs and write feature.json inside the now-active execution root.
mkdir -p ".loop-spec/features/${slug}" .loop-spec/codebase "docs/loop-spec/features/${slug}"
# Startup probes ran in the control checkout. Copy their local runtime cache into
# a Claude feature worktree; in-place harnesses already point at the same file.
if [[ -f "$repo_root/.loop-spec/runtime.json" && "$(pwd -P)" != "$(cd "$repo_root" && pwd -P)" ]]; then
  cp "$repo_root/.loop-spec/runtime.json" .loop-spec/runtime.json
fi

# Build the full schema-7 skeleton from the single source of truth (lib/feature-init.sh).
# Model routes, configured phase defaults, the fixed iterate block, and the artifact
# scaffold all live in that one script -- never hand-build feature.json inline.
feature_json=$(bash "$SCRIPT_DIR/feature-init.sh" skeleton --mode single \
  --slug "$slug" --now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --style "$execStyle" --title "$title" \
  --branch "$feature_branch" --base-sha "$base_sha" --base-branch "$base_branch" \
  --worktree "$worktree_state_path" \
  --prepare "$cmd_prepare" --test "$cmd_test" --lint "$cmd_lint" --typecheck "$cmd_typecheck")
feature_json="$(jq --argjson baseline "$baseline_json" --arg profile "$cycle_profile" \
  '.verificationBaseline = $baseline | .executionProfile = $profile' <<<"$feature_json")"

# Everything below chats on stdout; the ONLY stdout this script owns is the final
# test command the caller captures, so sub-call chatter is routed to stderr.
bash "$SCRIPT_DIR/feature-write.sh" ".loop-spec/features/${slug}" "$feature_json" >&2
feature_dir_abs="$(cd ".loop-spec/features/${slug}" && pwd -P)"
bash "$SCRIPT_DIR/cycle-result.sh" begin \
  --result-root "$repo_root" --cycle-type full --title "$title" --slug "$slug" \
  --branch "$feature_branch" --base-branch "$base_branch" --feature-dir "$feature_dir_abs" \
  --phase spec --autonomous "$active_autonomous" >&2

# Autonomous mode: persist the flag so phase skills and resumed sessions see it
# without re-parsing the invocation (skills/shared/autonomous-mode.md).
# Greenfield mode: persist it the same way.
if [[ "$autonomous" == "1" ]]; then
  bash "$SCRIPT_DIR/feature-write.sh" set ".loop-spec/features/${slug}" autonomous true >&2
fi
if [[ "$greenfield" == "1" ]]; then
  bash "$SCRIPT_DIR/feature-write.sh" set ".loop-spec/features/${slug}" greenfield true >&2
fi

# Move any pre-SPEC assumed decisions (recorded during cycle Steps 0-4) into the
# feature dir so SPEC can render them; no-op when nothing was staged.
bash "$SCRIPT_DIR/decisions.sh" migrate \
  "$repo_root/.loop-spec/decisions-staging" ".loop-spec/features/${slug}" >&2

printf '%s\n' "$cmd_test"
