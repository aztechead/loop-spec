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
      if ! git push -u origin "${branch}:${branch}" 2>/dev/null; then
        _skip "push failed for branch '${branch}'"
      fi
    else
      if ! git push -u origin "$branch" 2>/dev/null; then
        _skip "push failed for branch '${branch}'"
      fi
    fi

    # ── Step 5: Idempotency — check for existing open PR ───────────────────────
    existing_url=$(gh pr list --head "$branch" --state open --json url --jq '.[0].url' 2>/dev/null || echo "")

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

      pr_url=$(gh pr create --draft \
        --base "${base_branch:-main}" \
        --head "$branch" \
        --title "$pr_title" \
        --body "$pr_body" 2>/dev/null) || {
        _skip "gh pr create failed"
      }
      pr_kind="draft"
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
