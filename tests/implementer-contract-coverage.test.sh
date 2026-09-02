#!/usr/bin/env bash
# Pin the four-questions design gate: every code-producing dispatch surface names
# skills/shared/implementer-contract.md and asks modular / extensible / least code / scale.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fixed-string-coverage.sh"

checks=(
  "skills/shared/implementer-contract.md	FOUR QUESTIONS (design gate — on by default)"
  "skills/shared/implementer-contract.md	more modular"
  "skills/shared/implementer-contract.md	least amount of code that makes it happen"
  "skills/shared/implementer-contract.md	Does this hold at production scale"
  "skills/shared/execute-subagent.md	implementer-contract.md"
  "skills/shared/execute-subagent.md	least amount of code that makes it happen"
  "skills/shared/execute-subagent.md	does this hold at production scale"
  "skills/shared/team-prompts/implementer.md	implementer-contract.md"
  "skills/shared/team-prompts/implementer.md	more modular"
  "skills/shared/team-prompts/implementer.md	does this hold at production scale"
  "agents/implementer.md	implementer-contract.md"
  "agents/implementer.md	more modular"
  "agents/implementer.md	does this hold at production scale"
  "skills/shared/execute-rungs.md	implementer-contract.md"
  "skills/shared/execute-rungs.md	more modular"
  "skills/shared/execute-rungs.md	does this hold at"
  "lib/plan-to-loop.sh	implementer-contract.md"
  "lib/plan-to-loop.sh	more modular"
  "lib/plan-to-loop.sh	hold at production scale"
  "lib/workflows/execute-dag.js	implementer-contract.md"
  "lib/workflows/execute-dag.js	more modular"
  "lib/workflows/execute-dag.js	hold at production "
  "skills/execute/SKILL.md	implementer-contract.md"
  "skills/execute/SKILL.md	does this hold at production scale"
  "agents/code-reviewer.md	scale:"
  "agents/challenger.md	Does this scale"
)

check_fixed_strings "${checks[@]}"

# Both subagent prompt templates (single-repo + workspace) must carry the gate.
sub_count="$(grep -cF "FOUR QUESTIONS (design gate" skills/shared/execute-subagent.md)"
marker_count="$(grep -cF "implementer contract stanza — insert the block above" skills/shared/execute-subagent.md)"
if [[ "$sub_count" -ge 1 && "$marker_count" -ge 2 ]]; then
  PASS=$((PASS+1)); echo "PASS: execute-subagent.md carries the gate in both prompts ($sub_count occurrences)"
else
  FAIL=$((FAIL+1)); echo "FAIL: execute-subagent.md has $sub_count four-questions occurrences; expected stanza >= 1 and both prompts inserting it (marker >= 2)"
fi

finish_fixed_string_coverage
