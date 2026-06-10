#!/usr/bin/env bash
# Unit tests for lib/pause-snapshot.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$REPO_ROOT/lib/pause-snapshot.sh"
PASS=0
FAIL=0

ok() { echo "PASS: $1"; (( PASS++ )) || true; }
fail() { echo "FAIL: $1"; (( FAIL++ )) || true; }

# Set up a fixture feature dir
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

FEATURE_DIR="$TMPDIR_TEST/.loop-spec/features/test-feature"
mkdir -p "$FEATURE_DIR"

cat > "$FEATURE_DIR/feature.json" <<'EOF'
{
  "slug": "test-feature",
  "currentPhase": "execute",
  "completedPhases": ["discuss", "plan"],
  "branch": "feat/test-feature",
  "pendingRemediationTasks": [],
  "gateHistory": []
}
EOF

# Test 1: --dry-run with --feature-dir produces valid JSON with all required keys
OUTPUT=$(bash "$SCRIPT" --dry-run --feature-dir "$FEATURE_DIR" 2>/dev/null)
if echo "$OUTPUT" | jq -e 'has("currentPhase") and has("completedTasks") and has("pendingTasks") and has("blockers") and has("decisions") and has("uncommittedFiles") and has("contextNotes")' >/dev/null 2>&1; then
  ok "--dry-run produces valid JSON with all required keys"
else
  fail "--dry-run did not produce valid JSON with all required keys; got: $OUTPUT"
fi

# Test 2: currentPhase value matches fixture
PHASE=$(echo "$OUTPUT" | jq -r '.currentPhase' 2>/dev/null || echo "")
if [[ "$PHASE" == "execute" ]]; then
  ok "currentPhase extracted correctly from feature.json"
else
  fail "currentPhase wrong; expected 'execute', got '$PHASE'"
fi

# Test 3: uncommittedFiles is an array
IS_ARRAY=$(echo "$OUTPUT" | jq 'type == "object" and (.uncommittedFiles | type) == "array"' 2>/dev/null || echo "false")
if [[ "$IS_ARRAY" == "true" ]]; then
  ok "uncommittedFiles is an array"
else
  fail "uncommittedFiles is not an array; got: $OUTPUT"
fi

# Test 4: kill switch LOOP_SPEC_PAUSE=0 exits 0 without output
KILL_OUTPUT=$(LOOP_SPEC_PAUSE=0 bash "$SCRIPT" --dry-run --feature-dir "$FEATURE_DIR" 2>/dev/null || echo "exit-nonzero")
if [[ -z "$KILL_OUTPUT" ]]; then
  ok "kill switch LOOP_SPEC_PAUSE=0 exits 0 with no output"
else
  fail "kill switch did not suppress output; got: '$KILL_OUTPUT'"
fi

# Test 5: --dry-run does NOT write files
bash "$SCRIPT" --dry-run --feature-dir "$FEATURE_DIR" >/dev/null 2>&1
if [[ ! -f "$FEATURE_DIR/HANDOFF.json" && ! -f "$FEATURE_DIR/.continue-here.md" ]]; then
  ok "--dry-run does not write files to feature-dir"
else
  fail "--dry-run wrote files when it should not have"
fi

# Test 6: non-dry-run writes both artifacts
bash "$SCRIPT" --feature-dir "$FEATURE_DIR" 2>/dev/null
if [[ -f "$FEATURE_DIR/HANDOFF.json" && -f "$FEATURE_DIR/.continue-here.md" ]]; then
  ok "write mode creates HANDOFF.json and .continue-here.md"
else
  fail "write mode did not create expected files in $FEATURE_DIR"
fi

# Test 7: HANDOFF.json is valid JSON
if jq -e . "$FEATURE_DIR/HANDOFF.json" >/dev/null 2>&1; then
  ok "HANDOFF.json is valid JSON"
else
  fail "HANDOFF.json is not valid JSON"
fi

# Test 8: .continue-here.md contains required sections
if grep -q "BLOCKING CONSTRAINTS" "$FEATURE_DIR/.continue-here.md" && \
   grep -q "ANTI-PATTERNS" "$FEATURE_DIR/.continue-here.md" && \
   grep -q "REQUIRED READING" "$FEATURE_DIR/.continue-here.md"; then
  ok ".continue-here.md has required sections"
else
  fail ".continue-here.md missing required sections; content: $(cat "$FEATURE_DIR/.continue-here.md")"
fi

# Test 9: .continue-here.md has severity tags
if grep -qE "blocking:|advisory:" "$FEATURE_DIR/.continue-here.md"; then
  ok ".continue-here.md has severity tags (blocking: or advisory:)"
else
  fail ".continue-here.md missing severity tags"
fi

# Summary
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
