#!/usr/bin/env bash
# Tests for hooks/codex-shell-env.sh — PreToolUse Bash rewrite prefixes the
# loop-spec env contract and leaves non-Bash tools untouched.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$REPO/hooks/codex-shell-env.sh"
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

export PLUGIN_ROOT="$REPO"

out="$(printf '%s' '{"tool_name":"Bash","cwd":"/tmp/proj","tool_input":{"command":"echo hi"}}' \
  | bash "$HOOK")"
check "rewrites Bash" "allow" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision')"
cmd="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedInput.command')"
check "exports harness" "yes" "$(grep -q 'LOOP_SPEC_HARNESS=codex' <<<"$cmd" && echo yes || echo no)"
check "keeps original command" "yes" "$(grep -q 'echo hi' <<<"$cmd" && echo yes || echo no)"
check "sets plugin root" "yes" "$(grep -q "$REPO" <<<"$cmd" && echo yes || echo no)"

out2="$(printf '%s' '{"tool_name":"Bash","cwd":"/tmp/proj","tool_input":{"command":"export LOOP_SPEC_HARNESS=codex\necho hi"}}' \
  | bash "$HOOK")"
check "does not double-prefix" "" "$out2"

out3="$(printf '%s' '{"tool_name":"spawn_agent","tool_input":{"message":"x"}}' \
  | bash "$HOOK")"
check "ignores non-Bash tools" "" "$out3"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
