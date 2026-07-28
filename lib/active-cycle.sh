#!/usr/bin/env bash
# Resolve whether a full cycle is active in the ambient checkout or any linked worktree.
#
# Usage: active-cycle.sh has-active [root ...]
# Exit 0: active feature found; 1: no active feature; 2: resolution failed.
set -uo pipefail

[[ "${1:-}" == "has-active" ]] || {
  echo "usage: active-cycle.sh has-active [root ...]" >&2
  exit 2
}
shift

roots=()
add_root() {
  local candidate="$1" resolved existing
  [[ -n "$candidate" && -d "$candidate" ]] || return 0
  resolved="$(cd "$candidate" 2>/dev/null && pwd -P)" || return 2
  for existing in "${roots[@]-}"; do
    [[ "$existing" == "$resolved" ]] && return 0
  done
  roots+=("$resolved")
}

if [[ $# -gt 0 ]]; then
  for root in "$@"; do
    add_root "$root" || exit 2
  done
else
  add_root "$PWD" || exit 2
  add_root "${CLAUDE_PROJECT_DIR:-}" || exit 2
fi

# Seed paths may be subdirectories. Add their repository roots and every worktree
# registered in the same common repository; add_root keeps the scan byte-stable.
seed_count="${#roots[@]}"
for ((i = 0; i < seed_count; i++)); do
  root="${roots[$i]}"
  repo_root="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -z "$repo_root" ]] || add_root "$repo_root" || exit 2
  if [[ -n "$repo_root" ]]; then
    worktrees="$(git -C "$repo_root" -c core.quotePath=false worktree list --porcelain 2>/dev/null)" || exit 2
    while IFS= read -r line; do
      [[ "$line" == worktree\ * ]] || continue
      add_root "${line#worktree }" || exit 2
    done <<<"$worktrees"
  fi
done

for root in "${roots[@]}"; do
  features_dir="$root/.loop-spec/features"
  [[ -d "$features_dir" ]] || continue
  for feature_json in "$features_dir"/*/feature.json; do
    [[ -f "$feature_json" ]] || continue
    phase="$(jq -er '.currentPhase | select(type == "string")' "$feature_json" 2>/dev/null)" || {
      echo "active-cycle: unreadable feature state: $feature_json" >&2
      exit 2
    }
    case "$phase" in
      spec|discuss|plan|execute|verify|iterate|deliver) ;;
      *) continue ;;
    esac

    delivery_file="$(dirname "$feature_json")/delivery.json"
    if [[ -f "$delivery_file" ]]; then
      next_phase="$(jq -er '.nextPhase // "" | select(type == "string")' "$delivery_file" 2>/dev/null)" || {
        echo "active-cycle: unreadable delivery state: $delivery_file" >&2
        exit 2
      }
      [[ "$next_phase" == "completed" ]] && continue
    fi
    printf '%s\t%s\t%s\n' "$root" "$(basename "$(dirname "$feature_json")")" "$phase"
    exit 0
  done
done

exit 1
