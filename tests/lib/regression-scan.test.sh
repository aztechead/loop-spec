#!/usr/bin/env bash
# Tests for lib/regression-scan.sh
# TDD: run before implementation - expect FAIL.
set -euo pipefail

LIB="$(cd "$(dirname "$0")/../.." && pwd)/lib/regression-scan.sh"
PASS=0
FAIL=0

check() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"
    ((FAIL++)) || true
  fi
}

WORK="${TMPDIR:-/tmp}/loop-spec-regression-scan.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/docs/loop-spec/features/feat-a"
mkdir -p "$WORK/docs/loop-spec/features/feat-b"

# --- Case A: output has required keys ---
out=$(bash "$LIB" "$WORK" 2>/dev/null)
has_prior=$(printf '%s' "$out" | jq 'has("prior_features")' 2>/dev/null || echo false)
has_failed=$(printf '%s' "$out" | jq 'has("failed_tests")' 2>/dev/null || echo false)
check "A: prior_features key present" "true" "$has_prior"
check "A: failed_tests key present" "true" "$has_failed"

# --- Case B: no VERIFICATION.md files -> empty arrays ---
prior_len=$(printf '%s' "$out" | jq '.prior_features | length' 2>/dev/null || echo -1)
check "B: no VERIFICATION.md -> prior_features is empty array" "0" "$prior_len"

# --- Case C: VERIFICATION.md present, with a passing bash test command ---
# Create a VERIFICATION.md with a verify command that will pass (echo PASS)
cat > "$WORK/docs/loop-spec/features/feat-a/VERIFICATION.md" <<'VEOF'
# VERIFICATION - feat-a

## Acceptance criteria

| # | Criterion | Verify command | Result |
|---|-----------|---------------|--------|
| 1 | some check | `echo PASS` | PASS |

## Result

All criteria pass.
VEOF

out2=$(bash "$LIB" "$WORK" 2>/dev/null)
prior_len2=$(printf '%s' "$out2" | jq '.prior_features | length' 2>/dev/null || echo -1)
check "C: VERIFICATION.md present -> prior_features has 1 entry" "1" "$prior_len2"

# --- Case D: prior_features entry has slug field ---
slug=$(printf '%s' "$out2" | jq -r '.prior_features[0].slug' 2>/dev/null || echo "")
check "D: prior_features[0] has slug field" "feat-a" "$slug"

# --- Case E: VERIFICATION.md with a failing command -> failed_tests populated ---
cat > "$WORK/docs/loop-spec/features/feat-b/VERIFICATION.md" <<'VEOF'
# VERIFICATION - feat-b

## Acceptance criteria

| # | Criterion | Verify command | Result |
|---|-----------|---------------|--------|
| 1 | some failing check | `exit 1` | PASS |

## Result

All criteria pass.
VEOF

out3=$(bash "$LIB" "$WORK" 2>/dev/null)
failed_len=$(printf '%s' "$out3" | jq '.failed_tests | length' 2>/dev/null || echo -1)
check "E: failing command -> failed_tests has 1 entry" "1" "$failed_len"

# --- Case F: failed_tests entry has required fields ---
failed_slug=$(printf '%s' "$out3" | jq -r '.failed_tests[0].slug' 2>/dev/null || echo "")
failed_cmd=$(printf '%s' "$out3" | jq -r '.failed_tests[0].command' 2>/dev/null || echo "")
check "F: failed_tests[0] has slug field" "feat-b" "$failed_slug"
check "F: failed_tests[0] has command field (non-empty)" "true" "$([[ -n "$failed_cmd" ]] && echo true || echo false)"

# --- Case G: fail-open: missing project root -> empty arrays, exit 0 ---
out4=$(bash "$LIB" "/nonexistent/path" 2>/dev/null)
exit_code=0
bash "$LIB" "/nonexistent/path" > /dev/null 2>&1 || exit_code=$?
check "G: missing project root exits 0 (fail-open)" "0" "$exit_code"
has_keys=$(printf '%s' "$out4" | jq 'has("prior_features") and has("failed_tests")' 2>/dev/null || echo false)
check "G: missing project root still outputs valid JSON with keys" "true" "$has_keys"

# --- Case H: script is executable ---
check "H: script is executable" "0" "$([[ -x "$LIB" ]] && echo 0 || echo 1)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
