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
check "partial env gets missing roots" "allow" "$(printf '%s' "$out2" | jq -r '.hookSpecificOutput.permissionDecision')"
check "partial env keeps original command" "yes" "$(printf '%s' "$out2" | jq -r '.hookSpecificOutput.updatedInput.command' | grep -q 'echo hi' && echo yes || echo no)"

out_full="$(printf '%s' "{\"tool_name\":\"Bash\",\"cwd\":\"/tmp/proj\",\"tool_input\":{\"command\":\"export LOOP_SPEC_HARNESS=codex CLAUDE_PLUGIN_ROOT=x CLAUDE_PROJECT_DIR=y LOOP_SPEC_SKILL_DIR=z CLAUDE_SKILL_DIR=z\\necho hi\"}}" \
  | bash "$HOOK")"
check "does not double-prefix complete env" "" "$out_full"

out3="$(printf '%s' '{"tool_name":"spawn_agent","tool_input":{"message":"x"}}' \
  | bash "$HOOK")"
check "ignores non-Bash tools" "" "$out3"

payload='{"tool_name":"Bash","tool_input":{"command":"test \"$LOOP_SPEC_SKILL_DIR\" = \"$CLAUDE_SKILL_DIR\" && bash \"$LOOP_SPEC_SKILL_DIR/../../lib/harness.sh\" detect"}}'
neutral="$(printf '%s' "$payload" | LOOP_SPEC_SKILL_DIR="$REPO/skills/spec" CLAUDE_SKILL_DIR=/stale bash "$HOOK")"
check "neutral directory and compatibility alias execute" "codex" "$(bash -c "$(printf '%s' "$neutral" | jq -r '.hookSpecificOutput.updatedInput.command')")"
legacy="$(printf '%s' "$payload" | LOOP_SPEC_SKILL_DIR= CLAUDE_SKILL_DIR="$REPO/skills/spec" bash "$HOOK")"
check "legacy environment supplies neutral directory" "codex" "$(bash -c "$(printf '%s' "$legacy" | jq -r '.hookSpecificOutput.updatedInput.command')")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
