#!/usr/bin/env bash
# Tests for hooks/team/busy-wait-guard.sh
# PreToolUse (Bash): deny a call whose only work is sleeping; allow waits with a purpose.
set -euo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/busy-wait-guard.sh"
PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" payload="$3"
  shift 3
  local actual=0
  env "$@" bash "$HOOK" >/dev/null 2>&1 <<< "$payload" || actual=$?
  if [[ "$actual" -eq "$expected" ]]; then
    echo "PASS: $name"; ((PASS++)) || true
  else
    echo "FAIL: $name (expected exit $expected, got $actual)"; ((FAIL++)) || true
  fi
}

PROJECT="${TMPDIR:-/tmp}/busy-wait-guard-test-$$"
trap 'rm -rf "$PROJECT"' EXIT
mkdir -p "$PROJECT/.loop-spec"
cd "$PROJECT"

bash_payload() { python3 -c 'import json,sys; print(json.dumps({"tool_name":"Bash","tool_input":{"command":sys.argv[1]}}))' "$1"; }

# The live shapes.
check "for/seq sleep loop denied" 2 "$(bash_payload 'for i in $(seq 1 100); do sleep 6; done; echo tick7')"
check "sleep then read a file denied" 2 "$(bash_payload 'sleep 45; tail -c 3000 /tmp/x.output')"
check "sleep then cat gate output denied" 2 "$(bash_payload 'sleep 240; echo "GATE:"; cat /tmp/plan-gate2.out; echo "=== procs:"; ps aux | grep -c "[a]cceptance-lint"')"
check "bare sleep denied" 2 "$(bash_payload 'sleep 300')"

# Waits with a purpose pass.
check "until loop on a condition allowed" 0 "$(bash_payload 'until grep -q Ready dev.log; do sleep 0.5; done')"
check "while loop polling a job allowed" 0 "$(bash_payload 'while ! test -f done; do sleep 5; done')"
check "sleep before kill allowed" 0 "$(bash_payload 'sleep 2; kill $pid')"
check "sleep beside a real command allowed" 0 "$(bash_payload 'sleep 1 && terragrunt plan -lock=false')"
check "no sleep allowed" 0 "$(bash_payload 'git status --short')"

# Scope and kill switch.
check "non-Bash tool allowed" 0 '{"tool_name":"Read","tool_input":{"file_path":"/tmp/x"}}'
check "kill switch allows" 0 "$(bash_payload 'sleep 300')" LOOP_SPEC_BUSY_WAIT_GUARD=0
cd /
check "outside a loop-spec project allowed" 0 "$(bash_payload 'sleep 300')" CLAUDE_PROJECT_DIR=/
check "malformed payload allowed" 0 'not json'

echo
echo "busy-wait-guard: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
