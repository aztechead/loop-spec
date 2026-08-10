#!/usr/bin/env bash
# Plain-language coverage: the readability directive MUST be referenced by every
# prose-producing agent, mirroring tests/human-code-coverage.test.sh for the
# code-for-humans directive. Wiring the reference into ten agent files and then
# letting skills/shared/plain-language.md quietly drift is the same failure mode
# human-code-coverage.test.sh guards against for code: a reference that survives
# while the contract behind it is hollowed out is worse than no reference, because
# it reads as enforced when it is not.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
PASS=0
FAIL=0

# Every prose-producing agent must point at the shared contract, never restate it.
agents=(
  agents/spec-writer.md
  agents/planner.md
  agents/verifier.md
  agents/pattern-mapper.md
  agents/challenger.md
  agents/advocate.md
  agents/code-reviewer.md
  agents/iterate-judge.md
  agents/implementer.md
  agents/spec-compliance-reviewer.md
)

for f in "${agents[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "FAIL: $f missing"; FAIL=$((FAIL+1)); continue
  fi
  if grep -qF "skills/shared/plain-language.md" "$f"; then
    echo "PASS: $f references skills/shared/plain-language.md"; PASS=$((PASS+1))
  else
    echo "FAIL: $f does NOT reference skills/shared/plain-language.md -- an agent lost the directive"
    FAIL=$((FAIL+1))
  fi
done

# The contract itself must not be hollowed out while the references survive: these
# three clauses are the ones a quiet edit could strip without breaking any grep above.
contract="skills/shared/plain-language.md"
checks=(
  "STE-informed"
  "makes \*\*no claim of conformance\*\*"
  "Rule 6 is the escape hatch"
)
for rx in "${checks[@]}"; do
  if grep -qE "$rx" "$contract"; then
    echo "PASS: $contract carries key clause (/$rx/)"; PASS=$((PASS+1))
  else
    echo "FAIL: $contract lost key clause (/$rx/)"; FAIL=$((FAIL+1))
  fi
done

# Rules 3 and 6 are explicitly not machine-checked; the contract must keep saying so.
if grep -qE '\| 3 \|.*\*\*No\.\*\*' "$contract" && grep -qE '\| 6 \|.*\*\*No, and never will be\.\*\*' "$contract"; then
  echo "PASS: $contract states rules 3 and 6 are not machine-checked"; PASS=$((PASS+1))
else
  echo "FAIL: $contract lost the 'rules 3 and 6 are not machine-checked' statement"
  FAIL=$((FAIL+1))
fi

# Copyright note: no reproduction of ASD-STE100's dictionary, no conformance claim.
if grep -qF "ASD-STE100" "$contract" && grep -qF "reproduce its approved-word dictionary" "$contract"; then
  echo "PASS: $contract carries the copyright note"; PASS=$((PASS+1))
else
  echo "FAIL: $contract lost the ASD-STE100 copyright note"; FAIL=$((FAIL+1))
fi

# The directive must be advisory-only in the agents that carry it: it must not read
# as a gate anywhere it is referenced.
for f in "${agents[@]}"; do
  [[ -f "$f" ]] || continue
  if grep -qiE "advisory" "$f"; then
    echo "PASS: $f marks the directive advisory, not a gate"; PASS=$((PASS+1))
  else
    echo "FAIL: $f references the contract without marking it advisory -- reads as a gate"
    FAIL=$((FAIL+1))
  fi
done

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
echo "PASS: plain-language directive present in every prose-producing agent"
