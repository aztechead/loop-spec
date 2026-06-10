#!/usr/bin/env bash
# PostToolUse hook: consecutive-failure strategy rotation.
#
# Claude Code contract:
#   exit 0  = allow (always; this hook only emits additionalContext, never blocks)
#
# Tracks consecutive tool failures per tool name in a per-session JSON state
# file. When failures reach the threshold the hook emits a JSON
# hookSpecificOutput.additionalContext block instructing the agent to stop and
# verbalize a different approach before retrying.
#
# Configuration (all optional):
#   LOOP_SPEC_STRATEGY_ROTATION_THRESHOLD  failures before rotation (default: 2)
#   LOOP_SPEC_STRATEGY_ROTATION            set to 0 to disable entirely
#
# State file: ${TMPDIR:-/tmp}/loop-spec-failures-${SESSION:-default}.json
# Hook event: PostToolUse (matcher: Bash|Edit|Write)
#
# Fail-open: any JSON parse/file error -> reset state to {} or exit 0
# Kill switch: LOOP_SPEC_STRATEGY_ROTATION=0 -> exit 0 immediately
#
# Trace log: ${LOOP_SPEC_USERGATE_TRACE_LOG:-/tmp/claude-hooks/loop-spec-user-gate-trace.log}
# format: <ISO-8601>|strategy-rotation|<tool>|<event>|<reason>

set -euo pipefail

# Fail-open exit trap: any unexpected error must not block the session.
trap 'exit 0' ERR

TRACE_LOG="${LOOP_SPEC_USERGATE_TRACE_LOG:-/tmp/claude-hooks/loop-spec-user-gate-trace.log}"
mkdir -p "$(dirname "$TRACE_LOG")" 2>/dev/null || true

trace() {
  local tool="${1:-?}" event="${2:-?}" reason="${3:-}"
  printf '%s|strategy-rotation|%s|%s|%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$tool" "$event" "$reason" \
    >> "$TRACE_LOG" 2>/dev/null || true
}

# Kill switch
if [[ "${LOOP_SPEC_STRATEGY_ROTATION:-1}" == "0" ]]; then
  trace "?" "skip" "kill-switch"
  exit 0
fi

# Scope: only active in projects that use loop-spec. This hook fires on every
# Bash/Edit/Write in the session; a stat is the most it may cost elsewhere.
if [[ ! -d "${CLAUDE_PROJECT_DIR:-$PWD}/.loop-spec" && ! -d "$PWD/.loop-spec" ]]; then
  exit 0
fi

THRESHOLD="${LOOP_SPEC_STRATEGY_ROTATION_THRESHOLD:-2}"

# Session identification (same priority as claude-octopus reference)
SESSION="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-$$}}"
STATE_FILE="${TMPDIR:-/tmp}/loop-spec-failures-${SESSION}.json"

# Drain stdin
INPUT=""
INPUT=$(cat 2>/dev/null) || true

# Detect tool name from payload
TOOL_NAME=""
if [[ -n "$INPUT" ]] && command -v jq &>/dev/null; then
  TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || TOOL_NAME=""
fi

# Normalize to lowercase key; exit 0 for untracked tools
TOOL_KEY=""
case "$(printf '%s' "$TOOL_NAME" | tr '[:upper:]' '[:lower:]')" in
  bash)  TOOL_KEY="bash" ;;
  edit)  TOOL_KEY="edit" ;;
  write) TOOL_KEY="write" ;;
  *)     trace "${TOOL_NAME:-?}" "skip" "untracked-tool"; exit 0 ;;
esac

# Detect failure from payload
IS_FAILURE=false

