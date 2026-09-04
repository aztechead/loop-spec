#!/usr/bin/env bash
# Pin the approach contract to design, dispatch, and review entry points.
# These checks protect prompt wiring; they do not measure model judgment.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fixed-string-coverage.sh"

checks=(
  "skills/spec/SKILL.md	shared/approach-selection.md"
  "skills/discuss/SKILL.md	shared/approach-selection.md"
  "skills/plan/SKILL.md	shared/approach-selection.md"
  "agents/spec-writer.md	shared/approach-selection.md"
  "agents/planner.md	shared/approach-selection.md"
  "agents/iterate-judge.md	shared/approach-selection.md"
  "agents/code-reviewer.md	shared/approach-selection.md"
  "skills/shared/engineering-directives.md	shared/approach-selection.md"
  "skills/shared/prompt-normalize.md	Preserve suggested methods"
  "skills/shared/approach-selection.md	Explicit constraints remain binding"
  "skills/shared/approach-selection.md	Never lower acceptance criteria"
  "skills/shared/approach-selection.md	No new evidence means no reopening"
  "skills/shared/approach-selection.md	PLAN.md and tasks.json"
  "skills/shared/approach-selection.md	Best practice alone is not evidence"
)

check_fixed_strings "${checks[@]}"
finish_fixed_string_coverage
