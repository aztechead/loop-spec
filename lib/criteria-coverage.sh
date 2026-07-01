#!/usr/bin/env bash
# Check that every SPEC "### Good Enough" success criterion appears in PLAN.
#
# VERIFY's deterministic acceptance gate runs the criteria recorded in PLAN.md --
# a criterion that SPEC promises but PLAN drops is therefore invisible to every
# downstream gate (VERIFY passes green, ITERATE's judge sees a green floor). This
# check closes the SPEC -> PLAN handoff the same way decision-coverage.sh closes
# the <decisions> handoff.
#
# Usage: criteria-coverage.sh <spec-path> <plan-path>
#
# Exit codes:
#   0  all Good Enough criteria covered (or no section found -- skipped)
#   1  one or more criteria not found in PLAN
#
# Prints uncovered criteria to stdout on exit 1.
# Prints "skipped: no Good Enough section" to stderr and exits 0 when absent.
# Fail-open: if SPEC cannot be read, exits 0 with a warning to stderr.
set -euo pipefail

spec_path="${1:-}"
plan_path="${2:-}"

if [[ -z "$spec_path" || -z "$plan_path" ]]; then
  echo "usage: criteria-coverage.sh <spec-path> <plan-path>" >&2
  exit 1
fi

# Read spec content -- fail-open if unreadable (covers missing files and bad FDs)
spec_content=""
if ! spec_content=$(cat "$spec_path" 2>/dev/null); then
  echo "skipped: spec file not readable: $spec_path" >&2
  exit 0
fi

# Extract the "### Good Enough" section: from that heading up to the next heading
# of any level (### Exceptional, ## next-section, ...).
criteria_block=$(echo "$spec_content" \
  | awk '/^###[[:space:]]+Good Enough/{flag=1; next} flag && /^#{1,6}[[:space:]]/{flag=0} flag' \
  || true)

# No section present -> skip
if [[ -z "$criteria_block" ]]; then
  echo "skipped: no Good Enough section in spec" >&2
  exit 0
fi

# Parse individual criteria (lines starting with "- ")
uncovered=()
while IFS= read -r line; do
  # Strip leading whitespace
  stripped="${line#"${line%%[! ]*}"}"
  [[ -z "$stripped" ]] && continue
  [[ "$stripped" != -* ]] && continue

  # Strip the bullet and an optional checkbox prefix
  entry="${stripped#- }"
  entry="${entry#\[ \] }"
  entry="${entry#\[x\] }"
  [[ -z "$entry" ]] && continue

  # Check if the criterion appears in the plan (fixed-string match)
  if ! grep -qF "$entry" "$plan_path" 2>/dev/null; then
    uncovered+=("$entry")
  fi
done <<< "$criteria_block"

if [[ ${#uncovered[@]} -eq 0 ]]; then
  exit 0
fi

echo "Uncovered Good Enough criteria:"
for item in "${uncovered[@]}"; do
  echo "  - $item"
done
exit 1