if [[ -n "$INPUT" ]] && command -v jq &>/dev/null; then
  # Check exit_code field (non-zero = failure)
  EXIT_CODE=$(printf '%s' "$INPUT" | jq -r '.exit_code // .exitCode // empty' 2>/dev/null) || EXIT_CODE=""
  if [[ -n "$EXIT_CODE" && "$EXIT_CODE" != "0" && "$EXIT_CODE" != "null" ]]; then
    IS_FAILURE=true
  fi

  # Check result text for clear error patterns
  if [[ "$IS_FAILURE" != "true" ]]; then
    RESULT_TEXT=$(printf '%s' "$INPUT" | jq -r '.result // .output // empty' 2>/dev/null) || RESULT_TEXT=""
    if [[ -n "$RESULT_TEXT" ]]; then
      if printf '%s' "$RESULT_TEXT" | grep -qiE '^error:|^FAIL:|failed to |command not found|permission denied|no such file|syntax error' 2>/dev/null; then
        IS_FAILURE=true
      fi
    fi
  fi

  # Check explicit error field
  if [[ "$IS_FAILURE" != "true" ]]; then
    HAS_ERROR=$(printf '%s' "$INPUT" | jq -r 'if .error then "yes" else "no" end' 2>/dev/null) || HAS_ERROR="no"
    if [[ "$HAS_ERROR" == "yes" ]]; then
      IS_FAILURE=true
    fi
  fi
fi

# Load current state; fail-open on any parse error
STATE="{}"
if [[ -f "$STATE_FILE" ]]; then
  STATE=$(cat "$STATE_FILE" 2>/dev/null) || STATE="{}"
  [[ -z "$STATE" ]] && STATE="{}"
  # Validate JSON; reset to {} on parse error
  if command -v jq &>/dev/null; then
    if ! printf '%s' "$STATE" | jq empty 2>/dev/null; then
      trace "$TOOL_KEY" "warn" "malformed-state-reset"
      STATE="{}"
    fi
  fi
fi

# Update state
if command -v jq &>/dev/null; then
  if [[ "$IS_FAILURE" == "true" ]]; then
    CURRENT=$(printf '%s' "$STATE" | jq -r ".${TOOL_KEY}.consecutive // 0" 2>/dev/null) || CURRENT=0
    NEW_COUNT=$((CURRENT + 1))
    STATE=$(printf '%s' "$STATE" | jq \
      --arg key "$TOOL_KEY" \
      --argjson count "$NEW_COUNT" \
      '.[$key] = {"consecutive": $count}' 2>/dev/null) || STATE="{}"
    trace "$TOOL_KEY" "failure" "count=$NEW_COUNT threshold=$THRESHOLD"
  else
    STATE=$(printf '%s' "$STATE" | jq \
      --arg key "$TOOL_KEY" \
      '.[$key] = {"consecutive": 0}' 2>/dev/null) || STATE="{}"
    trace "$TOOL_KEY" "success" "counter-reset"
  fi

  # Persist state
  printf '%s' "$STATE" > "$STATE_FILE" 2>/dev/null || true
fi

# Check threshold and emit additionalContext if reached
if [[ "$IS_FAILURE" == "true" ]] && command -v jq &>/dev/null; then
  CONSECUTIVE=$(printf '%s' "$STATE" | jq -r ".${TOOL_KEY}.consecutive // 0" 2>/dev/null) || CONSECUTIVE=0
  if [[ "$CONSECUTIVE" -ge "$THRESHOLD" ]]; then
    # Map tool key to display name
    TOOL_DISPLAY="$TOOL_KEY"
    [[ "$TOOL_KEY" == "bash" ]]  && TOOL_DISPLAY="Bash"
    [[ "$TOOL_KEY" == "edit" ]]  && TOOL_DISPLAY="Edit"
    [[ "$TOOL_KEY" == "write" ]] && TOOL_DISPLAY="Write"

    MSG="STOP. This approach failed ${CONSECUTIVE} consecutive times using ${TOOL_DISPLAY}."
    MSG="${MSG} Before your next attempt you must verbalize:"
    MSG="${MSG} (1) what the failure mode is,"
    MSG="${MSG} (2) a completely different approach you will try instead,"
    MSG="${MSG} (3) why the new approach avoids the same failure."
    MSG="${MSG} Do not retry the same command or edit pattern again."

    printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "$MSG"
    trace "$TOOL_KEY" "rotation" "emitted consecutive=$CONSECUTIVE"
  fi
fi

exit 0
