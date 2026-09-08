#!/usr/bin/env bash
# Tests for hooks/team/dispatch-prompt-guard.sh
# PreToolUse (Agent): deny a prompt that is an unexpanded substitution or too short to be a brief.
set -euo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/dispatch-prompt-guard.sh"
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

PROJECT="${TMPDIR:-/tmp}/dispatch-prompt-guard-test-$$"
trap 'rm -rf "$PROJECT"' EXIT
mkdir -p "$PROJECT/.loop-spec"
cd "$PROJECT"

agent() { python3 -c 'import json,sys; print(json.dumps({"tool_name":"Agent","tool_input":{"description":"impl","prompt":sys.argv[1]}}))' "$1"; }

# The live shape.
check "unexpanded \$(cat file) denied" 2 "$(agent '$(cat /tmp/prompt-task-001.txt)')"
check "backtick substitution denied" 2 "$(agent '`cat /tmp/brief.md`')"
check "empty prompt denied" 2 "$(agent '')"
check "one-line stub denied" 2 "$(agent 'do task-001')"
check "a brief with a line that is only a substitution denied" 2 "$(agent $'Follow the directive verbatim (fresh-eyes prose pruning):\n\n---\n$(cat contents below)\n---\nArtifact: /repo/docs/loop-spec/features/x/SPEC.md and the template at /plugin/skills/shared/artifact-templates/SPEC.md.template. Return the pruning list.')"

# Real briefs pass, including ones that mention a substitution inside prose.
BRIEF='You are an implementer agent for task task-001. Read the brief at /repo/.loop-spec/features/x/dispatch/task-001-brief.md, then run the verify command `$(cat cmd.txt)` exactly as written and report DONE.'
check "a full brief is allowed" 0 "$(agent "$BRIEF")"
check "non-Agent tool allowed" 0 '{"tool_name":"Bash","tool_input":{"command":"echo $(cat x)"}}'
check "kill switch allows" 0 "$(agent '$(cat /tmp/x)')" LOOP_SPEC_DISPATCH_PROMPT_GUARD=0
cd /
check "outside a loop-spec project allowed" 0 "$(agent '$(cat /tmp/x)')" CLAUDE_PROJECT_DIR=/
check "malformed payload allowed" 0 'not json'

echo
echo "dispatch-prompt-guard: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
