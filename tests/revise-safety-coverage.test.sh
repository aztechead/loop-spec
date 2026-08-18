#!/usr/bin/env bash
# Contract coverage for the user-facing /revise procedure.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0
expect() {
  local label="$1" file="$2" text="$3"
  if grep -Fq -- "$text" "$ROOT/$file"; then
    echo "PASS: $label"; PASS=$((PASS + 1))
  else
    echo "FAIL: $label"; FAIL=$((FAIL + 1))
  fi
}
absent() {
  local label="$1" file="$2" text="$3"
  if grep -Fq -- "$text" "$ROOT/$file"; then
    echo "FAIL: $label"; FAIL=$((FAIL + 1))
  else
    echo "PASS: $label"; PASS=$((PASS + 1))
  fi
}

expect "revise delegates branch reconciliation" skills/revise/SKILL.md 'lib/revise-branch.sh'
expect "revise prepares branch before feature state" skills/revise/SKILL.md 'Step 3.5 - Feature runtime state (only after preparation succeeds)'
expect "revise documents local-ahead reconciliation" skills/revise/SKILL.md 'pushed normally'
expect "revise keeps runtime state out of commits" skills/revise/SKILL.md 'never include `.loop-spec/*` runtime'
expect "revise isolates runtime state before reconstruction" skills/revise/SKILL.md 'lib/revise-state.sh'
expect "revise does not reconstruct feature.json in prose" skills/revise/SKILL.md 'Do **not** reconstruct'
absent "revise no longer hand-builds a reconstructed skeleton" skills/revise/SKILL.md 'reconstructed: true'
expect "revise honors bot CHANGES_REQUESTED reviews" skills/revise/SKILL.md 'CHANGES_REQUESTED'
expect "revise cleanup removes only owned worktrees" skills/revise/SKILL.md 'owned == true'
expect "helper reports isolation and owned" lib/revise-branch.sh 'isolation:$isolation,owned:$owned'
absent "revise no longer force-resets branch" skills/revise/SKILL.md 'git -C "$revision_root" checkout -B'
expect "helper refuses true divergence" lib/revise-branch.sh 'unique commits; refusing to rewrite either history'
expect "helper uses ordinary push for local-ahead" lib/revise-branch.sh 'push origin "refs/heads/$branch:refs/heads/$branch"'
expect "helper uses fast-forward only for remote-ahead" lib/revise-branch.sh 'merge --ff-only "origin/$branch"'

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
