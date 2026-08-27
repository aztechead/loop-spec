#!/usr/bin/env bash
# Pin the DISCUSS grill: non-autonomous runs must still ask. execStyle auto is
# not autonomous mode, and a passed SPEC gate does not skip the design loop.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/fixed-string-coverage.sh"

checks=(
  "skills/discuss/SKILL.md	This is the in-phase grill."
  "skills/discuss/SKILL.md	\`execStyle: auto\` is not autonomous mode"
  "skills/discuss/SKILL.md	**\`auto\`:** MUST grill."
  "skills/discuss/SKILL.md	**\`step\` / \`interactive\`:** MUST grill."
  "skills/discuss/SKILL.md	**\`auto\` / \`step\` / \`interactive\`:** ask ONE targeted"
  "skills/discuss/SKILL.md	\`execStyle == \"auto\"\` is none of those."
  "skills/spec/SKILL.md	**\`execStyle: auto\` still interviews.**"
  "skills/shared/autonomous-mode.md	\`execStyle: auto\` is not this mode."
  "skills/shared/autonomous-mode.md	AskUserQuestion loop (\`auto\` included)"
  "skills/shared/autonomous-mode.md	AskUserQuestion in \`auto\`/\`step\`/\`interactive\`"
  "skills/cycle/SKILL.md	DISCUSS still runs its design-shape grill afterward"
  "skills/grill/SKILL.md	DISCUSS still runs its design-shape clarifying loop"
  "hooks/team/grill-inject.sh	Skip the grill pass **only** when"
  "hooks/team/grill-inject.sh	\`/loop-spec:cycle\` without that token is not a skip"
  "output-styles/loop-spec.md	\`style:auto\` is not autonomous mode"
  "skills/shared/report-style.md	\`style:auto\` is not autonomous mode"
  "docs/tier-guide.md	SPEC and DISCUSS still grill a human"
  "skills/iterate/SKILL.md	ITERATE re-entry; do not block an unattended loop"
)

check_fixed_strings "${checks[@]}"

# Softenings that must not return: optional grill, auto-as-skip, auto-as-autonomous.
must_not=(
  "skills/discuss/SKILL.md	you may run the normal clarifying loop"
  "skills/discuss/SKILL.md	e.g., \`execStyle == \"auto\"\` and the caller passes"
  "skills/iterate/SKILL.md	\`auto\` / \`review-only\` (autonomous):"
  "docs/tier-guide.md	plus interactive clarifying loops in SPEC/DISCUSS"
)

for entry in "${must_not[@]}"; do
  file="${entry%%	*}"
  needle="${entry#*	}"
  if [[ -f "$file" ]] && grep -qF -e "$needle" "$file"; then
    FAIL=$((FAIL+1)); echo "FAIL: $file still contains softening '$needle'"
  else
    PASS=$((PASS+1)); echo "PASS: $file dropped '$needle'"
  fi
done

finish_fixed_string_coverage
