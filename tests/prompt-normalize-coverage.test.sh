#!/usr/bin/env bash
# Every implementer-facing entry skill must front its input with the shared
# prompt-normalize pass, and the contract must keep the rules that make the
# pass safe: never invent, artifacts byte-for-byte, one pass per input.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
PASS=0
FAIL=0

checks=(
  $'skills/shared/prompt-normalize.md\tNormalize, never invent'
  $'skills/shared/prompt-normalize.md\tbyte-for-byte'
  $'skills/shared/prompt-normalize.md\tstay gaps - the ambiguity gate'
  $'skills/shared/prompt-normalize.md\tnon-interactive'
  $'skills/shared/prompt-normalize.md\tSPEC-shaped'
  $'skills/shared/prompt-normalize.md\tnever loop-spec output'
  $'skills/shared/prompt-normalize.md\tA normalize that finds nothing changes nothing'
  $'skills/cycle/SKILL.md\tshared/prompt-normalize.md'
  $'skills/intake/SKILL.md\tshared/prompt-normalize.md'
  $'skills/micro/SKILL.md\tshared/prompt-normalize.md'
  $'skills/debug/SKILL.md\tshared/prompt-normalize.md'
)

for entry in "${checks[@]}"; do
  file="${entry%%$'\t'*}"
  needle="${entry#*$'\t'}"
  if [[ -f "$file" ]] && grep -qF -- "$needle" "$file"; then
    PASS=$((PASS+1)); echo "PASS: $file contains '$needle'"
  else
    FAIL=$((FAIL+1)); echo "FAIL: $file missing '$needle'"
  fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
