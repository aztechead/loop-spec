#!/usr/bin/env bash
# PreToolUse hook: enforce session cost budget ceiling.
#
# Claude Code contract:
#   exit 0  = allow
#   exit 2  = block (with stderr message shown to user)
#
# Cost source hierarchy:
#   1. metrics-session.json (.totals.estimated_cost_usd) in CWD if the file exists
#   2. LOOP_SPEC_SESSION_COST_USD env var (test override)
#   3. 0 (no data -> fail-open, allow)
#
# Behavior:
#   ratio >= 1.0  -> exit 2, emit DENY to stderr
#   0.80 <= ratio < 1.0 -> exit 0, emit hookSpecificOutput.additionalContext WARNING to stdout
#   ratio < 0.80  -> exit 0 silently
#
# Kill-switch: LOOP_SPEC_BUDGET_GUARD=0 -> exit 0 unconditionally
# Fail-open: malformed metrics file -> exit 0
#
# Trace log:
#   ${LOOP_SPEC_BUDGET_TRACE_LOG:-/tmp/claude-hooks/loop-spec-budget-gate-trace.log}
set -euo pipefail

TRACE_LOG="${LOOP_SPEC_BUDGET_TRACE_LOG:-/tmp/claude-hooks/loop-spec-budget-gate-trace.log}"

trace() {
  local event="$1"
  local reason="${2:-}"
  mkdir -p "$(dirname "$TRACE_LOG")" 2>/dev/null || true
  printf '%s|budget-gate|%s|%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$event" "$reason" \
    >> "$TRACE_LOG" 2>/dev/null || true
}

# Kill-switch: unconditional bypass.
if [[ "${LOOP_SPEC_BUDGET_GUARD:-1}" == "0" ]]; then
  trace "skip" "guard=0"
  exit 0
fi

# Fail-open trap: any unexpected error must not block the session.
trap 'trace "error" "trap-ERR"; exit 0' ERR

# No ceiling configured: nothing to enforce.
if [[ -z "${LOOP_SPEC_MAX_COST_USD:-}" ]]; then
  trace "skip" "no-ceiling"
  exit 0
fi

# Drain stdin (required by PreToolUse hook protocol).
cat > /dev/null 2>&1 || true

MAX_COST="${LOOP_SPEC_MAX_COST_USD}"

# Resolve current cost.
# Priority 1: metrics-session.json in CWD.
CURRENT_COST=""
if [[ -f "metrics-session.json" ]]; then
  if command -v jq &>/dev/null; then
    CURRENT_COST=$(jq -r '.totals.estimated_cost_usd // empty' metrics-session.json 2>/dev/null || true)
  fi
fi

# Priority 2: env var override (for tests or explicit injection).
if [[ -z "$CURRENT_COST" ]]; then
  CURRENT_COST="${LOOP_SPEC_SESSION_COST_USD:-}"
fi

# Priority 3: treat as 0 (fail-open, no data).
if [[ -z "$CURRENT_COST" ]]; then
  CURRENT_COST="0"
fi

trace "check" "cost=$CURRENT_COST max=$MAX_COST"

# Float comparison via awk.
BUDGET_STATUS=$(awk -v current="$CURRENT_COST" -v max="$MAX_COST" '
BEGIN {
  c = current + 0
  m = max + 0
  if (m <= 0) {
    print "ok"
  } else if (c >= m) {
    print "over"
  } else if (c >= m * 0.8) {
    print "warning"
    printf "%.0f\n", (c / m) * 100
  } else {
    print "ok"
  }
}' 2>/dev/null) || { trace "error" "awk-failed"; exit 0; }

STATUS_LINE=$(printf '%s' "$BUDGET_STATUS" | head -1)
PCT_LINE=$(printf '%s' "$BUDGET_STATUS" | sed -n '2p')

case "$STATUS_LINE" in
  over)
    trace "block" "cost=$CURRENT_COST exceeds max=$MAX_COST"
    printf 'DENY: budget exceeded ($%s of $%s)\n' "$CURRENT_COST" "$MAX_COST" >&2
    exit 2
    ;;
  warning)
    PCT="${PCT_LINE:-80}"
    trace "warn" "cost=$CURRENT_COST at ${PCT}% of max=$MAX_COST"
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"WARNING: session cost is at %s%% of ceiling $%s (current: $%s). Avoid spawning additional sub-agents."}}\n' \
      "$PCT" "$MAX_COST" "$CURRENT_COST"
    exit 0
    ;;
  *)
    trace "allow" "cost=$CURRENT_COST below 80% of max=$MAX_COST"
    exit 0
    ;;
esac
