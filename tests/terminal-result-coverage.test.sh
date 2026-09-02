#!/usr/bin/env bash
# Pin common terminal result emission into every user-facing cycle type.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fixed-string-coverage.sh"

checks=(
  "lib/cycle-driver.sh	cycle-result write"
  "skills/micro/SKILL.md	write-terminal"
  "skills/debug/SKILL.md	write-terminal"
  "skills/micro/SKILL.md	LOOP_SPEC_RESULT"
  "skills/debug/SKILL.md	LOOP_SPEC_RESULT"
  "skills/forensics/SKILL.md	write-terminal"
  "skills/assess/SKILL.md	write-terminal"
  "skills/retro/SKILL.md	write-terminal"
  "skills/shared/route-exit-contract.md	--summary"
  "lib/cycle-driver.sh	already-satisfied"
  "skills/micro/SKILL.md	--summary"
  "skills/debug/SKILL.md	--summary"
  "skills/forensics/SKILL.md	diagnostic-only"
  "skills/assess/SKILL.md	diagnostic-only"
  "skills/retro/SKILL.md	diagnostic-only"
  "lib/cycle-result.sh	cycleType: \"full\""
  "lib/cycle-result.sh	active-run.json"
  "lib/cycle-reconcile.sh	write-terminal"
  "lib/cycle-reconcile.sh	checkpoint-pr.sh"
  "lib/cycle-result.sh	--outcome delivered"
  "lib/cycle-result.sh	Cycle completed; PR delivered."
  "lib/cycle-reconcile.sh	a PR was delivered"
  "lib/cycle-result.sh	LOOP_SPEC_RESULT"
  "lib/cycle-driver.sh	retrying once"
  "lib/cycle-result.sh	noChangeReason"
  "lib/cycle-result.sh	no-change-needed"
  "lib/cycle-result.sh	worktree list --porcelain"
  "lib/cycle-result.sh	delivery-blocked"
  "lib/cycle-result.sh	implementationConverged"
  "lib/cycle-result.sh	workDelivered"
  "lib/cycle-result.sh	delivered-draft"
  "lib/cycle-result.sh	delivery-reconcile.sh"
  "docs/loop-spec/agent-output-contract.md	workDelivered"
  "docs/loop-spec/agent-output-contract.md	delivered-draft"
  "lib/events.sh	LOOP_SPEC_PHASE_START"
  "lib/events.sh	LOOP_SPEC_PHASE_END"
  # The route-exit contract: every route publishes a terminal result, including the
  # one that declines a genuine non-task. A route that exits without one is the
  # false-negative failure this pins shut. Declining accepted repository work as
  # protocol-mismatch is the complementary failure (v4.2.1).
  "skills/shared/route-exit-contract.md	protocol-mismatch"
  "skills/shared/route-exit-contract.md	genuine **non-task**"
  "skills/shared/route-exit-contract.md	ITERATE and DELIVER included"
  "skills/auto/SKILL.md	route-exit-contract.md"
  "skills/auto/SKILL.md	cycle-reconcile.sh"
  "skills/auto/SKILL.md	executed, not declined"
  "skills/cycle/SKILL.md	protocol-mismatch"
  "skills/cycle/SKILL.md	genuinely not repository work"
  "skills/cycle/SKILL.md	never skips ITERATE or DELIVER"
  "skills/micro/SKILL.md	protocol-mismatch"
  "skills/micro/SKILL.md	not repository work at all"
  "skills/debug/SKILL.md	protocol-mismatch"
  "skills/debug/SKILL.md	not repository work at all"
  "lib/cycle-result.sh	protocol-mismatch"
  "lib/task-route.sh	arm_route"
  "hooks/hooks.json	route-terminal-guard.sh"
  "hooks/team/route-terminal-guard.sh	LOOP_SPEC_ROUTE_GUARD"
  "hooks/team/route-terminal-guard.sh	Do not use this to decline"
  "docs/loop-spec/agent-output-contract.md	not declined"
)

check_fixed_strings "${checks[@]}"

# v3.0.1 invited the model to decline a rebase/sync/chore as protocol-mismatch.
# Those examples must not return: they are the v4.2.1 complementary failure.
for entry in \
  "skills/cycle/SKILL.md	that judgment is a finding to report" \
  "skills/auto/SKILL.md	judges its protocol a poor fit must publish" \
  "skills/shared/route-exit-contract.md	Stopping is the point"
do
  file="${entry%%	*}"
  needle="${entry#*	}"
  if [[ -f "$file" ]] && grep -qF -e "$needle" "$file"; then
    FAIL=$((FAIL+1)); echo "FAIL: $file still invites mismatch with '$needle'"
  else
    PASS=$((PASS+1)); echo "PASS: $file no longer contains '$needle'"
  fi
done

finish_fixed_string_coverage
