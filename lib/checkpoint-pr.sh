#!/usr/bin/env bash
# Push feature branch and open/reuse a draft GitHub PR on pause, escalation, or
# terminal stop so an interrupted cycle (headless or interactive) yields a
# reviewable artifact. Default ON for all runs; LOOP_SPEC_CHECKPOINT_PR=0 disables.
#
# Usage: checkpoint-pr.sh create <feature_dir> [--reason <text>]
#
# NOTE: workspace mode is out of scope (per-repo branches; callers handle per-repo PRs).
#       The top-level .branch field is null in workspace mode; this script skips on null.
#
# NOTE: checkpointPrUrl is already consumed by lib/cycle-result.sh (result.json field);
#       no changes are needed there.
#
# OBSERVABILITY CONTRACT: this script must NEVER abort a cycle. All internal
# failures print a one-line warning to stderr and exit 0. Same contract as
# lib/events.sh and lib/cycle-result.sh.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=credential-refresh.sh
. "$script_dir/credential-refresh.sh"
# shellcheck source=bounded-run.sh
. "$script_dir/bounded-run.sh"

# This script is the crash-rescue path: lib/cycle-reconcile.sh runs it out of band
# AFTER the agent process has exited, as the last chance to leave a reviewable PR.
# Its caller wraps it in `|| true`, which absorbs a failure but not a hang -- so an
# unbounded git/gh call here silently strands the one safety net that was supposed
# to catch everything else.
loop_spec_disable_interactive_prompts
_checkpoint_timeout="$(loop_spec_resolve_timeout "${LOOP_SPEC_GH_COMMAND_TIMEOUT_SECONDS:-}" 60)" \
  || _checkpoint_timeout=60

_warn() { echo "checkpoint-pr: $*" >&2; }
_skip() { _warn "$*"; exit 0; }

cmd="${1:-}"
feature_dir="${2:-}"

case "$cmd" in
  create)
    # Parse optional --reason flag
    reason=""
    shift 2 || true
    while [[ $# -gt 0 ]]; do
      case "${1:-}" in
        --reason) reason="${2:-}"; shift 2 || shift || true ;;
        *) shift || true ;;
      esac
    done

    # ── Step 1: Gating (before any git/gh work) ────────────────────────────────
    # Default-on for ALL runs (autonomous and interactive): an interrupted cycle
    # should yield a reviewable draft PR regardless of how it was started.
    # LOOP_SPEC_CHECKPOINT_PR=0 is the only off switch.
    if [[ "${LOOP_SPEC_CHECKPOINT_PR:-}" == "0" ]]; then
      echo "checkpoint-pr: disabled (LOOP_SPEC_CHECKPOINT_PR=0)"
      exit 0
    fi

    # ── Step 2: Read feature.json ───────────────────────────────────────────────
    if [[ ! -f "$feature_dir/feature.json" ]]; then
      _skip "feature.json not found in $feature_dir"
    fi

    branch=$(jq -r '.branch // empty' "$feature_dir/feature.json" 2>/dev/null || true)
    if [[ -z "$branch" ]]; then
      _skip ".branch is null/empty in feature.json (workspace mode is out of scope; callers handle per-repo PRs)"
    fi

    base_branch=$(jq -r '.baseBranch // "main"' "$feature_dir/feature.json" 2>/dev/null || echo "main")
    feature_title=$(jq -r '.feature_title // .slug // "unknown"' "$feature_dir/feature.json" 2>/dev/null || echo "unknown")
    current_phase=$(jq -r '.currentPhase // "unknown"' "$feature_dir/feature.json" 2>/dev/null || echo "unknown")

    # ── Step 3: Preconditions (each a skip, never a failure) ───────────────────
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      _skip "not inside a git work tree"
    fi

    if ! git remote get-url origin >/dev/null 2>&1; then
      _skip "no 'origin' remote"
    fi

    if ! command -v gh >/dev/null 2>&1; then
      _skip "'gh' not on PATH"
    fi

    repo_dir="$(pwd -P)"
    remote_url="$(git remote get-url --push origin 2>/dev/null || git remote get-url origin 2>/dev/null)"
    credential_host="$(python3 - "$remote_url" <<'PY'
