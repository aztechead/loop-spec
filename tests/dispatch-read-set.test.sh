#!/usr/bin/env bash
# dispatch-read-set.test.sh - The bytes a fresh dispatch reads before it can act stay
# under a ceiling, like the test wall clock in run-all.sh.
#
# Why: every implementer and reviewer dispatch starts from zero and reads its agent
# file plus every contract it cites, on every task and every rework attempt. The
# 6.5.0 cycle here paid that for 12 tasks, twice each. The ceilings sit within 5% of
# the 6.9.0 measurement; a red run is a finding to fix (cut, cite a section, or move
# a rule into the brief), never a number to raise.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
check() {
  local name="$1" ceiling="$2" actual="$3"
  if (( actual <= ceiling )); then echo "PASS: $name ($actual <= $ceiling bytes)"; ((PASS++)) || true
  else echo "FAIL: $name ($actual > $ceiling bytes)"; ((FAIL++)) || true; fi
}
# The shared docs a document names, by basename, summed with the document itself.
read_set() {
  local doc="$1" total; total=$(wc -c < "$doc")
  for name in $(grep -oE 'shared/[a-z0-9-]+\.md' "$doc" | sed 's#shared/##' | sort -u); do
    [[ -f "$ROOT/skills/shared/$name" ]] && total=$((total + $(wc -c < "$ROOT/skills/shared/$name")))
  done
  echo "$total"
}
# The stanza block alone: the eight sources the subagent rung names before any task text.
stanza="$(awk '/^## Implementer contract stanza/{f=1} /^## Implementer Agent prompt/{f=0} f' "$ROOT/skills/shared/execute-subagent.md")"
stanza_total=0
for name in $(grep -oE 'shared/[a-z0-9-]+\.md' <<<"$stanza" | sed 's#shared/##' | sort -u); do
  stanza_total=$((stanza_total + $(wc -c < "$ROOT/skills/shared/$name")))
done
check "subagent-rung stanza sources"  61440 "$stanza_total"
check "agents/implementer.md + cites" 77824 "$(read_set "$ROOT/agents/implementer.md")"
check "agents/code-reviewer.md + cites" 79872 "$(read_set "$ROOT/agents/code-reviewer.md")"
check "agents/spec-writer.md + cites" 53248 "$(read_set "$ROOT/agents/spec-writer.md")"
check "agents/planner.md + cites" 49152 "$(read_set "$ROOT/agents/planner.md")"
echo "Results: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
