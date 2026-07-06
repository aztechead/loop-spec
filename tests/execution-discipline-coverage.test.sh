#!/usr/bin/env bash
# Execution-discipline coverage: the "evidence over recall" directive MUST be present in
# every EXECUTE/VERIFY dispatch path, mirroring tests/ponytail-coverage.test.sh and
# tests/design-coverage.test.sh. The directive encodes frontier-model execution habits
# (verify don't recall, surprise is signal, re-read the contract before DONE, depth over
# breadth, artifacts over memory, NEEDS_CONTEXT over confident guessing) for the
# mid-tier models (sonnet/opus) that actually run those phases.
#
# This is the enforcement that keeps the wiring from silently regressing.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
PASS=0
FAIL=0

# file<TAB>regex(any-case) that must match at least once.
checks=(
  "skills/shared/execution-discipline.md	evidence over recall"
  "skills/shared/execution-discipline.md	surprise is signal"
  "skills/shared/execution-discipline.md	NEEDS_CONTEXT"
  "agents/implementer.md	evidence over recall"
  "agents/verifier.md	evidence over recall"
  "skills/shared/team-prompts/implementer.md	evidence over recall"
  "skills/shared/execute-subagent.md	evidence over recall"
  "lib/plan-to-loop.sh	evidence over recall"
  "lib/workflows/execute-dag.js	evidence over recall"
)

for entry in "${checks[@]}"; do
  f="${entry%%	*}"
  rx="${entry##*	}"
  if [[ ! -f "$f" ]]; then
    echo "FAIL: $f missing"; FAIL=$((FAIL+1)); continue
  fi
  if grep -qiE "$rx" "$f"; then
    echo "PASS: $f carries execution discipline (/$rx/)"; PASS=$((PASS+1))
  else
    echo "FAIL: $f does NOT carry execution discipline (/$rx/) -- a dispatch path lost the directive"
    FAIL=$((FAIL+1))
  fi
done

# The EXECUTE subagent rung dispatches TWO implementer prompts (single-repo + workspace);
# both must carry the directive, same as the ladder requirement.
sub_count="$(grep -ciE "evidence over recall" skills/shared/execute-subagent.md)"
if [[ "$sub_count" -ge 2 ]]; then
  echo "PASS: execute-subagent.md covers both implementer prompts ($sub_count occurrences)"
  PASS=$((PASS+1))
else
  echo "FAIL: execute-subagent.md has $sub_count execution-discipline occurrences; expected >= 2 (single-repo + workspace prompts)"
  FAIL=$((FAIL+1))
fi

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "PASS: execution-discipline directive present in every EXECUTE/VERIFY dispatch path"
