#!/usr/bin/env bash
# Every execution route must apply the same post-change grounding gate before
# validation can pass. A green command is necessary evidence, not proof that the
# implementation fits the repository.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
PASS=0
FAIL=0

checks=(
  $'skills/shared/verification-grounding.md\tGrounding gate'
  $'skills/shared/verification-grounding.md\tValidation gate'
  $'skills/shared/verification-grounding.md\tfile:line'
  $'skills/shared/verification-grounding.md\tunsupported assumption'
  $'skills/verify/SKILL.md\tshared/verification-grounding.md'
  $'skills/verify/SKILL.md\trepositoryEvidence'
  $'skills/verify/SKILL.md\tverification-grounding-lint.sh'
  $'agents/verifier.md\tshared/verification-grounding.md'
  $'agents/verifier.md\tRepository grounding'
  $'lib/workflows/templates/schemas.snippet.js\trepositoryEvidence'
  $'lib/workflows/acceptance-verify.js\trepositoryEvidence'
  $'lib/workflows/acceptance-verify.js\tgroundingPass'
  $'skills/micro/SKILL.md\tshared/verification-grounding.md'
  $'skills/micro/SKILL.md\t--grounding'
  $'skills/micro/SKILL.md\tcopy each `--criteria` value byte-for-byte'
  $'skills/micro/SKILL.md\tintegration: none - <reason of at least 10 characters>'
  $'skills/micro/SKILL.md\tfeedback-driven edit returns to Step 5'
  $'skills/debug/SKILL.md\tshared/verification-grounding.md'
  $'skills/debug/SKILL.md\tfeedback-driven edit returns to Step 4'
  $'skills/shared/artifact-templates/VERIFICATION.md.template\t## Repository grounding'
  $'lib/verification-grounding-lint.sh\tnone_re'
  $'hooks/team/micro-inject.sh\tpost-change grounding review'
  $'hooks/team/adhoc-verify-guard.sh\tcopy each --criteria value byte-for-byte'
  $'hooks/team/adhoc-verify-guard.sh\tpost-change grounding review'
  $'skills/auto/SKILL.md\tshared verification-grounding contract'
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
