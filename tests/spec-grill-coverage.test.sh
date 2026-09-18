#!/usr/bin/env bash
# Pin the compact SPEC design evaluation: inspect every mode, ask only genuine
# user-visible gaps, and keep the shared challenger gate authoritative.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fixed-string-coverage.sh"

checks=(
  $'skills/spec/SKILL.md\tLock the design in the same pass.'
  $'skills/spec/SKILL.md\t.mode.grill .mode.critique .mode.reentry'
  $'skills/spec/SKILL.md\ta passed intent'
  $'skills/spec/SKILL.md\tone consolidated'
  $'skills/spec/SKILL.md\tNever AskUserQuestion as a wait'
  $'skills/spec/SKILL.md\t`interview` is human-attended, including `execStyle: auto`'
  $'skills/shared/autonomous-mode.md\t`execStyle: auto` is not this mode.'
  $'skills/shared/autonomous-mode.md\tconsolidated AskUserQuestion questions (`auto` included)'
  $'skills/shared/autonomous-mode.md\tAskUserQuestion in `auto`/`step`/`interactive`'
  $'skills/cycle/SKILL.md\town design-lock step still runs the design-shape grill afterward'
  $'skills/settings/SKILL.md\town design-lock step still runs the design-shape clarifying loop'
  $'hooks/team/grill-inject.sh\tSkip the grill pass **only** when'
  $'hooks/team/grill-inject.sh\t`/loop-spec:cycle` without that token is not a skip'
  $'output-styles/loop-spec.md\t`style:auto` is not autonomous mode'
  $'skills/shared/report-style.md\t`style:auto` is not autonomous mode'
  $'docs/tier-guide.md\tpauses before every agent dispatch'
  $'skills/iterate/SKILL.md\tITERATE re-entry; do not block an unattended loop'
)
check_fixed_strings "${checks[@]}"

must_not=(
  $'skills/spec/SKILL.md\tsubagent_type: "loop-spec:advocate"'
  $'skills/spec/SKILL.md\tmandatory grill rounds'
  $'skills/spec/SKILL.md\texecStyle == "auto" is none of those'
  $'skills/iterate/SKILL.md\t`auto` / `review-only` (autonomous):'
)
for entry in "${must_not[@]}"; do
  file="${entry%%	*}"; needle="${entry#*	}"
  if [[ ! -f "$file" ]]; then
    FAIL=$((FAIL+1)); echo "FAIL: missing coverage target $file"
  elif grep -qF -- "$needle" "$file"; then
    FAIL=$((FAIL+1)); echo "FAIL: $file retained '$needle'"
  else
    PASS=$((PASS+1)); echo "PASS: $file dropped '$needle'"
  fi
done
finish_fixed_string_coverage
