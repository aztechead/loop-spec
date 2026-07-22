#!/usr/bin/env bash
# Pin the semantic autonomous router across its prompt, validator, harness docs,
# SDK examples, and machine-readable output.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
PASS=0
FAIL=0

checks=(
  "skills/auto/SKILL.md	lib/task-route.sh"
  "skills/auto/SKILL.md	Skill(loop-spec:micro)"
  "skills/auto/SKILL.md	Skill(loop-spec:debug)"
  "skills/auto/SKILL.md	Skill(loop-spec:cycle)"
  "skills/auto/SKILL.md	AUTONOMOUS_ROUTE"
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
  "skills/shared/pi-harness.md	/skill:auto"
  "skills/shared/opencode-harness.md	loop-spec-auto"
  "README.md	/loop-spec:auto"
  "README.md	AUTONOMOUS_ROUTE"
)

for entry in "${checks[@]}"; do
  file="${entry%%	*}"
  needle="${entry#*	}"
  if [[ -f "$file" ]] && grep -qF -- "$needle" "$file"; then
    PASS=$((PASS+1)); echo "PASS: $file contains '$needle'"
  else
    FAIL=$((FAIL+1)); echo "FAIL: $file missing '$needle'"
  fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
