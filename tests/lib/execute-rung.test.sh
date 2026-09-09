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

# The stub `claude` above plus a headless invocation is exactly what selects the
# session rung; LOOP_SPEC_SESSION_LAYER=0 pins the in-harness ladder beneath it.
select_rung() {
  env -u LOOP_SPEC_EXECUTE_LOOPS -u LOOP_SPEC_LOOP_RUNTIME -u CLAUDE_CODE_ENTRYPOINT \
    PATH="$WORK/bin:$PATH" LOOP_SPEC_HARNESS=claude LOOP_SPEC_SESSION_LAYER=0 "$@" bash "$SCRIPT" select \
    --width 3 --teams-mode none --workflows-available false --workflow-optin false
}
session_rung="session"; session_reason="headless/claude"
if ! python3 -c 'import tomllib' >/dev/null 2>&1; then session_rung="subagent"; session_reason="python-below-3.11"; fi

out="$(select_rung LOOP_SPEC_NON_INTERACTIVE=1)"
check "headless wide DAG uses subagent" "subagent" "$(jq -r '.rung' <<<"$out")"
check "headless fallback reason is auditable" "headless/non-interactive" "$(jq -r '.loop.runtimeReason' <<<"$out")"
check "headless subagent isolation is lead-created worktrees" "lead-worktree" \
  "$(jq -r '.subagentIsolation' <<<"$out")"

out="$(env -u LOOP_SPEC_SESSION_LAYER PATH="$WORK/bin:$PATH" LOOP_SPEC_HARNESS=claude LOOP_SPEC_NON_INTERACTIVE=1 \
  bash "$SCRIPT" select --width 1 --teams-mode none --workflows-available false --workflow-optin false)"
check "headless with the CLI and a profile uses the session rung" "$session_rung" "$(jq -r '.rung' <<<"$out")"
check "the session rung reports the probe's reason" "$session_reason" "$(jq -r '.sessionLayer.reason' <<<"$out")"
check "the session rung isolates by lead-created worktrees" "lead-worktree" "$(jq -r '.subagentIsolation' <<<"$out")"
out="$(env -u LOOP_SPEC_SESSION_LAYER PATH="$WORK/bin:$PATH" LOOP_SPEC_HARNESS=claude CLAUDE_CODE_ENTRYPOINT=sdk-cli \
  bash "$SCRIPT" select --width 3 --teams-mode implicit --workflows-available false --workflow-optin false)"
check "claude -p with the CLI outranks the team rung" "$session_rung" "$(jq -r '.rung' <<<"$out")"
out="$(env -u LOOP_SPEC_SESSION_LAYER PATH="$WORK/bin:$PATH" LOOP_SPEC_HARNESS=claude \
  bash "$SCRIPT" select --width 3 --teams-mode none --workflows-available false --workflow-optin false)"
check "an attended run never selects the session rung" "subagent" "$(jq -r '.rung' <<<"$out")"
check "the attended answer is in-harness" "in-harness" "$(jq -r '.sessionLayer.answer' <<<"$out")"
rc=0
out="$(env PATH="$WORK/nobin:$(dirname "$(command -v bash)"):$(dirname "$(command -v jq)"):$(dirname "$(command -v python3)")" LOOP_SPEC_HARNESS=claude LOOP_SPEC_SESSION_LAYER=1 \
  bash "$SCRIPT" select --width 1 --teams-mode none --workflows-available false --workflow-optin false)" || rc=$?
check "a forced session layer without the CLI fails loudly" "1" "$rc"
check "the forced session error is structured" "session-layer-unavailable" "$(jq -r '.error' <<<"$out")"

out="$(select_rung LOOP_SPEC_EXECUTION_PROFILE=interactive)"
check "persistent runtime may auto-select loop" "loop" "$(jq -r '.rung' <<<"$out")"

out="$(select_rung)"
check "unmarked one-shot-safe default uses subagent" "subagent" "$(jq -r '.rung' <<<"$out")"

out="$(select_rung LOOP_SPEC_WORKTREES=0)"
check "worktree opt-out retains sequential context-isolating subagents" "subagent:false" \
  "$(jq -r '.rung + ":" + (.worktreesEnabled | tostring)' <<<"$out")"
check "worktree opt-out reason is auditable" "LOOP_SPEC_WORKTREES=0; serial in-place one-shot subagents" \
  "$(jq -r '.reason' <<<"$out")"
check "worktree opt-out has no subagent isolation" "none" \
  "$(jq -r '.subagentIsolation' <<<"$out")"
rc=0
select_rung LOOP_SPEC_WORKTREES=invalid >/dev/null 2>&1 || rc=$?
check "invalid worktree setting fails closed" "2" "$rc"

out="$(select_rung LOOP_SPEC_MAX_PARALLEL_SUBAGENTS=1 \
  LOOP_SPEC_EXECUTION_PROFILE=interactive LOOP_SPEC_EXECUTE_LOOPS=1)"
