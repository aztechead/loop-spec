#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/lib/execute-rung.sh"
WORK="${TMPDIR:-/tmp}/loop-spec-execute-rung.$$"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/claude"
chmod +x "$WORK/bin/claude"
PASS=0; FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL + 1))
  fi
}

select_rung() {
  env -u LOOP_SPEC_EXECUTE_LOOPS -u LOOP_SPEC_LOOP_RUNTIME -u CLAUDE_CODE_ENTRYPOINT \
    PATH="$WORK/bin:$PATH" LOOP_SPEC_HARNESS=claude "$@" bash "$SCRIPT" select \
    --width 3 --teams-mode none --workflows-available false --workflow-optin false
}

out="$(select_rung LOOP_SPEC_NON_INTERACTIVE=1)"
check "headless wide DAG uses subagent" "subagent" "$(jq -r '.rung' <<<"$out")"
check "headless fallback reason is auditable" "headless/non-interactive" "$(jq -r '.loop.runtimeReason' <<<"$out")"

out="$(select_rung LOOP_SPEC_EXECUTION_PROFILE=interactive)"
check "persistent runtime may auto-select loop" "loop" "$(jq -r '.rung' <<<"$out")"

out="$(select_rung)"
check "unmarked one-shot-safe default uses subagent" "subagent" "$(jq -r '.rung' <<<"$out")"

out="$(select_rung LOOP_SPEC_NON_INTERACTIVE=1 LOOP_SPEC_LOOP_RUNTIME=1 LOOP_SPEC_EXECUTE_LOOPS=1)"
check "runtime override permits explicit loop" "loop" "$(jq -r '.rung' <<<"$out")"

# A headless entrypoint alone is enough to keep a wide DAG off the loop rung —
# no operator env required. This is the run that previously reached EXECUTE,
# selected loop, and exited 0 with no work done.
out="$(select_rung CLAUDE_CODE_ENTRYPOINT=sdk-cli)"
check "claude -p wide DAG uses subagent" "subagent" "$(jq -r '.rung' <<<"$out")"
check "claude -p reason names the entrypoint" "headless/sdk-cli" "$(jq -r '.loop.runtimeReason' <<<"$out")"

out="$(select_rung CLAUDE_CODE_ENTRYPOINT=sdk-py)"
check "python SDK wide DAG uses subagent" "subagent" "$(jq -r '.rung' <<<"$out")"

out="$(select_rung CLAUDE_CODE_ENTRYPOINT=sdk-py LOOP_SPEC_EXECUTION_PROFILE=interactive)"
check "stale interactive export cannot force loop" "subagent" "$(jq -r '.rung' <<<"$out")"

rc=0
out="$(select_rung LOOP_SPEC_NON_INTERACTIVE=1 LOOP_SPEC_EXECUTE_LOOPS=1)" || rc=$?
check "forced loop without runtime fails loudly" "1" "$rc"
check "forced loop error is structured" "loop-runtime-unavailable" "$(jq -r '.error' <<<"$out")"

out="$(env -u LOOP_SPEC_EXECUTE_LOOPS PATH="$WORK/bin:$PATH" LOOP_SPEC_HARNESS=claude \
  LOOP_SPEC_NON_INTERACTIVE=1 bash "$SCRIPT" select --width 8 --teams-mode implicit \
  --workflows-available true --workflow-optin true)"
check "workflow still wins when opted in" "workflow" "$(jq -r '.rung' <<<"$out")"

out="$(env -u LOOP_SPEC_EXECUTE_LOOPS PATH="$WORK/bin:$PATH" LOOP_SPEC_HARNESS=claude \
  LOOP_SPEC_NON_INTERACTIVE=1 bash "$SCRIPT" select --width 08 --teams-mode implicit \
  --workflows-available true --workflow-optin true)"
check "leading-zero width is decimal" "workflow" "$(jq -r '.rung' <<<"$out")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
