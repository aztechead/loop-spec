#!/usr/bin/env bash
# babysit_prs.sh — keep your open PRs green and responsive, hands-off.
#
# The canonical "loop" starter. Runs Claude Code in a continuous session that watches
# your open PRs, fixes failing CI by editing code, and addresses review comments.
# Halts when no PR has a failing check, or on budget/time ceilings.
#
# Requires: claude (authenticated), gh (GitHub CLI, authenticated), a git repo.
set -euo pipefail

cd "${1:-.}"  # optional repo path as first arg

python3 "$(dirname "$0")/../loop.py" \
  "Check all my open pull requests. For each one with failing CI, read the failure,
   fix the underlying code (not the tests), and push the fix. Respond to any
   unresolved review comments by making the requested change. Use a separate git
   worktree per PR so changes don't collide. Do not merge anything." \
  --verify 'gh pr list --author @me --json statusCheckRollup \
            -q "[.[].statusCheckRollup[]? | select(.conclusion==\"FAILURE\")] | length == 0"' \
  --mode continue --task-id babysit-prs \
  --allowed-tools "Read,Edit,Bash" \
  --budget 8.00 \
  --max-iterations 20 \
  --timeout 7200 \
  --no-progress 4 \
  --commit
