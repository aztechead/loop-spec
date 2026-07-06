#!/usr/bin/env bash
# Design-for-change coverage: the "seams, not speculation" directive MUST be present in
# every design- and code-producing dispatch path, mirroring tests/ponytail-coverage.test.sh
# for the laziness ladder. The directive codifies: design to an interface not an
# implementation, separation of concerns, dependency injection over deep construction,
# seams placed where change is likely (without speculative artifacts), the corner test,
# and the sibling sweep after a confirmed root-cause fix.
#
# This is the enforcement that keeps the wiring from silently regressing.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
PASS=0
FAIL=0

# file<TAB>regex(any-case) that must match at least once.
checks=(
  "skills/shared/design-for-change.md	seams, not speculation"
  "skills/shared/design-for-change.md	sibling sweep"
  "skills/shared/design-for-change.md	corner test"
  "agents/planner.md	seams, not speculation"
  "agents/challenger.md	(corner test|designed into a corner)"
  "agents/code-reviewer.md	design-for-change pass"
  "agents/implementer.md	seams, not speculation"
  "skills/discuss/SKILL.md	corner question"
  "skills/debug/SKILL.md	sibling sweep"
  "commands/loop-debug.md	sibling sweep"
  "skills/shared/team-prompts/implementer.md	seams, not speculation"
  "skills/shared/execute-subagent.md	seams, not speculation"
  "lib/plan-to-loop.sh	seams, not speculation"
  "lib/workflows/execute-dag.js	seams, not speculation"
  "skills/shared/laziness-ladder.md	seam"
  "skills/simplicity/SKILL.md	seam"
  "hooks/team/simplicity-inject.sh	seam"
  "CLAUDE.md	seams, not speculation"
)

for entry in "${checks[@]}"; do
  f="${entry%%	*}"
  rx="${entry##*	}"
  if [[ ! -f "$f" ]]; then
    echo "FAIL: $f missing"; FAIL=$((FAIL+1)); continue
  fi
  if grep -qiE "$rx" "$f"; then
    echo "PASS: $f carries design-for-change (/$rx/)"; PASS=$((PASS+1))
  else
    echo "FAIL: $f does NOT carry design-for-change (/$rx/) -- a dispatch path lost the directive"
    FAIL=$((FAIL+1))
  fi
done

# The EXECUTE subagent rung dispatches TWO implementer prompts (single-repo + workspace);
# both must carry the directive, same as the ladder requirement.
sub_count="$(grep -ciE "seams, not speculation" skills/shared/execute-subagent.md)"
if [[ "$sub_count" -ge 2 ]]; then
  echo "PASS: execute-subagent.md covers both implementer prompts ($sub_count occurrences)"
  PASS=$((PASS+1))
else
  echo "FAIL: execute-subagent.md has $sub_count design-for-change occurrences; expected >= 2 (single-repo + workspace prompts)"
  FAIL=$((FAIL+1))
fi

# The debug loop's sibling sweep is a mandatory step with its own BUG.md section: a
# confirmed root cause is rarely alone, and same-cause siblings land in the same change.
if grep -qiE '## Sibling sweep' skills/debug/SKILL.md; then
  echo "PASS: skills/debug/SKILL.md carries the BUG.md '## Sibling sweep' section"
  PASS=$((PASS+1))
else
  echo "FAIL: skills/debug/SKILL.md BUG.md format lacks the '## Sibling sweep' section"
  FAIL=$((FAIL+1))
fi

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "PASS: design-for-change directive present in every relevant dispatch path"
