#!/usr/bin/env bash
# Dispatch-telemetry coverage: every dispatch path MUST carry the `dispatch`
# event emission directive (skills/shared/dispatch-events.md), mirroring
# tests/design-coverage.test.sh for the design-for-change directive. Without
# this enforcement the events.jsonl dispatch record silently rots and
# `/loop-spec:status --stats` loses its model/role accounting.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
PASS=0
FAIL=0

# file<TAB>regex(any-case) that must match at least once.
checks=(
  "skills/shared/dispatch-events.md	dispatch telemetry contract"
  "skills/shared/dispatch-events.md	one event per agent launched"
  "skills/discuss/SKILL.md	dispatch-events.md"
  "skills/plan/SKILL.md	dispatch-events.md"
  "skills/execute/SKILL.md	dispatch-events.md"
  "skills/verify/SKILL.md	dispatch-events.md"
  "skills/iterate/SKILL.md	dispatch-events.md"
  "skills/map-codebase/SKILL.md	dispatch-events.md"
  "skills/shared/execute-subagent.md	dispatch-events.md"
  "skills/shared/execute-loop-fleet.md	dispatch-events.md"
  "lib/events.sh	dispatch          - an agent was launched"
)

for entry in "${checks[@]}"; do
  f="${entry%%	*}"
  rx="${entry##*	}"
  if [[ ! -f "$f" ]]; then
    echo "FAIL: $f missing"; FAIL=$((FAIL+1)); continue
  fi
  if grep -qiE "$rx" "$f"; then
    echo "PASS: $f carries dispatch telemetry (/$rx/)"; PASS=$((PASS+1))
  else
    echo "FAIL: $f does NOT carry dispatch telemetry (/$rx/) -- a dispatch path lost the directive"
    FAIL=$((FAIL+1))
  fi
done

# gate_round must actually be emitted by both critique gates (it was a canonical
# name with zero emitters before this suite existed).
for f in skills/discuss/SKILL.md skills/plan/SKILL.md; do
  if grep -qE "events.sh\" emit .* gate_round" "$f"; then
    echo "PASS: $f emits gate_round"; PASS=$((PASS+1))
  else
    echo "FAIL: $f does not emit gate_round (critique-gate telemetry lost)"
    FAIL=$((FAIL+1))
  fi
done

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "PASS: dispatch telemetry directive present in every dispatch path"
