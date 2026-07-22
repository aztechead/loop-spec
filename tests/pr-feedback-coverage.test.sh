#!/usr/bin/env bash
# Terminal PR feedback coverage: every cycle type MUST end by opening a PR and
# checking it for reviews/comments/requested changes, per the shared contract in
# skills/shared/pr-feedback-check.md — mirroring tests/design-coverage.test.sh for
# design-for-change. This pins the wiring so no flow silently regresses to
# "delivered, never looked back", and pins the concise-GFM PR body seam.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
PASS=0
FAIL=0

# file<TAB>regex(any-case) that must match at least once.
checks=(
  "skills/shared/pr-feedback-check.md	pr-feedback.sh.* check"
  "skills/shared/pr-feedback-check.md	changesRequested"
  "skills/shared/pr-feedback-check.md	loud"
  "skills/deliver/SKILL.md	pr-feedback-check"
  "skills/deliver/SKILL.md	pr-feedback.sh"
  "skills/deliver/SKILL.md	feedback persistence failed"
  "skills/cycle/SKILL.md	feedback check"
  "skills/cycle/SKILL.md	must not skip terminal feedback"
  "skills/micro/SKILL.md	pr-feedback-check"
  "skills/micro/SKILL.md	--pr"
  "skills/debug/SKILL.md	pr-feedback-check"
  "skills/debug/SKILL.md	before delegation"
  "commands/loop-debug.md	pr-feedback-check"
  "lib/pr-comments.sh	summary"
  "lib/pr-feedback.sh	observationStatus"
  "lib/adhoc-ledger.sh	--pr"
  "lib/deliver.sh	pr-body.sh"
  "lib/pr-body.sh	concise"
)

for entry in "${checks[@]}"; do
  f="${entry%%	*}"
  rx="${entry##*	}"
  if [[ ! -f "$f" ]]; then
    echo "FAIL: $f missing"; FAIL=$((FAIL+1)); continue
  fi
  if grep -qiE -- "$rx" "$f"; then
    echo "PASS: $f carries the terminal PR feedback contract (/$rx/)"; PASS=$((PASS+1))
  else
    echo "FAIL: $f does NOT carry the terminal PR feedback contract (/$rx/) -- a cycle type lost its ending"
    FAIL=$((FAIL+1))
  fi
done

# The shared contract must name every cycle type it binds; a new flow that opens PRs
# should be added to this table (and to the checks above).
for flow in cycle micro debug revise; do
  if grep -qE "loop-spec:${flow}" skills/shared/pr-feedback-check.md; then
    echo "PASS: pr-feedback-check.md names /loop-spec:${flow}"
    PASS=$((PASS+1))
  else
    echo "FAIL: pr-feedback-check.md does not name /loop-spec:${flow}"
    FAIL=$((FAIL+1))
  fi
done

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "PASS: terminal PR feedback check wired into every cycle type"
