#!/usr/bin/env bash
# Stop hook: block low-context deflection phrases.
#
# Claude Code contract:
#   exit 0  = allow
#   exit 2  = block (with stderr message shown to user)
#
# Reads context usage and the final assistant text from transcript_path JSONL.
# The legacy inline Stop payload remains supported:
#   total_used = input_tokens + cache_read_input_tokens + cache_creation_input_tokens
#
# Blocks the stop (exit 2) when:
#   1. The last assistant text contains a known deflection phrase, AND
#   2. Computed usage percentage is below LOOP_SPEC_DEFLECTION_THRESHOLD_PCT.
#
# Fail-open: if payload is missing, malformed, or usage cannot be resolved,
# the hook always exits 0. Errors never cascade into the user's session.
#
# Environment variables (all optional):
#   LOOP_SPEC_DEFLECTION_GUARD           Set to "0" to disable. Default: 1 (active).
#   LOOP_SPEC_CONTEXT_LIMIT              Total context window in tokens. Default: 200000.
#   LOOP_SPEC_DEFLECTION_THRESHOLD_PCT   Threshold %. Below this with phrase -> block. Default: 50.
#   LOOP_SPEC_DEFLECTION_TRACE_LOG       Path for trace log.
#                                         Default: /tmp/claude-hooks/loop-spec-deflection-trace.log
set -euo pipefail

# Kill switch.
if [[ "${LOOP_SPEC_DEFLECTION_GUARD:-1}" == "0" ]]; then
  exit 0
fi

# Scope: only active in projects that use loop-spec.
if [[ ! -d "${CLAUDE_PROJECT_DIR:-$PWD}/.loop-spec" && ! -d "$PWD/.loop-spec" ]]; then
  exit 0
fi

# Fail-open: any unexpected error must not block the session.
trap 'exit 0' ERR

TRACE_LOG="${LOOP_SPEC_DEFLECTION_TRACE_LOG:-/tmp/claude-hooks/loop-spec-deflection-trace.log}"
CONTEXT_LIMIT="${LOOP_SPEC_CONTEXT_LIMIT:-200000}"
THRESHOLD_PCT="${LOOP_SPEC_DEFLECTION_THRESHOLD_PCT:-50}"

trace() {
  local task_id="$1"
  local event="$2"
  local reason="$3"
  mkdir -p "$(dirname "$TRACE_LOG")" 2>/dev/null || true
  printf '%s|stop-deflection-guard|%s|%s|%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$task_id" "$event" "$reason" \
    >> "$TRACE_LOG" 2>/dev/null || true
}

INPUT=$(cat)

# stop_hook_active guard: when Claude Code is already continuing because of a
# previous Stop-hook block, do not block again. Claude Code force-overrides
# after 8 consecutive blocks; re-blocking only wastes turns. Exit 0 early.
if printf '%s' "$INPUT" | python3 -c "import json,sys; sys.exit(0 if json.load(sys.stdin).get('stop_hook_active') else 1)" 2>/dev/null; then
  trace "?" "skip" "stop_hook_active"
  exit 0
fi

# Parse last assistant text and usage tokens from production transcript_path JSONL,
# falling back to the legacy inline payload used by older harnesses/tests.
PARSE_RESULT=$(printf '%s' "$INPUT" | python3 -c "
import json, os, sys

try:
    d = json.load(sys.stdin)
except Exception:
    print(json.dumps({'text': '', 'tokens': -1, 'has_usage': False}))
    sys.exit(0)

usage = d.get('usage')
text = ''
transcript_path = str(d.get('transcript_path') or '')
if transcript_path and os.path.isfile(transcript_path):
    try:
        with open(transcript_path) as transcript:
            entries = []
            for line in transcript:
                try:
                    entry = json.loads(line)
                except Exception:
                    continue
                if entry.get('type') == 'assistant':
                    entries.append(entry)
        for entry in reversed(entries):
            message = entry.get('message') or {}
            parts = [c.get('text', '') for c in (message.get('content') or [])
                     if isinstance(c, dict) and c.get('type') == 'text']
            if parts and not text:
                text = '\n'.join(parts)
            if usage is None and message.get('usage') is not None:
                usage = message.get('usage')
            if text and usage is not None:
                break
    except Exception:
        pass
else:
    for entry in reversed(d.get('transcript') or []):
        if not isinstance(entry, dict) or entry.get('role') != 'assistant':
            continue
        parts = [c.get('text', '') for c in (entry.get('content') or [])
                 if isinstance(c, dict) and c.get('type') == 'text']
        if parts:
            text = '\n'.join(parts)
            break

if usage is None:
    print(json.dumps({'text': text, 'tokens': -1, 'has_usage': False}))
    sys.exit(0)

tokens = ((usage.get('input_tokens') or 0)
          + (usage.get('cache_read_input_tokens') or 0)
          + (usage.get('cache_creation_input_tokens') or 0))

print(json.dumps({'text': text, 'tokens': tokens, 'has_usage': True}))
" 2>/dev/null || echo "")

# If python3 produced no output, fail-open.
if [[ -z "$PARSE_RESULT" ]]; then
  trace "?" "parse-error" "empty python output"
  exit 0
fi

HAS_USAGE=$(printf '%s' "$PARSE_RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print('yes' if d.get('has_usage') else 'no')" 2>/dev/null || echo "no")
if [[ "$HAS_USAGE" != "yes" ]]; then
  trace "?" "fail-open" "no usage field in payload"
  exit 0
fi

TEXT=$(printf '%s' "$PARSE_RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('text',''))" 2>/dev/null || echo "")
TOKENS=$(printf '%s' "$PARSE_RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('tokens',0))" 2>/dev/null || echo "0")

# No text from last assistant message: nothing to scan.
if [[ -z "$TEXT" ]]; then
  trace "?" "allow" "no assistant text"
  exit 0
fi

# Compute usage percentage using integer math.
if [[ "${TOKENS:-0}" -le 0 || "${CONTEXT_LIMIT:-0}" -le 0 ]]; then
  CONTEXT_PCT=0
else
  CONTEXT_PCT=$(( TOKENS * 100 / CONTEXT_LIMIT ))
fi

trace "?" "scanned" "usage=${TOKENS}/${CONTEXT_LIMIT} pct=${CONTEXT_PCT}"

# At or above threshold: allow (context pressure may be legitimate).
if [[ "$CONTEXT_PCT" -ge "$THRESHOLD_PCT" ]]; then
  trace "?" "allow" "usage pct ${CONTEXT_PCT} >= threshold ${THRESHOLD_PCT}"
  exit 0
fi

# Deflection phrase list (case-insensitive scan below threshold only).
PATTERNS=(
  "fresh session"
  "context is full"
  "context full"
  "context is high"
  "running low on context"
  "start a new session"
)

for pattern in "${PATTERNS[@]}"; do
  if echo "$TEXT" | grep -qi "$pattern"; then
    trace "?" "deny" "phrase='${pattern}' usage=${CONTEXT_PCT}%"
    echo "DENY: deflection phrase detected but context usage is only ${CONTEXT_PCT}% (${TOKENS}/${CONTEXT_LIMIT} tokens). Provide a substantive response." >&2
    echo "(To disable this check, set LOOP_SPEC_DEFLECTION_GUARD=0.)" >&2
    exit 2
  fi
done

trace "?" "allow" "no deflection phrase matched"
exit 0
