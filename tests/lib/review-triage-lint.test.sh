#!/usr/bin/env bash
# Tests for lib/review-triage-lint.sh (one verdict per code-review finding, with a
# location, and a disproof for every rejected finding).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LINT="$ROOT/lib/review-triage-lint.sh"
WORK="${TMPDIR:-/tmp}/loop-spec-review-triage.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"
PASS=0; FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL + 1))
  fi
}

# verification FINDINGS: a VERIFICATION.md whose Code review carries these findings.
verification() {
  cat > "$WORK/VERIFICATION.md" <<MD
# x - Verification

## Repository grounding

- criterion: GE-001 | implementation: src/a.py:3 - proof | integration: none - no separate site

## Acceptance criteria

| # | Criterion | Status | Evidence |
|---|-----------|--------|----------|
| GE-001 | it works | PASS | \`true\` -> exit 0 |

## Code review

**Reviewer:** code-reviewer (sonnet)

### Findings

#### Critical
$1

#### Important
none

#### Minor (deferred)
none

### Resolution
see above

## Final test suite

\`\`\`
ok
\`\`\`
MD
  printf '%s' "$WORK/VERIFICATION.md"
}

ec=0; bash "$LINT" >/dev/null 2>&1 || ec=$?
check "no argument is a bad call" "2" "$ec"
ec=0; bash "$LINT" "$WORK/missing.md" >/dev/null 2>&1 || ec=$?
check "a missing artifact flags" "1" "$ec"

f="$(verification 'none')"
ec=0; bash "$LINT" "$f" >/dev/null 2>&1 || ec=$?
check "none under every severity is clean" "0" "$ec"

f="$(verification '- src/a.py:12 — off by one in the range | verdict: true — fixed in 1a2b3c4')"
ec=0; out="$(bash "$LINT" "$f" 2>&1)" || ec=$?
check "a located finding with an evidenced true verdict passes" "0" "$ec"

f="$(verification '- src/a.py:12 — off by one in the range | verdict: false — the range is exclusive and tests/test_a.py:9 asserts the last element')"
ec=0; bash "$LINT" "$f" >/dev/null 2>&1 || ec=$?
check "a false verdict with a disproof sentence passes" "0" "$ec"

f="$(verification '- src/a.py:12 — off by one in the range | verdict: false — nope')"
ec=0; out="$(bash "$LINT" "$f" 2>&1)" || ec=$?
check "a false verdict without a disproof flags" "1" "$ec"
check "the flag names the disproof" "1" "$(grep -c 'verdict: false needs a disproof sentence' <<<"$out")"

f="$(verification '- off by one in the range | verdict: true — fixed in 1a2b3c4')"
ec=0; out="$(bash "$LINT" "$f" 2>&1)" || ec=$?
check "a finding without file:line flags" "1" "$ec"
check "the flag names the location rule and the line" "1" "$(grep -c '^FLAG .*VERIFICATION.md:20: finding has no file:line' <<<"$out")"

f="$(verification '- src/a.py:12 — off by one in the range')"
ec=0; out="$(bash "$LINT" "$f" 2>&1)" || ec=$?
check "a finding without a verdict flags" "1" "$ec"
check "the flag names the verdict rule" "1" "$(grep -c 'finding has no verdict' <<<"$out")"

f="$(verification '- src/a.py:12 — off by one in the range | verdict: true')"
ec=0; out="$(bash "$LINT" "$f" 2>&1)" || ec=$?
check "a true verdict without evidence flags" "1" "$ec"
check "the flag asks for the commit or backlog id" "1" "$(grep -c 'verdict: true needs its evidence' <<<"$out")"

f="$(verification '- Makefile:7 — the lint target runs nothing | verdict: true — backlog 9f8e7d6c')"
ec=0; bash "$LINT" "$f" >/dev/null 2>&1 || ec=$?
check "a file without an extension still counts as a location" "0" "$ec"

# Bullets outside the Findings block are not findings.
f="$(verification 'none')"
printf '\n## Verification gaps\n\n- a gap with no location\n' >> "$f"
ec=0; bash "$LINT" "$f" >/dev/null 2>&1 || ec=$?
check "bullets outside Code review findings are ignored" "0" "$ec"

# The shipped template's findings placeholders lint as the shape the skill writes.
ec=0; out="$(bash "$LINT" "$ROOT/skills/shared/artifact-templates/VERIFICATION.md.template" 2>&1)" || ec=$?
check "the template's example bullets carry the shape" "0" "$ec"

echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
