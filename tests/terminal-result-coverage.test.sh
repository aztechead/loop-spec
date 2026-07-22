#!/usr/bin/env bash
# Pin common terminal result emission into every user-facing cycle type.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
PASS=0
FAIL=0

checks=(
  "skills/cycle/SKILL.md	cycle-result.sh"
  "skills/micro/SKILL.md	write-terminal"
  "skills/debug/SKILL.md	write-terminal"
  "skills/micro/SKILL.md	LOOP_SPEC_RESULT"
  "skills/debug/SKILL.md	LOOP_SPEC_RESULT"
  "lib/cycle-result.sh	cycleType: \"full\""
  "lib/cycle-result.sh	LOOP_SPEC_RESULT"
  "lib/cycle-result.sh	worktree list --porcelain"
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
