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
cycle_type="$(jq -r '.cycleType // "full"' "$active")"
case "$cycle_type" in full|micro|debug) ;; *) cycle_type="full" ;; esac
slug="$(jq -r '.slug // empty' "$active")"
branch="$(jq -r '.branch // empty' "$active")"
base_branch="$(jq -r '.baseBranch // empty' "$active")"
phase="$(jq -r '.phase // "startup"' "$active")"
feature_dir="$(jq -r '.featureDir // empty' "$active")"
autonomous="$(jq -r '.autonomous // false' "$active")"
summary="Cycle interrupted during ${phase}: ${reason}"

# A delivered PR in this run is not an interruption. Reconcile used to stamp
# converged=false over a successful DELIVER because the agent process ended
# before the cycle-skill write, and the supervisor then marked the PR a draft.
# Phase is not required: an inline cycle can open the PR without advancing
# currentPhase through deliver/completed.
_delivery_succeeded() {
  local fdir="$1"
  [[ -f "$fdir/feature.json" ]] || return 1
  local delivery="$fdir/delivery.json"
  [[ -f "$delivery" ]] || delivery="$fdir/feature.json"
  if jq -e '
    .status == "ready-for-review"
    or ((.targets // []) | map(select(
          .outcome == "delivered" and ((.prUrl // "") != ""))) | length) > 0
    or ((.delivery.status // "") == "ready-for-review")
    or ((.delivery.targets // []) | map(select(
          .outcome == "delivered" and ((.prUrl // "") != ""))) | length) > 0
  ' "$delivery" >/dev/null 2>&1; then
    return 0
  fi
  jq -e '
    ((.prUrl // "") != "")
    and ((.prUrl // "") != (.checkpointPrUrl // ""))
  ' "$fdir/feature.json" >/dev/null 2>&1
}

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
  if _delivery_succeeded "$feature_dir"; then
    delivered_summary="$(jq -r '.iterate.lastVerdict.summary // empty' \
      "$feature_dir/feature.json" 2>/dev/null || true)"
    if ! jq -en --arg s "$delivered_summary" '$s | test("\\S")' >/dev/null 2>&1; then
      delivered_summary="Cycle completed; a PR was delivered."
    fi
    LOOP_SPEC_RESULT_ROOT="$result_root" bash "$script_dir/cycle-result.sh" write \
      "$feature_dir" --status completed --summary "$delivered_summary"
    final_rc=$?
    if [[ "$final_rc" -ne 0 ]]; then
      echo "cycle-reconcile: delivered terminal result could not be published (rc=$final_rc)" >&2
      exit "$final_rc"
    fi
    exit 0
  fi
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
  # Propagate a publication failure. Reconciliation exists to leave exactly one
  # authoritative terminal result behind; if the pointer could not be published,
  # reporting success would tell the supervisor the run was accounted for when it
  # was not -- the same silent loss this script is the backstop against.
  final_rc=0
  LOOP_SPEC_RESULT_ROOT="$result_root" bash "$script_dir/cycle-result.sh" write "$feature_dir" \
    --status failed --reason "$reason" --summary "$summary" || final_rc=$?
  if [[ "$final_rc" -ne 0 ]]; then
    echo "cycle-reconcile: terminal result could not be published (rc=$final_rc)" >&2
    exit "$final_rc"
  fi
  exit 0
fi

bash "$script_dir/cycle-result.sh" write-terminal \
  --result-root "$result_root" --cycle-type "$cycle_type" --status failed \
  --outcome interrupted --title "$title" --slug "$slug" --branch "$branch" \
  --base-branch "$base_branch" --phase-reached "$phase" --reason "$reason" \
  --converged false --verification-status not-run --autonomous "$autonomous" \
  --summary "$summary"
