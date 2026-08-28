#!/usr/bin/env bash
# Pin red-then-green TDD: every code-producing implementer path writes the failing
# test first. A missing TDD label in the plan does not exempt the task.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fixed-string-coverage.sh"

checks=(
  "agents/implementer.md	For every code-producing task: write the failing test FIRST"
  "agents/implementer.md	Skill/config/docs tasks are excluded"
  "agents/implementer.md	Omitting a TDD label does not exempt"
  "agents/implementer.md	Do NOT skip the failing-test step on code-producing tasks"
  "agents/planner.md	Omitting a TDD label does not exempt"
  "skills/shared/writing-good-tests.md	Code-producing tasks MUST write the failing test first"
  "skills/shared/writing-good-tests.md	Omitting a TDD label does not exempt"
  "skills/shared/writing-good-tests.md	Skill/config/docs tasks are excluded"
  "skills/shared/execute-inline.md	TDD (failing test first for every code-producing task"
  "skills/shared/team-prompts/implementer.md	Omitting a TDD label does not exempt"
  "skills/shared/execute-subagent.md	Omitting a TDD label does not exempt"
  "lib/plan-to-loop.sh	Omitting a TDD label does not exempt"
  "lib/workflows/execute-dag.js	Omitting a TDD label does not exempt"
  "docs/loop-spec/codebase/DOMAIN.md	even when the plan omits a TDD label"
)

check_fixed_strings "${checks[@]}"

sub_count="$(grep -cF 'Omitting a TDD label does not exempt' skills/shared/execute-subagent.md || true)"
marker_count="$(grep -cF "implementer contract stanza — insert the block above" skills/shared/execute-subagent.md)"
if [[ "$sub_count" -ge 1 && "$marker_count" -ge 2 ]]; then
  PASS=$((PASS+1)); echo "PASS: execute-subagent.md forces TDD on both implementer prompts ($sub_count)"
else
  FAIL=$((FAIL+1)); echo "FAIL: execute-subagent.md TDD force count $sub_count with stanza marker count $marker_count; expected >= 1 and >= 2"
fi

must_not=(
  "agents/implementer.md	If task says TDD"
  "skills/shared/execute-inline.md	the task admits one"
)

for entry in "${must_not[@]}"; do
  file="${entry%%	*}"
  needle="${entry#*	}"
  if [[ -f "$file" ]] && grep -qF -e "$needle" "$file"; then
    FAIL=$((FAIL+1)); echo "FAIL: $file still contains optional-TDD softening '$needle'"
  else
    PASS=$((PASS+1)); echo "PASS: $file dropped '$needle'"
  fi
done

finish_fixed_string_coverage
