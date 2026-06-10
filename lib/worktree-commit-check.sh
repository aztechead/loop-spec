#!/usr/bin/env bash
# lib/worktree-commit-check.sh <base_ref> <branch_ref>
#
# Assert that a worktree branch actually carries commits over its base before the
# EXECUTE lead ff-merges it. Subagents running in isolated worktrees occasionally
# fail to commit (sandbox / worktree isolation), and a silent ff-merge of a branch
# with zero new commits advances the pipeline on missing work. This guard makes
# that case loud instead of silent.
#
# Exit codes:
#   0  branch is ahead of base (>=1 commit)  -> safe to merge
#   1  branch has zero commits over base     -> implementer work did not land
#   2  bad invocation / refs not resolvable
#
# Examples:
#   worktree-commit-check.sh feat/my-slug task/task-001-my-slug
set -euo pipefail

usage() { echo "usage: worktree-commit-check.sh <base_ref> <branch_ref>" >&2; }

if [[ $# -ne 2 ]]; then
  usage
  exit 2
fi

BASE="$1"
BRANCH="$2"

# Both refs must resolve in the current repo.
for ref in "$BASE" "$BRANCH"; do
  if ! git rev-parse --verify --quiet "$ref^{commit}" >/dev/null; then
    echo "worktree-commit-check: ref not found: $ref" >&2
    exit 2
  fi
done

count="$(git rev-list --count "${BASE}..${BRANCH}")"

if [[ "$count" -eq 0 ]]; then
  echo "FAIL: $BRANCH has 0 commits over $BASE -- implementer work did not land (worktree commit missing)" >&2
  exit 1
fi

echo "OK: $BRANCH is $count commit(s) ahead of $BASE"
exit 0