import re, sys
try:
    from urllib.parse import urlparse
except ImportError:
    from urlparse import urlparse

value = sys.argv[1]
match = re.match(r'^[^@/]+@([^:/]+):', value)
if match:
    print(match.group(1).lower())
else:
    print((urlparse(value).hostname or '').lower())
PY
)"
    [[ -n "$credential_host" ]] || credential_host="${GH_HOST:-github.com}"

    command_tmp="$(mktemp -d "${TMPDIR:-/tmp}/loop-spec-checkpoint-pr-XXXXXX")" \
      || _skip "cannot allocate command output"
    trap 'rm -rf "$command_tmp"' EXIT
    trap 'exit 0' HUP INT TERM
    command_out="$command_tmp/stdout"
    command_err="$command_tmp/stderr"

    run_once() {
      local stdout_file="$1" stderr_file="$2"
      shift 2
      LOOP_SPEC_BOUNDED_RUN_CWD="$repo_dir" \
        loop_spec_run_bounded "$_checkpoint_timeout" "$stdout_file" "$stderr_file" "$@"
    }

    run_authenticated() {
      local stage="$1"
      shift
      loop_spec_run_authenticated "$repo_dir" "$stage" "$credential_host" \
        "$command_out" "$command_err" run_once "$command_out" "$command_err" "$@"
    }

    run_without_auth_retry() {
      local stage="$1"
      shift
      LOOP_SPEC_AUTH_ERROR_CODE=""
      LOOP_SPEC_AUTH_ERROR_MESSAGE=""
      loop_spec_credential_refresh "$repo_dir" "$stage" "pre-stage" "$credential_host" || return 125
      run_once "$command_out" "$command_err" "$@"
    }

    auth_skip() {
      if [[ -n "$LOOP_SPEC_AUTH_ERROR_CODE" ]]; then
        _skip "$LOOP_SPEC_AUTH_ERROR_CODE: $LOOP_SPEC_AUTH_ERROR_MESSAGE"
      fi
      _skip "$1"
    }

    list_open_pr_once() {
      local rc=0
      run_once "$command_out" "$command_err" gh pr list --head "$branch" --state open \
        --json url --jq '.[0].url' || rc=$?
      [[ "$rc" -eq 0 ]] || return "$rc"
      existing_url="$(tr -d '\r\n' < "$command_out")"
    }

    # Determine push form: when cwd is not on the feature branch use explicit ref
    current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    use_explicit_ref=0
    if [[ "$current_branch" != "$branch" ]]; then
      if ! git rev-parse --verify --quiet "$branch" >/dev/null 2>&1; then
        _skip "branch '$branch' does not exist locally"
      fi
      use_explicit_ref=1
    fi

    # ── Step 4: Push ────────────────────────────────────────────────────────────
    if [[ "$use_explicit_ref" -eq 1 ]]; then
      push_rc=0
      run_authenticated push git push -u origin "${branch}:${branch}" || push_rc=$?
      if [[ "$push_rc" -ne 0 ]]; then
        auth_skip "push failed for branch '${branch}'"
      fi
    else
      push_rc=0
      run_authenticated push git push -u origin "$branch" || push_rc=$?
      if [[ "$push_rc" -ne 0 ]]; then
        auth_skip "push failed for branch '${branch}'"
      fi
    fi

    # ── Step 5: Idempotency — check for existing open PR ───────────────────────
    list_rc=0
    run_authenticated github-pr gh pr list --head "$branch" --state open \
      --json url --jq '.[0].url' || list_rc=$?
    [[ "$list_rc" -eq 0 ]] || auth_skip "gh pr list failed"
    existing_url="$(tr -d '\r\n' < "$command_out")"

    if [[ -n "$existing_url" && "$existing_url" != "null" ]]; then
      pr_url="$existing_url"
      pr_kind="existing"
    else
      # ── Step 6: Create draft PR ──────────────────────────────────────────────
      pr_title="WIP: ${feature_title} (checkpoint: ${current_phase})"

      pr_body="This is an automated checkpoint of an INCOMPLETE loop-spec cycle.

