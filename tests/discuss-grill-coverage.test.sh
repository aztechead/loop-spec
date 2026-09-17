#!/usr/bin/env bash
# Pin the compact DISCUSS design evaluation: inspect every mode, ask only genuine
# user-visible gaps, and keep the shared challenger gate authoritative.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fixed-string-coverage.sh"

checks=(
  $'skills/discuss/SKILL.md\tThis is the in-phase design evaluation.'
  $'skills/discuss/SKILL.md\tHuman questioning is governed by `mode.grill`'
  $'skills/discuss/SKILL.md\tA passed SPEC'
  $'skills/discuss/SKILL.md\tone consolidated'
  $'skills/discuss/SKILL.md\tNever AskUserQuestion as a wait'
  $'skills/spec/SKILL.md\t`interview` is human-attended, including `execStyle: auto`'
  $'skills/shared/autonomous-mode.md\t`execStyle: auto` is not this mode.'
  $'skills/shared/autonomous-mode.md\tconsolidated AskUserQuestion questions (`auto` included)'
  $'skills/shared/autonomous-mode.md\tAskUserQuestion in `auto`/`step`/`interactive`'
  $'skills/cycle/SKILL.md\tDISCUSS still runs its design-shape grill afterward'
  $'skills/settings/SKILL.md\tDISCUSS still runs its design-shape clarifying loop'
  $'hooks/team/grill-inject.sh\tSkip the grill pass **only** when'
  $'hooks/team/grill-inject.sh\t`/loop-spec:cycle` without that token is not a skip'
  $'output-styles/loop-spec.md\t`style:auto` is not autonomous mode'
  $'skills/shared/report-style.md\t`style:auto` is not autonomous mode'
  $'docs/tier-guide.md\tpauses before every agent dispatch'
  $'skills/iterate/SKILL.md\tITERATE re-entry; do not block an unattended loop'
)
check_fixed_strings "${checks[@]}"

must_not=(
  $'skills/discuss/SKILL.md\tsubagent_type: "loop-spec:advocate"'
  $'skills/discuss/SKILL.md\tmandatory grill rounds'
  $'skills/discuss/SKILL.md\texecStyle == "auto" is none of those'
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
