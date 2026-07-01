#!/usr/bin/env bash
# Tests for lib/criteria-coverage.sh
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/lib/criteria-coverage.sh"
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

WORK="${TMPDIR:-/tmp}/criteria-coverage-test.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"

# === Case A: all-covered ===
SPEC_A="$WORK/spec-a.md"
PLAN_A="$WORK/plan-a.md"
cat > "$SPEC_A" <<'EOF'
# SPEC

## Success criteria

### Good Enough

- CSV export completes for a 10k-row table
- progress bar renders during export

### Exceptional

- export streams without buffering the whole table
EOF
cat > "$PLAN_A" <<'EOF'
## Spec coverage

- CSV export completes for a 10k-row table -> task-001
- progress bar renders during export -> task-002
EOF

exit_code=0
bash "$SCRIPT" "$SPEC_A" "$PLAN_A" >/dev/null 2>&1 || exit_code=$?
check "A: all-covered exits 0" "0" "$exit_code"

# === Case B: one-uncovered ===
SPEC_B="$WORK/spec-b.md"
PLAN_B="$WORK/plan-b.md"
cat > "$SPEC_B" <<'EOF'
## Success criteria

### Good Enough

- CSV export completes for a 10k-row table
- progress bar renders during export
EOF
cat > "$PLAN_B" <<'EOF'
## Spec coverage

- CSV export completes for a 10k-row table -> task-001
EOF

exit_code=0
output=$(bash "$SCRIPT" "$SPEC_B" "$PLAN_B" 2>&1) || exit_code=$?
check "B: one-uncovered exits 1" "1" "$exit_code"
echo "$output" | grep -qF "progress bar renders during export" && listed="yes" || listed="no"
check "B: uncovered criterion is listed" "yes" "$listed"

# === Case C: Exceptional criteria are NOT gated ===
# Only Good Enough bullets are required in PLAN; stretch criteria dropped from
# PLAN must not fail the gate.
SPEC_C="$WORK/spec-c.md"
PLAN_C="$WORK/plan-c.md"
cat > "$SPEC_C" <<'EOF'
### Good Enough

- the one shippable criterion

### Exceptional

- an unplanned stretch criterion
EOF
cat > "$PLAN_C" <<'EOF'
- the one shippable criterion -> task-001
EOF

exit_code=0
bash "$SCRIPT" "$SPEC_C" "$PLAN_C" >/dev/null 2>&1 || exit_code=$?
check "C: exceptional-only-missing exits 0" "0" "$exit_code"

# === Case D: no Good Enough section ===
SPEC_D="$WORK/spec-d.md"
PLAN_D="$WORK/plan-d.md"
cat > "$SPEC_D" <<'EOF'
# SPEC with no success criteria section at all
EOF
cat > "$PLAN_D" <<'EOF'
## Plan
EOF

exit_code=0
output=$(bash "$SCRIPT" "$SPEC_D" "$PLAN_D" 2>&1) || exit_code=$?
check "D: no-section exits 0" "0" "$exit_code"
echo "$output" | grep -qi "skip" && skipped="yes" || skipped="no"
check "D: no-section prints skipped note" "yes" "$skipped"

# === Case E: missing SPEC file (fail-open) ===
exit_code=0
bash "$SCRIPT" "$WORK/does-not-exist.md" "$PLAN_A" >/dev/null 2>&1 || exit_code=$?
check "E: missing-spec-file exits 0 (fail-open)" "0" "$exit_code"

# === Case F: checkbox bullets ===
SPEC_F="$WORK/spec-f.md"
PLAN_F="$WORK/plan-f.md"
cat > "$SPEC_F" <<'EOF'
### Good Enough

- [ ] checkboxed criterion is still extracted
EOF
cat > "$PLAN_F" <<'EOF'
- checkboxed criterion is still extracted -> task-001
EOF

exit_code=0
bash "$SCRIPT" "$SPEC_F" "$PLAN_F" >/dev/null 2>&1 || exit_code=$?
check "F: checkbox bullet covered exits 0" "0" "$exit_code"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
