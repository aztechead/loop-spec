#!/usr/bin/env bash
# Test suite for hooks/team/invocation-stamp.sh
# UserPromptSubmit hook: stamp the tokens of a /loop-spec:<skill> prompt for the driver.
# Usage: bash hooks/team/invocation-stamp.test.sh
set -uo pipefail
HOOK="$(cd "$(dirname "$0")" && pwd)/invocation-stamp.sh"
WORK="${TMPDIR:-/tmp}/invocation-stamp-test-$$"
mkdir -p "$WORK/proj"
trap 'rm -rf "$WORK"' EXIT
PASS=0
FAIL=0
check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $name"; ((PASS++)) || true
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; ((FAIL++)) || true
  fi
}
run() { CLAUDE_PROJECT_DIR="$WORK/proj" bash "$HOOK" <<<"$1"; }
STAMP="$WORK/proj/.loop-spec/invocation-stamp.json"

run '{"prompt":"/loop-spec:cycle autonomous add a --json flag to wc_tool.py"}'
check "cycle prompt is stamped" "1" "$([[ -f "$STAMP" ]] && echo 1 || echo 0)"
check "stamp carries the skill" "cycle" "$(jq -r '.skill' "$STAMP")"
check "stamp carries the raw arguments" "autonomous add a --json flag to wc_tool.py" "$(jq -r '.args' "$STAMP")"

rm -f "$STAMP"
run '{"prompt":"please fix the failing test"}'
check "an ordinary prompt writes nothing" "0" "$([[ -f "$STAMP" ]] && echo 1 || echo 0)"

run '{"prompt":"/loop-spec:auto new build a fib tool"}'
check "auto prompt is stamped" "auto" "$(jq -r '.skill' "$STAMP")"
rm -f "$STAMP"

LOOP_SPEC_INVOCATION_STAMP=0 run '{"prompt":"/loop-spec:cycle autonomous x"}'
check "kill switch writes nothing" "0" "$([[ -f "$STAMP" ]] && echo 1 || echo 0)"

ec=0; run 'not json' || ec=$?
check "malformed payload exits 0" "0" "$ec"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
