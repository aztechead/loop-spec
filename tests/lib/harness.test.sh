#!/usr/bin/env bash
# Tests for lib/harness.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$REPO/lib/harness.sh"
PASS=0
FAIL=0

check() {
  local name="$1"
  local expected="$2"
  local actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"
    ((FAIL++)) || true
  fi
}

# run <verb> [env assignments...]
# Invokes the lib in a clean env so the real session's harness vars can't leak in.
run() {
  local verb="$1"; shift
  env -u LOOP_SPEC_HARNESS -u CLAUDECODE -u PI_CODING_AGENT_DIR \
    -u LOOP_SPEC_NON_INTERACTIVE -u LOOP_SPEC_EXECUTION_PROFILE \
    -u LOOP_SPEC_LOOP_RUNTIME -u CLAUDE_CODE_ENTRYPOINT "$@" \
    bash "$LIB" "$verb"
}

# --- detect: override wins over everything ---
got=$(run detect LOOP_SPEC_HARNESS=adk)
check "override adk -> adk" "adk" "$got"

got=$(run detect LOOP_SPEC_HARNESS=adk CLAUDECODE=1)
check "override adk beats CLAUDECODE" "adk" "$got"

got=$(run detect LOOP_SPEC_HARNESS=opencode)
check "override opencode -> opencode" "opencode" "$got"

got=$(run detect LOOP_SPEC_HARNESS=opencode CLAUDECODE=1)
check "override opencode beats CLAUDECODE" "opencode" "$got"

got=$(run detect LOOP_SPEC_HARNESS=codex)
check "override codex -> codex" "codex" "$got"

got=$(run detect LOOP_SPEC_HARNESS=codex CLAUDECODE=1)
check "override codex beats CLAUDECODE" "codex" "$got"

# --- detect: unknown override falls through to the back-compat default ---
got=$(run detect LOOP_SPEC_HARNESS=garbage)
check "unknown override -> default claude" "claude" "$got"

# An explicit retired harness is an operator request, not a stale ambient hint.
# Fail it loudly instead of running a different harness than the one requested.
set +e
pi_err="$(run detect LOOP_SPEC_HARNESS=pi 2>&1 >/dev/null)"
pi_rc=$?
set -e
check "retired pi override exits 2" "2" "$pi_rc"
check "retired pi override names migration" "1" \
  "$(grep -c 'choose claude, opencode, adk, or codex' <<< "$pi_err")"

set +e
run subagents LOOP_SPEC_HARNESS=pi >/dev/null 2>&1
pi_subagents_rc=$?
set -e
check "retired pi failure propagates through capability probe" "2" "$pi_subagents_rc"

got=$(run detect PI_CODING_AGENT_DIR=/x)
check "retired pi env hint -> default claude" "claude" "$got"

# --- detect: env signals ---
got=$(run detect CLAUDECODE=1)
check "CLAUDECODE=1 -> claude" "claude" "$got"

got=$(run detect)
check "no signals -> default claude" "claude" "$got"

# --- cli mirrors detect ---
got=$(run cli LOOP_SPEC_HARNESS=adk)
check "cli under adk -> adk" "adk" "$got"

got=$(run cli)
check "cli default -> claude" "claude" "$got"

got=$(run cli LOOP_SPEC_HARNESS=opencode)
check "cli under opencode -> opencode" "opencode" "$got"

got=$(run cli LOOP_SPEC_HARNESS=codex)
check "cli under codex -> codex" "codex" "$got"

# --- subagents ---
got=$(run subagents CLAUDECODE=1)
check "subagents under claude -> true" "true" "$got"

# opencode's task tool shares the Agent call shape, so the capability holds.
got=$(run subagents LOOP_SPEC_HARNESS=opencode)
check "subagents under opencode -> true" "true" "$got"

# The ADK bridge's dispatch_subagent takes {description, prompt, subagent_type,
# optional native model}, so the capability holds there too.
got=$(run subagents LOOP_SPEC_HARNESS=adk)
check "subagents under adk -> true" "true" "$got"

got=$(run subagents LOOP_SPEC_HARNESS=codex)
check "subagents under codex -> true" "true" "$got"

# --- loop runtime ---
got=$(run loop-runtime LOOP_SPEC_NON_INTERACTIVE=1)
check "non-interactive has no persistent loop runtime" "false" "$got"

got=$(run loop-runtime-reason LOOP_SPEC_EXECUTION_PROFILE=headless)
check "headless runtime reason is stable" "headless/non-interactive" "$got"

got=$(run loop-runtime)
check "unmarked invocation fails safe" "false" "$got"

got=$(run loop-runtime LOOP_SPEC_EXECUTION_PROFILE=interactive)
check "interactive profile asserts persistent runtime" "true" "$got"

