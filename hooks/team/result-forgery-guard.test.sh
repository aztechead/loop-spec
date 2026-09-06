#!/usr/bin/env bash
# Test suite for hooks/team/result-forgery-guard.sh
# PreToolUse hook (Bash): contract files are written only by their own writers.
# Usage: bash hooks/team/result-forgery-guard.test.sh
set -uo pipefail
HOOK="$(cd "$(dirname "$0")" && pwd)/result-forgery-guard.sh"
WORK="${TMPDIR:-/tmp}/result-forgery-guard-test-$$"
mkdir -p "$WORK/proj/.loop-spec" "$WORK/plain"
trap 'rm -rf "$WORK"' EXIT
PASS=0
FAIL=0
check() {
  local name="$1" expected="$2" cmd="$3" dir="${4:-$WORK/proj}" ec=0
  CLAUDE_PROJECT_DIR="$dir" bash "$HOOK" >/dev/null 2>&1 <<<"$(jq -cn --arg c "$cmd" '{tool_name:"Bash", tool_input:{command:$c}}')" || ec=$?
  if [[ "$ec" -eq "$expected" ]]; then echo "PASS: $name"; ((PASS++)) || true
  else echo "FAIL: $name (expected exit $expected, got $ec)"; ((FAIL++)) || true; fi
}
check "heredoc into last-result.json is denied" 2 $'cat > .loop-spec/last-result.json << \'EOF\'\n{"status":"completed"}\nEOF'
check "jq redirected into feature.json is denied" 2 'jq ".currentPhase=\"deliver\"" f.json > .loop-spec/features/x/feature.json'
check "append to result.json is denied" 2 'echo "{}" >> /abs/path/.loop-spec/features/x/result.json'
check "tee into active-run.json is denied" 2 'printf "{}" | tee .loop-spec/active-run.json'
check "cp over delivery.json is denied" 2 'cp /tmp/d.json .loop-spec/features/x/delivery.json'
check "sed -i on feature.json is denied" 2 'sed -i "s/execute/deliver/" .loop-spec/features/x/feature.json'
check "python open for write is denied" 2 'python3 -c "import json; json.dump({}, open(\".loop-spec/last-result.json\", \"w\"))"'
check "reading the result is allowed" 0 'cat .loop-spec/last-result.json | jq .status'
check "the writer itself is allowed" 0 'bash /plugin/lib/cycle-result.sh write .loop-spec/features/x --status failed --reason "runner died" --summary s'
check "feature-write is allowed" 0 'bash /plugin/lib/feature-write.sh set .loop-spec/features/x currentPhase "\"verify\""'
check "an unrelated redirect is allowed" 0 'python3 -m unittest > /tmp/out.log 2>&1'
check "a project without .loop-spec is untouched" 0 'cat > .loop-spec/last-result.json <<< "{}"' "$WORK/plain"
LOOP_SPEC_FORGERY_GUARD=0 check "kill switch allows" 0 'cat > .loop-spec/last-result.json <<< "{}"'
ec=0; CLAUDE_PROJECT_DIR="$WORK/proj" bash "$HOOK" >/dev/null 2>&1 <<<"not json" || ec=$?
check_m() { [[ "$ec" -eq 0 ]] && { echo "PASS: malformed payload allows"; ((PASS++)) || true; } || { echo "FAIL: malformed payload allows"; ((FAIL++)) || true; }; }; check_m
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