Phase reached: ${current_phase}"
      if [[ -n "$reason" ]]; then
        pr_body="${pr_body}
Reason: ${reason}"
      fi

      if [[ -f "$feature_dir/PROGRESS.md" ]]; then
        progress_tail=$(tail -20 "$feature_dir/PROGRESS.md" 2>/dev/null || true)
        if [[ -n "$progress_tail" ]]; then
          pr_body="${pr_body}

## Progress tail

${progress_tail}"
        fi
      fi

      pr_body="${pr_body}

Resuming \`/loop-spec:cycle\` on this branch continues the run. Re-review this PR after cycle completion."

      create_rc=0
      run_without_auth_retry github-pr gh pr create --draft \
        --base "${base_branch:-main}" \
        --head "$branch" \
        --title "$pr_title" \
        --body "$pr_body" || create_rc=$?

      if [[ "$create_rc" -eq 0 ]]; then
        pr_url="$(tr -d '\r\n' < "$command_out")"
        pr_kind="draft"
      elif loop_spec_is_auth_failure "$create_rc" "$command_out" "$command_err"; then
        loop_spec_credential_refresh "$repo_dir" "github-pr" "auth-retry" "$credential_host" \
          || auth_skip "credential refresh failed before PR create reconciliation"

        relist_rc=0
        list_open_pr_once || relist_rc=$?
        [[ "$relist_rc" -eq 0 ]] || auth_skip "cannot re-list after gh pr create authentication failure"
        if [[ -n "$existing_url" && "$existing_url" != "null" ]]; then
          pr_url="$existing_url"
          pr_kind="existing"
        else
          create_rc=0
          run_once "$command_out" "$command_err" gh pr create --draft \
            --base "${base_branch:-main}" --head "$branch" --title "$pr_title" --body "$pr_body" \
            || create_rc=$?
          if [[ "$create_rc" -eq 0 ]]; then
            pr_url="$(tr -d '\r\n' < "$command_out")"
            pr_kind="draft"
          else
            relist_rc=0
            list_open_pr_once || relist_rc=$?
            if [[ "$relist_rc" -eq 0 && -n "$existing_url" && "$existing_url" != "null" ]]; then
              pr_url="$existing_url"
              pr_kind="existing"
            else
              if loop_spec_is_auth_failure "$create_rc" "$command_out" "$command_err"; then
                LOOP_SPEC_AUTH_ERROR_CODE="authentication_failed"
                LOOP_SPEC_AUTH_ERROR_MESSAGE="authentication failed after credential refresh"
              fi
              auth_skip "gh pr create failed after credential refresh"
            fi
          fi
        fi
      else
        relist_rc=0
        list_open_pr_once || relist_rc=$?
        if [[ "$relist_rc" -eq 0 && -n "$existing_url" && "$existing_url" != "null" ]]; then
          pr_url="$existing_url"
          pr_kind="existing"
        else
          _skip "gh pr create failed"
        fi
      fi
    fi

    # ── Step 7: Persist + emit (both best-effort) ───────────────────────────────
    bash "$(dirname "${BASH_SOURCE[0]}")/feature-write.sh" set "$feature_dir" checkpointPrUrl "\"$pr_url\"" 2>/dev/null || true

    data_json=$(jq -cn --arg url "$pr_url" '{"url": $url}')
    bash "$(dirname "${BASH_SOURCE[0]}")/events.sh" emit "$feature_dir" checkpoint_pr --data "$data_json" 2>/dev/null || true

    echo "checkpoint-pr: ${pr_kind} PR $pr_url"
    exit 0
    ;;
  *)
    echo "checkpoint-pr: unknown subcommand '${cmd:-}'. Usage: checkpoint-pr.sh create <feature_dir> [--reason <text>]" >&2
    exit 0
    ;;
esac
