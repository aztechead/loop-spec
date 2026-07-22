#!/usr/bin/env bash
# debug-init.sh - Deterministic Step 0 mechanics for the debug skill.
#
# The debug loop's setup is pure mechanics: slug the symptom, create the BUG.md dir,
# apply branch discipline, capture the branch-point SHA (the test-tamper scan's
# baseline), detect the test command. Prose-driving these risks drift — especially
# the SHA capture, which VERIFY needs recorded BEFORE any change lands.
#
# Usage:
#   debug-init.sh init [--dir <repo_dir>] -- <symptom text...>
#
# Behavior:
#   1. slug   = kebab-case of the first 6 words of the token-stripped symptom
#               (parse-invocation strips autonomous/style: tokens first).
#   2. bugdir = docs/loop-spec/debug/{slug} (created).
#   3. branch discipline:
#        - on the default branch -> create + switch to fix/{slug}
#        - already on a non-default branch -> stay (branch_action="kept");
#          dirty tree there is reported as dirty=true for the SKILL's
#          stop-and-ask / autonomous-relatedness judgment (NOT decided here).
#   4. sha    = HEAD short SHA captured BEFORE any change (test-tamper baseline).
#   5. test_cmd = LOOP_SPEC_CMD_TEST when set, else lib/detect-test-cmd.sh.
#
# Output: one JSON object:
#   {slug, bug_dir, branch, branch_action: created|kept, default_branch,
#    dirty, sha_before, test_cmd, autonomous, style}
#
# Exit codes: 0 success, 1 bad invocation / not a git repo.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cmd="${1:-}"
[[ "$cmd" == "init" ]] || {
  echo "usage: debug-init.sh init [--dir <repo_dir>] -- <symptom text...>" >&2
  exit 1
}
shift

repo_dir="$PWD"
if [[ "${1:-}" == "--dir" ]]; then
  repo_dir="${2:-}"
  [[ -d "$repo_dir" ]] || { echo "debug-init: no such directory: $repo_dir" >&2; exit 1; }
  shift 2
fi
bash "$SCRIPT_DIR/cycle-result.sh" clear --result-root "$repo_dir"
bash "$SCRIPT_DIR/runtime-preflight.sh" check-jq
[[ "${1:-}" == "--" ]] && shift

symptom="$*"
[[ -n "$symptom" ]] || { echo "debug-init: symptom text required" >&2; exit 1; }

git -C "$repo_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "debug-init: not a git repo: $repo_dir" >&2
  exit 1
}
git -C "$repo_dir" rev-parse --verify -q HEAD >/dev/null 2>&1 || {
  echo "debug-init: repo has no commits — nothing to debug against (no baseline for the test-tamper scan). Commit something first." >&2
  exit 1
}

inv="$(bash "$SCRIPT_DIR/parse-invocation.sh" parse -- "$symptom")"
autonomous="$(jq -r '.autonomous' <<<"$inv")"
style="$(jq -r '.style' <<<"$inv")"
clean_text="$(jq -r '.title' <<<"$inv")"
[[ -n "$clean_text" ]] || { echo "debug-init: symptom is empty after token stripping" >&2; exit 1; }

# Slug from the first 6 words of the cleaned symptom.
short="$(printf '%s' "$clean_text" | tr -s '[:space:]' ' ' | cut -d' ' -f1-6)"
slug="$(bash "$SCRIPT_DIR/git-ops.sh" slugify "$short")"

bug_dir="$repo_dir/docs/loop-spec/debug/$slug"
mkdir -p "$bug_dir"

default_branch="$(bash "$SCRIPT_DIR/git-ops.sh" -C "$repo_dir" detect-base-branch)"
current_branch="$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD)"

dirty=false
[[ -n "$(git -C "$repo_dir" status --porcelain)" ]] && dirty=true

# SHA before ANY debug change: the test-tamper scan's comparison baseline.
sha_before="$(git -C "$repo_dir" rev-parse --short HEAD)"

branch_action="kept"
branch="$current_branch"
if [[ "$current_branch" == "$default_branch" ]]; then
  branch="fix/$slug"
  if git -C "$repo_dir" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$repo_dir" checkout -q "$branch"
    branch_action="switched"
  else
    git -C "$repo_dir" checkout -q -b "$branch"
    branch_action="created"
  fi
fi

test_cmd="${LOOP_SPEC_CMD_TEST:-}"
if [[ -z "$test_cmd" ]]; then
  test_cmd="$(bash "$SCRIPT_DIR/detect-test-cmd.sh" "$repo_dir")"
fi

jq -cn \
  --arg slug "$slug" \
  --arg bug_dir "$bug_dir" \
  --arg branch "$branch" \
  --arg branch_action "$branch_action" \
  --arg default_branch "$default_branch" \
  --argjson dirty "$dirty" \
  --arg sha_before "$sha_before" \
  --arg test_cmd "$test_cmd" \
  --argjson autonomous "$autonomous" \
  --arg style "$style" \
  '{slug: $slug, bug_dir: $bug_dir, branch: $branch, branch_action: $branch_action,
    default_branch: $default_branch, dirty: $dirty, sha_before: $sha_before,
    test_cmd: $test_cmd, autonomous: $autonomous, style: $style}'
