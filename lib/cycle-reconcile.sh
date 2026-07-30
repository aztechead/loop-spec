#!/usr/bin/env bash
# Complete the terminal-result contract after an interrupted full cycle.
# Intended for an out-of-band supervisor after the agent process exits.
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
result_root=""
reason="agent process terminated before emitting a terminal result"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --result-root) result_root="${2:-}"; shift 2 ;;
    --reason) reason="${2:-}"; shift 2 ;;
    *) echo "cycle-reconcile: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

[[ -n "$result_root" && -d "$result_root" ]] || {
  echo "cycle-reconcile: --result-root must name a directory" >&2
  exit 2
}
result_root="$(bash "$script_dir/cycle-result.sh" resolve-root "$result_root")" || exit 2
active="$result_root/.loop-spec/active-run.json"
terminal="$result_root/.loop-spec/last-result.json"

if [[ ! -f "$active" ]]; then
  if [[ -f "$terminal" ]]; then
    printf 'LOOP_SPEC_RESULT %s\n' "$(jq -c . "$terminal")"
    exit 0
  fi
  echo "cycle-reconcile: no active run or terminal result found" >&2
  exit 1
fi

title="$(jq -r '.title // "Interrupted loop-spec cycle"' "$active")"
slug="$(jq -r '.slug // empty' "$active")"
branch="$(jq -r '.branch // empty' "$active")"
base_branch="$(jq -r '.baseBranch // empty' "$active")"
phase="$(jq -r '.phase // "startup"' "$active")"
feature_dir="$(jq -r '.featureDir // empty' "$active")"
autonomous="$(jq -r '.autonomous // false' "$active")"
summary="Cycle interrupted during ${phase}: ${reason}"

if [[ ! -f "$feature_dir/feature.json" && -n "$slug" ]]; then
  candidate="$result_root/.loop-spec/features/$slug"
  if [[ -f "$candidate/feature.json" ]]; then
    feature_dir="$candidate"
  elif git -C "$result_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    candidate="$(
      git -C "$result_root" worktree list --porcelain 2>/dev/null \
        | awk '/^worktree / { sub(/^worktree /, ""); print }' \
        | while IFS= read -r worktree; do
            if [[ -f "$worktree/.loop-spec/features/$slug/feature.json" ]]; then
              printf '%s\n' "$worktree/.loop-spec/features/$slug"
              break
            fi
          done
    )"
    [[ -z "$candidate" ]] || feature_dir="$candidate"
  fi
fi

if [[ -n "$feature_dir" && -f "$feature_dir/feature.json" ]]; then
  # Establish the local terminal result before attempting network I/O. A second
  # write below picks up checkpointPrUrl if the best-effort push succeeds.
  LOOP_SPEC_RESULT_ROOT="$result_root" bash "$script_dir/cycle-result.sh" write "$feature_dir" \
    --status failed --reason "$reason" --summary "$summary"
  repo_root="$(git -C "$feature_dir" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$repo_root" ]]; then
    (
      cd "$repo_root" || exit 0
      bash "$script_dir/checkpoint-pr.sh" create "$feature_dir" --reason "$reason"
    ) || true
  fi
  LOOP_SPEC_RESULT_ROOT="$result_root" bash "$script_dir/cycle-result.sh" write "$feature_dir" \
    --status failed --reason "$reason" --summary "$summary"
  exit 0
fi

bash "$script_dir/cycle-result.sh" write-terminal \
  --result-root "$result_root" --cycle-type full --status failed \
  --outcome interrupted --title "$title" --slug "$slug" --branch "$branch" \
  --base-branch "$base_branch" --phase-reached "$phase" --reason "$reason" \
  --converged false --verification-status not-run --autonomous "$autonomous" \
  --summary "$summary"
