#!/usr/bin/env bash
# Tests for lib/decision-coverage.sh
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)/lib/decision-coverage.sh"
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

WORK="${TMPDIR:-/tmp}/decision-coverage-test.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK"

# === Case A: all-covered ===
# All decisions in SPEC appear in PLAN -> exit 0
SPEC_A="$WORK/spec-a.md"
PLAN_A="$WORK/plan-a.md"
cat > "$SPEC_A" <<'EOF'
# SPEC

<decisions>
- Decision: use bash for scripting
- Decision: use awk for parsing
</decisions>
EOF
cat > "$PLAN_A" <<'EOF'
## Implementation

We use bash for scripting all helpers.
We use awk for parsing the block boundaries.
EOF

exit_code=0
bash "$SCRIPT" "$SPEC_A" "$PLAN_A" >/dev/null 2>&1 || exit_code=$?
check "A: all-covered exits 0" "0" "$exit_code"

# === Case B: one-uncovered ===
# One decision missing from PLAN -> exit 1, non-empty output
SPEC_B="$WORK/spec-b.md"
PLAN_B="$WORK/plan-b.md"
cat > "$SPEC_B" <<'EOF'
# SPEC

<decisions>
- Decision: use python for analysis
</decisions>
EOF
cat > "$PLAN_B" <<'EOF'
## Implementation

No python here. We use shell only.
EOF

exit_code=0
output=$(bash "$SCRIPT" "$SPEC_B" "$PLAN_B" 2>&1) || exit_code=$?
check "B: one-uncovered exits 1" "1" "$exit_code"
[[ -n "$output" ]] && nonempty="yes" || nonempty="no"
check "B: one-uncovered prints uncovered list" "yes" "$nonempty"

# === Case C: no <decisions> block ===
# SPEC has no <decisions>...</decisions> -> exit 0, prints "skipped"
SPEC_C="$WORK/spec-c.md"
PLAN_C="$WORK/plan-c.md"
cat > "$SPEC_C" <<'EOF'
# SPEC

This spec has no decisions block at all.
EOF
cat > "$PLAN_C" <<'EOF'
## Plan

Some plan content here.
EOF

exit_code=0
output=$(bash "$SCRIPT" "$SPEC_C" "$PLAN_C" 2>&1) || exit_code=$?
check "C: no-decisions-block exits 0" "0" "$exit_code"
echo "$output" | grep -qi "skip" && skipped="yes" || skipped="no"
check "C: no-decisions-block prints skipped note" "yes" "$skipped"

# === Case R: reflowed decision in PLAN still counts as covered ===
SPEC_R="$WORK/spec-r.md"
PLAN_R="$WORK/plan-r.md"
cat > "$SPEC_R" <<'EOF'
<decisions>
- Decision: a long decision text that a planner will reflow across two lines in the decisions record
</decisions>
EOF
cat > "$PLAN_R" <<'EOF'
## User decisions (already made)

- a long decision text that a planner will reflow
  across two lines in the decisions record
EOF

exit_code=0
bash "$SCRIPT" "$SPEC_R" "$PLAN_R" >/dev/null 2>&1 || exit_code=$?
check "R: reflowed decision exits 0" "0" "$exit_code"

# === Case D: missing SPEC file ===
# SPEC path does not exist -> exit 0 (fail-open)
SPEC_D="$WORK/does-not-exist.md"
PLAN_D="$WORK/plan-a.md"  # reuse plan-a which exists

exit_code=0
bash "$SCRIPT" "$SPEC_D" "$PLAN_D" >/dev/null 2>&1 || exit_code=$?
check "D: missing-spec-file exits 0 (fail-open)" "0" "$exit_code"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
