#!/usr/bin/env bash
# Check that every <decisions> entry in SPEC appears in PLAN.
#
# Usage: decision-coverage.sh <spec-path> <plan-path>
#
# An entry is covered when its statement -- the text before a "Rationale:" or
# "Alternatives considered:" clause -- appears in PLAN.md as a fixed string,
# whitespace-normalized. The rationale is the spec's to keep; the plan carries the
# decision. A haiku planner paraphrased five entries three times and escalated because
# the flag listed the entries without saying that only a verbatim copy counts.
#
# Exit codes:
#   0  all entries covered (or no <decisions> block found -- skipped)
#   1  one or more entries not found in PLAN
#
# Prints uncovered statements to stdout on exit 1, under a heading that says how to
# cover them.
# Prints "skipped: no <decisions> block" to stderr and exits 0 when block absent.
# Fail-open: if SPEC cannot be read, exits 0 with a warning to stderr.
set -euo pipefail

spec_path="${1:-}"
plan_path="${2:-}"

if [[ -z "$spec_path" || -z "$plan_path" ]]; then
  echo "usage: decision-coverage.sh <spec-path> <plan-path>" >&2
  exit 1
fi

# Read spec content -- fail-open if unreadable (covers missing files and bad FDs)
spec_content=""
if ! spec_content=$(cat "$spec_path" 2>/dev/null); then
  echo "skipped: spec file not readable: $spec_path" >&2
  exit 0
fi

# Extract the <decisions>...</decisions> block
decisions_block=$(echo "$spec_content" \
  | awk '/<decisions>/,/<\/decisions>/' \
  | grep -v '<decisions>' \
  | grep -v '</decisions>' \
  || true)

# No block present -> skip
if [[ -z "$decisions_block" ]]; then
  echo "skipped: no <decisions> block in spec" >&2
  exit 0
fi

# Parse individual decision entries (lines starting with "- ")
# Whitespace-normalized plan content: a decision reflowed across lines in PLAN.md
# must still count as covered (the match is semantic identity, not line layout).
plan_norm="$(tr -s '[:space:]' ' ' < "$plan_path" 2>/dev/null || true)"

uncovered=()
while IFS= read -r line; do
  # Strip leading whitespace
  stripped="${line#"${line%%[! ]*}"}"
  [[ -z "$stripped" ]] && continue
  [[ "$stripped" != -* ]] && continue

  # Strip the bullet and optional "Decision: " prefix
  entry="${stripped#- }"
  entry="${entry#Decision: }"
  entry="${entry#decision: }"
  [[ -z "$entry" ]] && continue

  # The statement ends where the rationale begins.
  statement="$(printf '%s' "$entry" | sed -E 's/[[:space:]]*(\*\*)?(Rationale|Alternatives considered):.*$//I')"
  [[ -n "$statement" ]] || statement="$entry"

  # Fixed-string match on whitespace-normalized text (both sides)
  statement_norm="$(printf '%s' "$statement" | tr -s '[:space:]' ' ')"
  if [[ "$plan_norm" != *"$statement_norm"* ]]; then
    uncovered+=("$statement")
  fi
done <<< "$decisions_block"

if [[ ${#uncovered[@]} -eq 0 ]]; then
  exit 0
fi

echo "Uncovered decisions (paste each line below into PLAN.md unchanged, under '## User decisions (already made)'; only a verbatim copy of the statement counts, a paraphrase does not):"
for item in "${uncovered[@]}"; do
  echo "  - $item"
done
exit 1
