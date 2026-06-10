#!/usr/bin/env bash
# Unit tests for lib/ralph-remediation.sh
set -euo pipefail

PASS=0
FAIL=0
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ralph-remediation.sh"

pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }

# Setup: create a temp feature dir with feature.json
make_feature_dir() {
  local dir
  dir=$(mktemp -d)
  cat > "$dir/feature.json" <<'JSON'
{
  "slug": "test-feature",
  "pendingRemediationTasks": [
    {"id": "r1", "subject": "Fix lint errors in foo.sh", "verifyCommand": "bash -n foo.sh", "acceptanceCriteria": ["foo.sh passes shellcheck"]},
    {"id": "r2", "subject": "Fix missing test in bar.sh", "verifyCommand": "bash bar.test.sh", "acceptanceCriteria": ["bar.test.sh exits 0"]},
    {"id": "r3", "subject": "Add docs to baz.sh", "verifyCommand": "grep -q usage baz.sh", "acceptanceCriteria": ["baz.sh has a usage block"]},
    {"id": "r4", "subject": "Fix import in qux.sh", "verifyCommand": "bash -n qux.sh", "acceptanceCriteria": ["qux.sh sources without error"]}
  ]
}
JSON
  echo "$dir"
}

make_feature_dir_small() {
  local dir
  dir=$(mktemp -d)
  cat > "$dir/feature.json" <<'JSON'
{
  "slug": "small-feature",
  "pendingRemediationTasks": [
    {"id": "r1", "subject": "Fix lint errors in foo.sh", "verifyCommand": "bash -n foo.sh", "acceptanceCriteria": ["foo.sh passes shellcheck"]},
    {"id": "r2", "subject": "Fix missing test in bar.sh", "verifyCommand": "bash bar.test.sh", "acceptanceCriteria": ["bar.test.sh exits 0"]}
  ]
}
JSON
  echo "$dir"
}

make_feature_dir_empty() {
  local dir
  dir=$(mktemp -d)
  cat > "$dir/feature.json" <<'JSON'
{
  "slug": "empty-feature",
  "pendingRemediationTasks": []
}
JSON
  echo "$dir"
}

# Test 1: Script is executable
if [[ -x "$SCRIPT" ]]; then
  pass "script is executable"
else
  fail "script is executable"
fi

# Test 2: Above threshold exits 0 immediately (4 tasks, threshold default 3)
FDIR=$(make_feature_dir)
if LOOP_SPEC_RALPH_THRESHOLD=3 bash "$SCRIPT" "$FDIR" > /dev/null 2>&1; then
  EXITCODE=0
else
  EXITCODE=$?
fi
if [[ "$EXITCODE" -eq 0 ]]; then
  pass "above threshold exits 0 immediately"
else
  fail "above threshold exits 0 immediately (got exit $EXITCODE)"
fi
rm -rf "$FDIR"

# Test 3: At-threshold runs loop (2 tasks, threshold 3) - exits 1 since no COMPLETE signal from echo
FDIR=$(make_feature_dir_small)
LOGFILE="${TMPDIR:-/tmp}/ralph-remediation-small-feature.log"
rm -f "$LOGFILE"
set +e
LOOP_SPEC_RALPH_THRESHOLD=3 bash "$SCRIPT" "$FDIR" > /dev/null 2>&1
EXITCODE=$?
set -e
if [[ "$EXITCODE" -eq 1 ]]; then
  pass "at-threshold loop exits 1 when no COMPLETE signal"
else
  fail "at-threshold loop exits 1 when no COMPLETE signal (got exit $EXITCODE)"
fi
rm -rf "$FDIR"

# Test 4: Log file created for at-threshold case
FDIR=$(make_feature_dir_small)
SLUG="small-feature"
LOGFILE="${TMPDIR:-/tmp}/ralph-remediation-${SLUG}.log"
rm -f "$LOGFILE"
set +e
LOOP_SPEC_RALPH_THRESHOLD=3 bash "$SCRIPT" "$FDIR" > /dev/null 2>&1
set -e
if [[ -f "$LOGFILE" ]]; then
  pass "log file created for at-threshold case"
else
  fail "log file created for at-threshold case (expected $LOGFILE)"
fi
rm -rf "$FDIR"
rm -f "$LOGFILE"

# Test 5: Log file contains iteration info
FDIR=$(make_feature_dir_small)
SLUG="small-feature"
LOGFILE="${TMPDIR:-/tmp}/ralph-remediation-${SLUG}.log"
rm -f "$LOGFILE"
set +e
LOOP_SPEC_RALPH_THRESHOLD=3 bash "$SCRIPT" "$FDIR" > /dev/null 2>&1
set -e
if grep -q "iteration\|iter" "$LOGFILE" 2>/dev/null; then
  pass "log file contains iteration info"
else
  fail "log file contains iteration info"
fi
rm -rf "$FDIR"
rm -f "$LOGFILE"

# Test 6: Empty tasks list exits 0 immediately
FDIR=$(make_feature_dir_empty)
if LOOP_SPEC_RALPH_THRESHOLD=3 bash "$SCRIPT" "$FDIR" > /dev/null 2>&1; then
  pass "empty task list exits 0"
else
  fail "empty task list exits 0"
fi
rm -rf "$FDIR"

# Test 7: Log does not contain emoji (octopus or others)
FDIR=$(make_feature_dir_small)
SLUG="small-feature"
LOGFILE="${TMPDIR:-/tmp}/ralph-remediation-${SLUG}.log"
rm -f "$LOGFILE"
set +e
LOOP_SPEC_RALPH_THRESHOLD=3 bash "$SCRIPT" "$FDIR" > /dev/null 2>&1
set -e
if [[ -f "$LOGFILE" ]]; then
  # Check for common emoji unicode ranges (octopus is U+1F419)
  if python3 -c "
import sys
content = open(sys.argv[1]).read()
# Check if any character has ordinal > 127 (emoji are outside ASCII)
has_emoji = any(ord(c) > 127 for c in content)
sys.exit(0 if not has_emoji else 1)
" "$LOGFILE" 2>/dev/null; then
    pass "log file has no emoji"
  else
    fail "log file has no emoji"
  fi
else
  pass "log file has no emoji (file not created or empty)"
fi
rm -rf "$FDIR"
rm -f "$LOGFILE"

# Test 8: Missing feature.json exits non-zero
EMPTYDIR=$(mktemp -d)
set +e
bash "$SCRIPT" "$EMPTYDIR" > /dev/null 2>&1
EXITCODE=$?
set -e
if [[ "$EXITCODE" -ne 0 ]]; then
  pass "missing feature.json exits non-zero"
else
  fail "missing feature.json exits non-zero (got exit 0)"
fi
rm -rf "$EMPTYDIR"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
