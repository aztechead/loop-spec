#!/usr/bin/env bash
# Check that every <decisions> entry in SPEC appears in PLAN.
#
# Usage: decision-coverage.sh <spec-path> <plan-path>
#
# Exit codes:
#   0  all entries covered (or no <decisions> block found -- skipped)
#   1  one or more entries not found in PLAN
#
# Prints uncovered entries to stdout on exit 1.
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

  # Fixed-string match on whitespace-normalized text (both sides)
  entry_norm="$(printf '%s' "$entry" | tr -s '[:space:]' ' ')"
  if [[ "$plan_norm" != *"$entry_norm"* ]]; then
    uncovered+=("$entry")
  fi
done <<< "$decisions_block"

if [[ ${#uncovered[@]} -eq 0 ]]; then
  exit 0
fi

echo "Uncovered decisions:"
for item in "${uncovered[@]}"; do
  echo "  - $item"
done
exit 1
