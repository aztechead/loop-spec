#!/usr/bin/env bash
# Coverage: Superpowers EXECUTE ports are wired into dispatch templates.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
PASS=0
FAIL=0

expect() {
  local name="$1" file="$2" pattern="$3"
  if grep -qE "$pattern" "$file"; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name ($file missing /$pattern/)"
    ((FAIL++)) || true
  fi
}

count_ge() {
  local name="$1" file="$2" pattern="$3" min="$4"
  local n
  n="$(grep -cE "$pattern" "$file" || true)"
  if [[ "$n" -ge "$min" ]]; then
    echo "PASS: $name ($n)"
    ((PASS++)) || true
  else
    echo "FAIL: $name (got $n, expected >= $min)"
    ((FAIL++)) || true
  fi
}

expect "subagent writes briefs via dispatch-files" \
  skills/shared/execute-subagent.md 'dispatch-files.sh" brief'
expect "subagent reviewer uses package path" \
  skills/shared/execute-subagent.md 'dispatch-files.sh package'
expect "subagent review JSON has unverified" \
  skills/shared/execute-subagent.md 'unverified'
expect "subagent names FIX_BASE" \
  skills/shared/execute-subagent.md 'FIX_BASE'
expect "subagent names no-prejudge" \
  skills/shared/execute-subagent.md 'review-prompts/no-prejudge.md'
expect "subagent names re-review" \
  skills/shared/execute-subagent.md 'review-prompts/re-review.md'
expect "subagent names fix-loop" \
  skills/shared/execute-subagent.md 'fix-loop.sh'
expect "subagent names task-batch" \
  skills/shared/execute-subagent.md 'task-batch.sh'
count_ge "subagent writing-good-tests in the shared stanza" \
  skills/shared/execute-subagent.md 'writing-good-tests.md' 1
count_ge "subagent TDD force in the shared stanza" \
  skills/shared/execute-subagent.md 'Omitting a TDD label does not exempt' 1
count_ge "subagent no-nested in stanza and reviewer prompt" \
  skills/shared/execute-subagent.md 'NO NESTED SUBAGENTS' 2
count_ge "both implementer prompts insert the shared stanza" \
  skills/shared/execute-subagent.md 'implementer contract stanza — insert the block above' 2

expect "execute SKILL reads executeMaxRetriesPerTask from the overlay" \
  skills/execute/SKILL.md 'get executeMaxRetriesPerTask 6'
expect "execute SKILL passes the effective cap into Workflow" \
  skills/execute/SKILL.md 'maxRetriesPerTask: maxRetriesPerTask,'
expect "execute SKILL emits conflict table" \
  skills/execute/SKILL.md 'plan-conflicts.sh" table'
expect "execute SKILL classifies stop vs ruling" \
  skills/execute/SKILL.md 'execute-stop.sh" classify'
expect "execute SKILL collapses batch groups" \
  skills/execute/SKILL.md 'task-batch.sh" collapse'
expect "tier-matrix retries is 6" \
  skills/shared/tier-matrix.md 'execute.maxRetriesPerTask \| 6'

expect "named implementer disallows Agent" \
  agents/implementer.md 'disallowedTools:'
expect "named implementer lists Agent" \
  agents/implementer.md '  - Agent'
expect "spec-compliance-reviewer disallows Agent" \
  agents/spec-compliance-reviewer.md '  - Agent'
expect "code-reviewer disallows Agent" \
  agents/code-reviewer.md '  - Agent'
expect "security-reviewer disallows Agent" \
  agents/security-reviewer.md '  - Agent'

expect "planner sets mechanical only for transcription" \
  agents/planner.md 'modelTier: mechanical'
expect "planner documents batchGroup" \
  agents/planner.md 'batchGroup'
expect "team implementer names writing-good-tests" \
  skills/shared/team-prompts/implementer.md 'writing-good-tests.md'
expect "team implementer forces TDD" \
  skills/shared/team-prompts/implementer.md 'Omitting a TDD label does not exempt'
expect "named implementer forces TDD" \
  agents/implementer.md 'Omitting a TDD label does not exempt'
expect "team reviewer names unverified" \
  skills/shared/team-prompts/reviewer.md 'unverified'
expect "workflow schema includes unverified" \
  lib/workflows/execute-dag.js 'unverified'
expect "workflow implementer names writing-good-tests" \
  lib/workflows/execute-dag.js 'writing-good-tests.md'
expect "workflow implementer forces TDD" \
  lib/workflows/execute-dag.js 'Omitting a TDD label does not exempt'
# The break this catches: a "pass" carrying unverified[] merged on the last
# attempt, because `continue` alone leaves the recorded verdict at pass.
expect "workflow downgrades a pass carrying unverified" \
  lib/workflows/execute-dag.js "verdict: 'rework' \}"
expect "git-ops remove-task-worktree never --force" \
  lib/git-ops.sh 'Never --force'

# Templates the lead actually ships. Do not scan no-prejudge.md itself
# (it names the banned phrases on purpose).
TEMPLATES=(
  skills/shared/execute-subagent.md
  skills/shared/team-prompts/implementer.md
  skills/shared/team-prompts/reviewer.md
  agents/implementer.md
  agents/spec-compliance-reviewer.md
  agents/code-reviewer.md
  agents/security-reviewer.md
  lib/workflows/execute-dag.js
  skills/quality-loop/SKILL.md
  skills/verify/SKILL.md
  skills/shared/execute-inline.md
  skills/shared/execute-loops.md
)
ec=0
out=$(bash lib/prejudge-lint.sh scan "${TEMPLATES[@]}" 2>&1) || ec=$?
if [[ "$ec" -eq 0 ]]; then
  echo "PASS: prejudge-lint clean on dispatch templates"
  ((PASS++)) || true
else
  echo "FAIL: prejudge-lint on dispatch templates"
  echo "$out"
  ((FAIL++)) || true
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
