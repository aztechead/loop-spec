#!/usr/bin/env bash
# Tests for hooks/team/nested-session-guard.sh.
set -euo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/nested-session-guard.sh"
PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" payload="$3"
  shift 3
  local actual=0
  # The hook also reads $PWD/.loop-spec, and this repository has one: every case runs
  # from the fixture root so the repository never stands in for the project.
  (cd "${CASE_CWD:-$ROOT}" && env "$@" bash "$HOOK") >/dev/null 2>&1 <<<"$payload" || actual=$?
  if [[ "$actual" -eq "$expected" ]]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name (expected exit $expected, got $actual)"
    ((FAIL++)) || true
  fi
}

ROOT="${TMPDIR:-/tmp}/nested-session-guard-test-$$"
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/.loop-spec" "$ROOT/bare"
printf '#!/usr/bin/env bash\nclaude -p "/loop-spec:cycle autonomous x" --model sonnet\n' > "$ROOT/round.sh"
printf '#!/usr/bin/env bash\npython3 -m pytest -q\n' > "$ROOT/tests.sh"
printf '%s\n' "$(head -c 1000 /dev/zero | tr '\0' 'x')" > "$ROOT/data.txt"

bash_cmd() { jq -cn --arg c "$1" '{tool_name:"Bash", tool_input:{command:$c}}'; }

CASE_CWD="$ROOT/bare" check "no .loop-spec: any launch is allowed" 0 "$(bash_cmd 'claude -p hi')" CLAUDE_PROJECT_DIR="$ROOT/bare"
check "claude -p in the command is denied" 2 "$(bash_cmd 'claude -p "/loop-spec:cycle" --model sonnet')" CLAUDE_PROJECT_DIR="$ROOT"
check "claude --print is denied" 2 "$(bash_cmd 'cd /tmp && claude --print x')" CLAUDE_PROJECT_DIR="$ROOT"
check "codex exec is denied" 2 "$(bash_cmd 'codex exec --json "x"')" CLAUDE_PROJECT_DIR="$ROOT"
check "opencode run is denied" 2 "$(bash_cmd 'opencode run --format json "x"')" CLAUDE_PROJECT_DIR="$ROOT"
check "adk run is denied" 2 "$(bash_cmd 'LOOP_SPEC_NON_INTERACTIVE=1 adk run dir "x" --jsonl')" CLAUDE_PROJECT_DIR="$ROOT"
check "a launch behind a pipe is denied" 2 "$(bash_cmd 'echo x | claude -p')" CLAUDE_PROJECT_DIR="$ROOT"
check "claude --version is allowed" 0 "$(bash_cmd 'claude --version')" CLAUDE_PROJECT_DIR="$ROOT"
check "a word containing the CLI name is allowed" 0 "$(bash_cmd 'grep -rn "claude -p" docs/')" CLAUDE_PROJECT_DIR="$ROOT"
check "a script the command runs is read" 2 "$(bash_cmd "bash $ROOT/round.sh 2 3.0")" CLAUDE_PROJECT_DIR="$ROOT"
check "a script without a launch is allowed" 0 "$(bash_cmd "bash $ROOT/tests.sh")" CLAUDE_PROJECT_DIR="$ROOT"
check "a data file named by the command is not a launch" 0 "$(bash_cmd "wc -l $ROOT/data.txt")" CLAUDE_PROJECT_DIR="$ROOT"
check "the session rung launcher is allowed" 0 "$(bash_cmd 'python3 /plugin/extensions/sessions/session_run.py --profile claude --cwd . --prompt-file p.md')" CLAUDE_PROJECT_DIR="$ROOT"
check "the loop-runner launcher is allowed" 0 "$(bash_cmd 'python3 skills/loop-runner/scripts/supervisor.py --agent-cli claude')" CLAUDE_PROJECT_DIR="$ROOT"
check "the eval driver is allowed" 0 "$(bash_cmd 'LOOP_SPEC_EVAL_LIVE=1 python3 evals/eval_run.py --model haiku')" CLAUDE_PROJECT_DIR="$ROOT"
# The allow-list is the launcher's path token, not a substring: a script that mentions
# session_run.py in a comment and then launches a session is still a launch, and a
# lookalike name is not a launcher.
printf '#!/usr/bin/env bash\n# not extensions/sessions/session_run.py, but mentions it\nclaude -p "x"\n' > "$ROOT/mentions.sh"
check "a script that mentions a launcher and launches is denied" 2 "$(bash_cmd "bash $ROOT/mentions.sh")" CLAUDE_PROJECT_DIR="$ROOT"
check "a lookalike launcher name is denied" 2 "$(bash_cmd 'python3 my_session_run.py && claude -p hi')" CLAUDE_PROJECT_DIR="$ROOT"
check "a launcher named in a comment does not allow a launch on the same line" 2 "$(bash_cmd 'claude -p hi # evals/eval_run.py')" CLAUDE_PROJECT_DIR="$ROOT"
check "kill switch stands down" 0 "$(bash_cmd 'claude -p hi')" CLAUDE_PROJECT_DIR="$ROOT" LOOP_SPEC_NESTED_SESSION_GUARD=0
check "a non-Bash tool is allowed" 0 '{"tool_name":"Write","tool_input":{"file_path":"x","content":"claude -p hi"}}' CLAUDE_PROJECT_DIR="$ROOT"
check "malformed payload fails open" 0 "not json" CLAUDE_PROJECT_DIR="$ROOT"

msg="$((cd "$ROOT" && env CLAUDE_PROJECT_DIR="$ROOT" bash "$HOOK") 2>&1 >/dev/null <<<"$(bash_cmd 'claude -p x')" || true)"
if grep -q 'claude -p in the command' <<<"$msg" && grep -q 'session_run.py' <<<"$msg"; then
  echo "PASS: the denial names the launch and the sanctioned launcher"; ((PASS++)) || true
else
  echo "FAIL: the denial message is incomplete: $msg"; ((FAIL++)) || true
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
