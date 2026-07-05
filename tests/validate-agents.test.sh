#!/usr/bin/env bash
# Tests for validate-agents.sh structural rules.
# Runs only against fixtures - does NOT validate the live agents/ directory.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR="$SCRIPT_DIR/validate-agents.sh"
PASS=0
FAIL=0

run_test() {
  local name="$1"
  local expected_exit="$2"
  local expected_msg="$3"
  local fixture="$4"

  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir/agents"
  cp "$fixture" "$tmpdir/agents/loop-spec-bad-agent.md"

  # Run validator from temp dir; override EXPECTED to 1 so count check passes
  output=$(cd "$tmpdir" && EXPECTED=1 bash "$VALIDATOR" 2>&1)
  actual_exit=$?

  rm -rf "$tmpdir"

  if [[ "$actual_exit" != "$expected_exit" ]]; then
    echo "FAIL [$name]: expected exit $expected_exit, got $actual_exit"
    echo "  output: $output"
    FAIL=$((FAIL + 1))
    return
  fi

  if [[ -n "$expected_msg" ]] && ! echo "$output" | grep -qF "$expected_msg"; then
    echo "FAIL [$name]: expected message containing '$expected_msg'"
    echo "  output: $output"
    FAIL=$((FAIL + 1))
    return
  fi

  echo "PASS [$name]"
  PASS=$((PASS + 1))
}

# Negative test: agent with 'skills:' key must be rejected
run_test "reject-skills-key" 1 "forbidden frontmatter key" "$SCRIPT_DIR/fixtures/agent-with-skills-key.md"

# Negative test: agent with invalid memory scope must be rejected
run_test "reject-bad-memory-scope" 1 "invalid memory scope" "$SCRIPT_DIR/fixtures/agent-with-bad-memory.md"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