check "global subagent cap disables fleet fan-out" "subagent:1:none" \
  "$(jq -r '.rung + ":" + (.maxParallelSubagents | tostring) + ":" + .teamsMode' <<<"$out")"

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

out="$(env -u LOOP_SPEC_EXECUTE_LOOPS PATH="$WORK/bin:$PATH" LOOP_SPEC_HARNESS=claude LOOP_SPEC_SESSION_LAYER=0 \
  LOOP_SPEC_NON_INTERACTIVE=1 bash "$SCRIPT" select --width 8 --teams-mode implicit \
  --workflows-available true --workflow-optin true)"
check "workflow still wins when opted in" "workflow" "$(jq -r '.rung' <<<"$out")"

out="$(env -u LOOP_SPEC_EXECUTE_LOOPS PATH="$WORK/bin:$PATH" LOOP_SPEC_HARNESS=claude LOOP_SPEC_SESSION_LAYER=0 \
  LOOP_SPEC_NON_INTERACTIVE=1 bash "$SCRIPT" select --width 3 --teams-mode implicit \
  --workflows-available false --workflow-optin false)"
check "implicit inherit still selects team" "team" "$(jq -r '.rung' <<<"$out")"

out="$(env -u LOOP_SPEC_EXECUTE_LOOPS PATH="$WORK/bin:$PATH" LOOP_SPEC_HARNESS=claude LOOP_SPEC_SESSION_LAYER=0 \
  LOOP_SPEC_NON_INTERACTIVE=1 bash "$SCRIPT" select --width 3 --teams-mode implicit \
  --workflows-available false --workflow-optin false --implementer-model sonnet)"
check "implicit sonnet skips team for a nameless subagent" "subagent" "$(jq -r '.rung' <<<"$out")"
check "implicit sonnet reason names session inheritance" "1" \
  "$(grep -Fq 'inherit the session model' <<<"$(jq -r '.reason' <<<"$out")" && echo 1 || echo 0)"
check "implicit sonnet still reports teamsMode implicit" "implicit" \
  "$(jq -r '.teamsMode' <<<"$out")"

out="$(env -u LOOP_SPEC_EXECUTE_LOOPS PATH="$WORK/bin:$PATH" LOOP_SPEC_HARNESS=claude LOOP_SPEC_SESSION_LAYER=0 \
  LOOP_SPEC_NON_INTERACTIVE=1 bash "$SCRIPT" select --width 3 --teams-mode explicit \
  --workflows-available false --workflow-optin false --implementer-model sonnet)"
check "explicit sonnet still selects team" "team" "$(jq -r '.rung' <<<"$out")"

out="$(env -u LOOP_SPEC_EXECUTE_LOOPS PATH="$WORK/bin:$PATH" LOOP_SPEC_HARNESS=claude LOOP_SPEC_SESSION_LAYER=0 \
  LOOP_SPEC_NON_INTERACTIVE=1 bash "$SCRIPT" select --width 08 --teams-mode implicit \
  --workflows-available true --workflow-optin true)"
check "leading-zero width is decimal" "workflow" "$(jq -r '.rung' <<<"$out")"

# Configuration rejections exit 2 with stdout EMPTY and the message on stderr. The
# EXECUTE relay must therefore read stderr: `jq` on empty stdin prints nothing, so a
# stdout-only relay reports a blank error for every one of these paths.
cfg_rc=0
cfg_err="$WORK/cfg.err"
cfg_out="$(select_rung LOOP_SPEC_WORKTREES=maybe 2>"$cfg_err")" || cfg_rc=$?
check "invalid worktrees setting exits 2" "2" "$cfg_rc"
check "invalid worktrees setting writes no stdout JSON" "" "$cfg_out"
check "invalid worktrees message lands on stderr" "1" \
  "$(grep -q 'LOOP_SPEC_WORKTREES must be 0 or 1' "$cfg_err" && echo 1 || echo 0)"
check "stdout-only relay would lose the message" "" \
  "$(jq -r '.message // empty' <<<"$cfg_out" 2>/dev/null || true)"

# lib/execute-prepare.sh runs the probe for the skill now; its stderr passes straight
# through to the lead, and a failed selection is a loud exit 2.
EXEC_PREP="$ROOT/lib/execute-prepare.sh"
check "EXECUTE rung relay names a failed selection" "1" \
  "$(grep -Fq 'rung selection failed' "$EXEC_PREP" && echo 1 || echo 0)"
check "EXECUTE rung relay does not swallow the probe's stderr" "0" \
  "$(grep -Fq 'execute-rung select' "$EXEC_PREP" && grep -F 'execute-rung select' "$EXEC_PREP" | grep -Fq '2>/dev/null' && echo 1 || echo 0)"
check "EXECUTE passes implementer model into the rung probe" "1" \
  "$(grep -Fq -- '--implementer-model' "$EXEC_PREP" && echo 1 || echo 0)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
