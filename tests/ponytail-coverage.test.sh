#!/usr/bin/env bash
# Ponytail coverage: the laziness-ladder directive MUST be present in every code-producing
# phase dispatch path, so the discipline is followed every time -- not only on the main
# thread (SessionStart hook) but inside each dispatched implementer / planner / reviewer,
# which a SessionStart hook does NOT reach.
#
# Relevant phases (skills/simplicity/SKILL.md "Relationship to the cycle"):
#   PLAN/planner, EXECUTE/implementer (team + subagent + loop-fleet rungs), VERIFY/code-reviewer.
#
# This is the enforcement that keeps the wiring from silently regressing.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
PASS=0
FAIL=0

# file<TAB>regex(any-case) that must match at least once.
checks=(
  "skills/shared/laziness-ladder.md	laziness ladder"
  "agents/planner.md	laziness ladder"
  "agents/implementer.md	laziness ladder"
  "agents/code-reviewer.md	(ponytail|over-engineering pass)"
  "skills/shared/team-prompts/implementer.md	(laziness ladder|ponytail)"
  "skills/shared/execute-subagent.md	ponytail laziness ladder"
  "lib/plan-to-loop.sh	ponytail laziness ladder"
  "lib/workflows/execute-dag.js	ponytail laziness ladder"
)

for entry in "${checks[@]}"; do
  f="${entry%%	*}"
  rx="${entry##*	}"
  if [[ ! -f "$f" ]]; then
    echo "FAIL: $f missing"; FAIL=$((FAIL+1)); continue
  fi
  if grep -qiE "$rx" "$f"; then
    echo "PASS: $f carries the ladder (/$rx/)"; PASS=$((PASS+1))
  else
    echo "FAIL: $f does NOT carry the ponytail ladder (/$rx/) -- a dispatch path lost the directive"
    FAIL=$((FAIL+1))
  fi
done

# The EXECUTE subagent rung dispatches TWO implementer prompts (single-repo + workspace);
# both must carry the directive. Require >= 2 ladder occurrences in that file.
sub_count="$(grep -ciE "ponytail laziness ladder" skills/shared/execute-subagent.md)"
if [[ "$sub_count" -ge 2 ]]; then
  echo "PASS: execute-subagent.md covers both implementer prompts ($sub_count occurrences)"
  PASS=$((PASS+1))
else
  echo "FAIL: execute-subagent.md has $sub_count ladder occurrences; expected >= 2 (single-repo + workspace prompts)"
  FAIL=$((FAIL+1))
fi

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "PASS: ponytail ladder present in every relevant-phase dispatch path"
