#!/usr/bin/env bash
# Pin the semantic autonomous router across its prompt, validator, harness docs,
# SDK examples, and machine-readable output.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fixed-string-coverage.sh"

checks=(
  "skills/auto/SKILL.md	lib/task-route.sh"
  "skills/auto/SKILL.md	Skill(loop-spec:micro)"
  "skills/auto/SKILL.md	Skill(loop-spec:debug)"
  "skills/auto/SKILL.md	Skill(loop-spec:cycle)"
  "skills/auto/SKILL.md	AUTONOMOUS_ROUTE"
  "skills/auto/SKILL.md	merge-conflict resolution"
  "skills/auto/SKILL.md	profile:{profile}"
  "skills/micro/SKILL.md	model: inherit"
  "lib/task-route.sh	invalid-classification"
  "lib/task-route.sh	micro-requires-low-ambiguity"
  "lib/task-route.sh	debug-task-kind-mismatch"
  "lib/task-route.sh	workingTreeConflict"
  "skills/micro/SKILL.md	autonomous runs (inline"
  "skills/micro/SKILL.md	brief so intake"
  "skills/debug/SKILL.md	with the path, hand off"
  "hooks/team/grill-inject.sh	/loop-spec:auto"
  "hooks/team/micro-inject.sh	/loop-spec:auto"
  "skills/shared/autonomous-mode.md	/loop-spec:auto"
  "skills/shared/autonomous-mode.md	loop-spec-auto"
  "skills/shared/adk-harness.md	adk run"
  "skills/shared/opencode-harness.md	loop-spec-auto"
  "README.md	/loop-spec:auto"
  "README.md	AUTONOMOUS_ROUTE"
  "skills/shared/adk-harness.md	route-terminal-guard.sh"
  "skills/shared/opencode-harness.md	route-terminal-guard.sh"
)

check_fixed_strings "${checks[@]}"

finish_fixed_string_coverage
