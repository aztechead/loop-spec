#!/usr/bin/env bash
# Test suite for teammate-idle.sh
# Tests the advisory hook emitted when a teammate goes idle.
# Usage: bash hooks/team/teammate-idle.test.sh
set -euo pipefail

HOOK="$(dirname "$0")/teammate-idle.sh"
PASS=0
FAIL=0

check() {
  local name="$1"
  local expected_exit="$2"
  local stderr_pattern="$3"
  shift 3
  # Remaining args are env overrides passed via env(1)
  local actual_exit=0
  local actual_stderr

  actual_stderr=$(env "$@" bash "$HOOK" 2>&1 >/dev/null) || actual_exit=$?

  if [[ "$actual_exit" -ne "$expected_exit" ]]; then
    echo "FAIL: $name (expected exit $expected_exit, got $actual_exit)"
    ((FAIL++)) || true
    return
  fi

  if [[ -n "$stderr_pattern" && "$actual_stderr" != *"$stderr_pattern"* ]]; then
    echo "FAIL: $name (expected stderr to contain '$stderr_pattern', got: $actual_stderr)"
    ((FAIL++)) || true
    return
  fi

  echo "PASS: $name"
  ((PASS++)) || true
}

# Setup: create a temp dir for feature.json fixtures
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

FEATURE_DIR="$TMPDIR_TEST/.super-spec/features/my-feature"
mkdir -p "$FEATURE_DIR"

FEATURE_JSON="$FEATURE_DIR/feature.json"

echo "=== teammate-idle.sh tests ==="

# Case A: no feature.json -> exit 0, advisory to stderr
check "A: missing feature.json exits 0 with advisory" 0 "advisory" \
  "SUPER_SPEC_FEATURE_DIR=$TMPDIR_TEST/.super-spec/features/nonexistent"

# Case B: feature.json currentPhase=discuss -> exit 0, message mentions "discuss"
cat > "$FEATURE_JSON" <<'JSON'
{"schemaVersion":3,"slug":"my-feature","currentPhase":"discuss","currentTeamName":"super-spec-discuss-my-feature","currentTeammates":["spec-writer-1"]}
JSON
check "B: currentPhase=discuss mentions discuss" 0 "discuss" \
  "SUPER_SPEC_FEATURE_DIR=$FEATURE_DIR"

# Case C: feature.json currentPhase=plan -> exit 0, message mentions "plan"
cat > "$FEATURE_JSON" <<'JSON'
{"schemaVersion":3,"slug":"my-feature","currentPhase":"plan","currentTeamName":"super-spec-plan-my-feature","currentTeammates":["planner-1"]}
JSON
check "C: currentPhase=plan mentions plan" 0 "plan" \
  "SUPER_SPEC_FEATURE_DIR=$FEATURE_DIR"

# Case D: feature.json currentPhase=execute -> exit 0, message mentions "execute"
cat > "$FEATURE_JSON" <<'JSON'
{"schemaVersion":3,"slug":"my-feature","currentPhase":"execute","currentTeamName":"super-spec-execute-my-feature","currentTeammates":["implementer-1","reviewer-1"]}
JSON
check "D: currentPhase=execute mentions execute" 0 "execute" \
  "SUPER_SPEC_FEATURE_DIR=$FEATURE_DIR"

# Case E: feature.json currentPhase=verify -> exit 0, message mentions "verify"
cat > "$FEATURE_JSON" <<'JSON'
{"schemaVersion":3,"slug":"my-feature","currentPhase":"verify","currentTeamName":"super-spec-verify-my-feature","currentTeammates":["verifier-1"]}
JSON
check "E: currentPhase=verify mentions verify" 0 "verify" \
  "SUPER_SPEC_FEATURE_DIR=$FEATURE_DIR"

# Case F: corrupt JSON -> exit 0, graceful handling with advisory to stderr
printf '{not valid json' > "$FEATURE_JSON"
check "F: corrupt feature.json exits 0 with advisory" 0 "advisory" \
  "SUPER_SPEC_FEATURE_DIR=$FEATURE_DIR"

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