got=$(run loop-runtime LOOP_SPEC_EXECUTION_PROFILE=interactive LOOP_SPEC_NON_INTERACTIVE=1)
check "non-interactive overrides contradictory profile" "false" "$got"

got=$(run loop-runtime LOOP_SPEC_NON_INTERACTIVE=1 LOOP_SPEC_LOOP_RUNTIME=1)
check "explicit runtime override wins" "true" "$got"

got=$(run loop-runtime LOOP_SPEC_LOOP_RUNTIME=0)
check "runtime kill switch wins" "false" "$got"

# --- entrypoint: the harness's own headless proof ---
# Claude Code stamps CLAUDE_CODE_ENTRYPOINT on every child process. `claude -p`
# rewrites cli -> sdk-cli; the Python Agent SDK sets sdk-py and the TypeScript
# SDK sets sdk-ts. Those three are one-shot invocations with no persistent
# runtime, so they are PROVEN headless rather than merely unproven.
got=$(run entrypoint CLAUDE_CODE_ENTRYPOINT=sdk-py)
check "entrypoint echoes the stamped value" "sdk-py" "$got"

got=$(run entrypoint)
check "unstamped entrypoint -> unknown" "unknown" "$got"

got=$(run headless CLAUDE_CODE_ENTRYPOINT=sdk-cli)
check "claude -p entrypoint is headless" "true" "$got"

got=$(run headless CLAUDE_CODE_ENTRYPOINT=sdk-py)
check "python SDK entrypoint is headless" "true" "$got"

got=$(run headless CLAUDE_CODE_ENTRYPOINT=sdk-ts)
check "typescript SDK entrypoint is headless" "true" "$got"

got=$(run headless CLAUDE_CODE_ENTRYPOINT=cli)
check "interactive CLI entrypoint is not headless" "false" "$got"

got=$(run headless)
check "unknown entrypoint is not assumed headless" "false" "$got"

got=$(run headless LOOP_SPEC_NON_INTERACTIVE=1)
check "operator non-interactive is headless" "true" "$got"

got=$(run headless LOOP_SPEC_EXECUTION_PROFILE=headless)
check "operator headless profile is headless" "true" "$got"

got=$(run headless LOOP_SPEC_EXECUTION_PROFILE=interactive CLAUDE_CODE_ENTRYPOINT=cli)
check "interactive profile is not headless" "false" "$got"

# --- entrypoint feeds loop-runtime ---
got=$(run loop-runtime CLAUDE_CODE_ENTRYPOINT=sdk-cli)
check "claude -p has no persistent loop runtime" "false" "$got"

got=$(run loop-runtime-reason CLAUDE_CODE_ENTRYPOINT=sdk-cli)
check "claude -p reason names the entrypoint" "headless/sdk-cli" "$got"

got=$(run loop-runtime-reason CLAUDE_CODE_ENTRYPOINT=sdk-py)
check "python SDK reason names the entrypoint" "headless/sdk-py" "$got"

# A stamped headless entrypoint is a fact; EXECUTION_PROFILE=interactive is an
# unverified claim (commonly a stale global export). The fact wins, which is the
# case that stranded a headless run on the loop rung.
got=$(run loop-runtime CLAUDE_CODE_ENTRYPOINT=sdk-py LOOP_SPEC_EXECUTION_PROFILE=interactive)
check "proven headless beats an interactive claim" "false" "$got"

got=$(run loop-runtime-reason CLAUDE_CODE_ENTRYPOINT=sdk-py LOOP_SPEC_EXECUTION_PROFILE=interactive)
check "proven headless reason beats an interactive claim" "headless/sdk-py" "$got"

# LOOP_SPEC_LOOP_RUNTIME stays absolute: it is the integrator's assertion that
# their headless wrapper CAN hold a foreground call open.
got=$(run loop-runtime CLAUDE_CODE_ENTRYPOINT=sdk-cli LOOP_SPEC_LOOP_RUNTIME=1)
check "integrator override still beats a headless entrypoint" "true" "$got"

# The interactive TUI keeps requiring an explicit opt-in (unchanged, deliberate).
got=$(run loop-runtime CLAUDE_CODE_ENTRYPOINT=cli)
check "interactive entrypoint alone stays unproven" "false" "$got"

got=$(run loop-runtime-reason CLAUDE_CODE_ENTRYPOINT=cli)
check "interactive entrypoint alone stays unproven (reason)" "unproven-runtime" "$got"

# --- unknown command exits 2 ---
rc=0
run bogus >/dev/null 2>&1 || rc=$?
check "unknown command exits 2" "2" "$rc"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
