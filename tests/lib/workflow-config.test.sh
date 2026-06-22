#!/usr/bin/env bash
# Unit tests for lib/workflow-config.sh
set -euo pipefail
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/workflow-config.sh"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
CF="$WORK/workflow.json"
wc() { LOOP_SPEC_WORKFLOW_CONFIG="$CF" bash "$SCRIPT" "$@"; }

# No file -> default per-task
[[ "$(wc commit-strategy)" == "per-task" ]] && pass "absent -> per-task" || fail "absent -> per-task"

# at-end honored
echo '{"commitStrategy":"at-end"}' > "$CF"
[[ "$(wc commit-strategy)" == "at-end" ]] && pass "at-end honored" || fail "at-end honored"

# garbage value -> default
echo '{"commitStrategy":"bananas"}' > "$CF"
[[ "$(wc commit-strategy)" == "per-task" ]] && pass "garbage -> default" || fail "garbage -> default"

# malformed json -> fail-open default
echo '{not json' > "$CF"
[[ "$(wc commit-strategy)" == "per-task" ]] && pass "malformed -> default" || fail "malformed -> default"

# get arbitrary key with default
echo '{"commitStrategy":"at-end","foo":"bar"}' > "$CF"
[[ "$(wc get foo)" == "bar" ]] && pass "get existing key" || fail "get existing key"
[[ "$(wc get missing fallback)" == "fallback" ]] && pass "get missing -> default" || fail "get missing -> default"

echo ""; echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
