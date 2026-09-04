#!/usr/bin/env bash
# converged-floor.sh - Deterministic floor under ITERATE's converged verdict.
#
# The judge's `converged: true` is a model judgment that ends the loop. This
# probe is the mechanical floor beneath it (docs/determinism-audit.md item 2,
# same shape as the deferral gate): convergence cannot be claimed over
# unverified scope. It never declares convergence — it can only VETO a
# converged verdict that the verification record does not support.
#
# Checks, given SPEC.md and VERIFICATION.md:
#   1. Every Good Enough criterion (GE-001..GE-NNN, numbered by SPEC checkbox
#      order) has a `- criterion: GE-NNN |` grounding row in VERIFICATION.md.
#   2. Every criterion has exactly one PASS result in "## Acceptance criteria".
#
# Usage: converged-floor.sh <spec-path> <verification-path>
#
# Exit codes:
#   0  floor holds
#   1  floor violated (each violation printed as "FLOOR <message>") — treat the
#      verdict as NOT converged; unreadable VERIFICATION.md with an existing
#      Good Enough section also fails (fail closed: VERIFY must have written it)
#   2  bad invocation
#
# Always ends with one ANSWER+REASON line:
#   converged-floor: ok (N criteria verified)  |  converged-floor: N violation(s)
set -uo pipefail

spec_path="${1:-}"
verification_path="${2:-}"
[[ -n "$spec_path" && -n "$verification_path" ]] || {
  echo "usage: converged-floor.sh <spec-path> <verification-path>" >&2
  exit 2
}

# A missing contract is missing evidence, never an empty success condition.
spec_content=""
if ! spec_content=$(cat "$spec_path" 2>/dev/null); then
  echo "FLOOR spec is not readable: $spec_path"
  echo "converged-floor: 1 violation(s)"
  exit 1
fi

criteria_count=$(printf '%s\n' "$spec_content" \
  | awk '/^###[[:space:]]+Good Enough/{flag=1; next} flag && /^#{1,6}[[:space:]]/{flag=0} flag' \
  | grep -cE '^\s*- \[[ xX]\]' || true)

if [[ "$criteria_count" -eq 0 ]]; then
  echo "FLOOR no Good Enough checkbox criteria in $spec_path"
  echo "converged-floor: 1 violation(s)"
  exit 1
fi

violations=0
if ! verification_content=$(cat "$verification_path" 2>/dev/null); then
  echo "FLOOR VERIFICATION.md is not readable ($verification_path) — a converged verdict needs the verification record"
  echo "converged-floor: 1 violation(s)"
  exit 1
fi

acceptance_rows="$(awk '
  /^##[[:space:]]+Acceptance criteria[[:space:]]*$/ {active=1; next}
  active && /^#/ {active=0}
  active && /^\|/ {print}
' <<<"$verification_content")"
for ((i = 1; i <= criteria_count; i++)); do
  ge_id=$(printf 'GE-%03d' "$i")
  if ! grep -qE "^\s*- criterion:\s*${ge_id}\b" <<<"$verification_content"; then
    echo "FLOOR $ge_id has no grounding row in $verification_path — unverified Good Enough scope cannot converge"
    violations=$((violations + 1))
  fi
  result="$(awk -F'|' -v id="$ge_id" -v number="$i" '
    {gsub(/^[ \t]+|[ \t]+$/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $4)}
    $2 == id || $2 == number {count++; status=$4}
    END {if (count == 1 && status == "PASS") print "PASS"; else print "missing, duplicate, or non-PASS"}
  ' <<<"$acceptance_rows")"
  if [[ "$result" != "PASS" ]]; then
    echo "FLOOR $ge_id acceptance result is $result in $verification_path"
    violations=$((violations + 1))
  fi
done

# Acceptance table: any FAIL status cell vetoes convergence outright.
while IFS= read -r line; do
  status_cell=$(awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $4); print $4}' <<<"$line")
  if [[ "$status_cell" == "FAIL" ]]; then
    echo "FLOOR acceptance table row still FAIL: ${line# }"
    violations=$((violations + 1))
  fi
done <<<"$acceptance_rows"

if [[ "$violations" -gt 0 ]]; then
  echo "converged-floor: $violations violation(s)"
  exit 1
fi
echo "converged-floor: ok ($criteria_count criteria verified)"
