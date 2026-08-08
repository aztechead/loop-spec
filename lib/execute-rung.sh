#!/usr/bin/env bash
# Select EXECUTE's dispatch rung from measured width and probed capabilities.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ "${1:-}" == "select" ]] || {
  echo "usage: execute-rung.sh select --width N --teams-mode MODE --workflows-available BOOL --workflow-optin BOOL" >&2
  exit 2
}
shift

width=""
teams_mode="none"
workflows_available="false"
workflow_optin="false"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --width) width="${2:-}"; shift 2 ;;
    --teams-mode) teams_mode="${2:-}"; shift 2 ;;
    --workflows-available) workflows_available="${2:-}"; shift 2 ;;
    --workflow-optin) workflow_optin="${2:-}"; shift 2 ;;
    *) echo "execute-rung: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

[[ "$width" =~ ^[0-9]+$ ]] || { echo "execute-rung: width must be a non-negative integer" >&2; exit 2; }
width=$((10#$width))
case "$teams_mode" in none|explicit|implicit) ;; *) teams_mode="none" ;; esac
case "$workflows_available" in true|false) ;; *) workflows_available="false" ;; esac
case "$workflow_optin" in true|false) ;; *) workflow_optin="false" ;; esac

subagents="$(bash "$SCRIPT_DIR/harness.sh" subagents)"
agent_cli="$(bash "$SCRIPT_DIR/harness.sh" cli)"
loop_runtime="$(bash "$SCRIPT_DIR/harness.sh" loop-runtime)"
loop_runtime_reason="$(bash "$SCRIPT_DIR/harness.sh" loop-runtime-reason)"
cli_available="false"
command -v "$agent_cli" >/dev/null 2>&1 && cli_available="true"
loops_available="false"
[[ "$cli_available" == "true" && "$loop_runtime" == "true" ]] && loops_available="true"
loops_optin="${LOOP_SPEC_EXECUTE_LOOPS:-auto}"
case "$loops_optin" in 0|1|auto) ;; *) loops_optin="auto" ;; esac
subagent_cap="${LOOP_SPEC_MAX_PARALLEL_SUBAGENTS:-}"
if [[ -n "$subagent_cap" ]]; then
  [[ "$subagent_cap" =~ ^[1-9][0-9]*$ ]] || {
    echo "execute-rung: LOOP_SPEC_MAX_PARALLEL_SUBAGENTS must be a positive integer" >&2
    exit 2
  }
  teams_mode="none"
  workflows_available="false"
  loops_optin="0"
fi
worktrees_enabled="${LOOP_SPEC_WORKTREES:-1}"
case "$worktrees_enabled" in
  0|1) ;;
  *)
    echo "execute-rung: LOOP_SPEC_WORKTREES must be 0 or 1" >&2
    exit 2
    ;;
esac
worktrees_json=true
[[ "$worktrees_enabled" == "1" ]] || worktrees_json=false

if [[ "$worktrees_enabled" != "0" && "$loops_optin" == "1" && "$loops_available" != "true" ]]; then
  jq -cn --arg cli "$agent_cli" --argjson cliAvailable "$cli_available" \
    --arg runtimeReason "$loop_runtime_reason" \
    '{error:"loop-runtime-unavailable", cli:$cli, cliAvailable:$cliAvailable,
      runtimeReason:$runtimeReason,
      message:("LOOP_SPEC_EXECUTE_LOOPS=1 requested loop-fleet, but its persistent runtime is unavailable (" + $runtimeReason + ")")}'
  exit 1
fi

rung=""
reason=""
if [[ "$worktrees_enabled" == "0" ]]; then
  if [[ "$subagents" == "true" ]]; then
    rung="subagent"
    reason="LOOP_SPEC_WORKTREES=0; serial in-place one-shot subagents"
  else
    rung="inline"
    reason="LOOP_SPEC_WORKTREES=0; no subagent tool; serial in-place lead execution"
  fi
elif [[ "$loops_optin" == "1" ]]; then
  rung="loop"
  reason="explicit loop opt-in; runtime ${loop_runtime_reason}"
elif [[ "$subagents" != "true" ]]; then
  if (( width >= 3 )) && [[ "$loops_available" == "true" && "$loops_optin" != "0" ]]; then
    rung="loop"
    reason="no subagent tool; loop runtime ${loop_runtime_reason}"
  else
    rung="inline"
    reason="no subagent tool; loop unavailable (${loop_runtime_reason})"
  fi
elif [[ "${LOOP_SPEC_FOREIGN_CLAIMANTS:-0}" == "1" ]] \
  && { [[ -n "${LOOP_SPEC_PORT:-}" && -x "${LOOP_SPEC_PORT}" ]] \
    || [[ -x "${SCRIPT_DIR}/graph/port-local.sh" ]]; }; then
  # Opt-in foreign claimants over the handoff port. Same graph nodes; width
  # selects this rung and never removes a node.
  rung="foreign"
  reason="foreign claimants opted in; handoff port reachable"
elif (( width >= 6 )) && [[ "$workflows_available" == "true" && "$workflow_optin" == "true" ]]; then
  rung="workflow"
  reason="workflow opted in and available"
elif (( width >= 3 )) && [[ "$teams_mode" != "none" ]]; then
  rung="team"
  reason="teams mode ${teams_mode}"
elif (( width >= 3 )) && [[ "$loops_available" == "true" && "$loops_optin" != "0" ]]; then
  rung="loop"
  reason="teams unavailable; loop runtime ${loop_runtime_reason}"
else
  rung="subagent"
  if (( width >= 3 )); then
    reason="teams unavailable; loop unavailable (${loop_runtime_reason}); safe wide-DAG fallback"
  else
    reason="DAG width below team threshold"
  fi
fi

jq -cn --arg rung "$rung" --argjson width "$width" --arg reason "$reason" \
  --arg teamsMode "$teams_mode" --argjson subagents "$subagents" \
  --arg cli "$agent_cli" --argjson cliAvailable "$cli_available" \
  --argjson loopRuntime "$loop_runtime" --arg loopRuntimeReason "$loop_runtime_reason" \
  --arg loopOptIn "$loops_optin" --argjson worktreesEnabled "$worktrees_json" \
  --arg subagentCap "$subagent_cap" \
  '{rung:$rung,width:$width,reason:$reason,teamsMode:$teamsMode,
    subagentsAvailable:$subagents,
    maxParallelSubagents:(if $subagentCap == "" then null else ($subagentCap | tonumber) end),
    worktreesEnabled:$worktreesEnabled,
    loop:{cli:$cli,cliAvailable:$cliAvailable,runtimeAvailable:$loopRuntime,
      runtimeReason:$loopRuntimeReason,optIn:$loopOptIn}}'
