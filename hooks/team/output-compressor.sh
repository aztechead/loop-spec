#!/usr/bin/env bash
# PostToolUse hook: compress large tool outputs to save context tokens.
#
# Claude Code contract:
#   exit 0 = allow (always; this hook only emits additionalContext, never blocks)
#
# Reads tool output JSON from stdin. If the output field exceeds THRESHOLD chars,
# detects content shape and injects a compressed summary as additionalContext.
#
# Shape detection (in priority order):
#   JSON array  - first 2 + last 2 items + count
#   JSON object - first 15 keys + count
#   HTML        - strip tags, first 30 lines
#   Log/text    - head 15 + tail 15
#
# Debounce: fires only on every 3rd qualifying call per session.
#
# Configuration:
#   LOOP_SPEC_COMPRESSOR   Set to "0" to disable. Default: 1 (active).
#
# State file: ${TMPDIR:-/tmp}/loop-spec-compress-${SESSION}.count
# Hook event: PostToolUse (Bash|Read|Grep)
#
# Fail-open: trap 'exit 0' ERR
# Kill switch: LOOP_SPEC_COMPRESSOR=0 -> exit 0 immediately

set -euo pipefail

# Fail-open: any unexpected error must not block the session.
trap 'exit 0' ERR

# Kill switch.
if [[ "${LOOP_SPEC_COMPRESSOR:-1}" == "0" ]]; then
  exit 0
fi

# Scope: only active in projects that use loop-spec. This hook fires on every
# Bash/Read/Grep in the session; a stat is the most it may cost elsewhere.
if [[ ! -d "${CLAUDE_PROJECT_DIR:-$PWD}/.loop-spec" && ! -d "$PWD/.loop-spec" ]]; then
  exit 0
fi

THRESHOLD=3000
SESSION="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-$$}}"
DEBOUNCE_FILE="${TMPDIR:-/tmp}/loop-spec-compress-${SESSION}.count"

# Debounce: only process every 3rd call.
count=0
if [[ -f "$DEBOUNCE_FILE" ]]; then
  count=$(cat "$DEBOUNCE_FILE" 2>/dev/null || echo 0)
fi
count=$((count + 1))
printf '%s' "$count" > "$DEBOUNCE_FILE" 2>/dev/null || true
if [[ $((count % 3)) -ne 0 ]]; then
  exit 0
fi

# Read stdin.
INPUT=""
INPUT=$(cat 2>/dev/null) || true

[[ -z "$INPUT" ]] && exit 0

# Extract output field from hook payload via python3.
OUTPUT=""
OUTPUT=$(printf '%s' "$INPUT" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
# PostToolUse payload: tool output is in 'output' or 'result' field
val = d.get('output') or d.get('result') or ''
if not isinstance(val, str):
    val = json.dumps(val)
sys.stdout.write(val)
" 2>/dev/null) || true

[[ -z "$OUTPUT" ]] && exit 0

# Size check.
char_count=${#OUTPUT}
if [[ $char_count -lt $THRESHOLD ]]; then
  exit 0
fi

# Content type detection and compression.
content_type="text"
compressed=""
line_count=$(printf '%s' "$OUTPUT" | wc -l | tr -d ' ')

# JSON array detection.
if command -v jq &>/dev/null; then
  jq_type=$(printf '%s' "$OUTPUT" | jq -r 'type' 2>/dev/null || echo "")
  if [[ "$jq_type" == "array" ]]; then
    content_type="json_array"
    arr_len=$(printf '%s' "$OUTPUT" | jq 'length' 2>/dev/null || echo 0)
    first_items=$(printf '%s' "$OUTPUT" | jq -c '.[:2]' 2>/dev/null || echo "[]")
    last_items=$(printf '%s' "$OUTPUT" | jq -c '.[-2:]' 2>/dev/null || echo "[]")
    compressed="[JSON array, ${arr_len} items total. First 2: ${first_items} Last 2: ${last_items}]"
  elif [[ "$jq_type" == "object" ]]; then
    content_type="json_object"
    key_count=$(printf '%s' "$OUTPUT" | jq 'keys | length' 2>/dev/null || echo 0)
    first_keys=$(printf '%s' "$OUTPUT" | jq -r 'keys[:15] | join(", ")' 2>/dev/null || echo "")
    compressed="[JSON object, ${key_count} keys total. First 15: ${first_keys}]"
  fi
fi

# HTML detection.
if [[ "$content_type" == "text" ]]; then
  if printf '%s' "$OUTPUT" | head -5 | grep -qi '<html\|<!doctype'; then
    content_type="html"
    stripped=$(printf '%s' "$OUTPUT" | sed 's/<[^>]*>//g' | sed '/^[[:space:]]*$/d' | head -30)
    compressed="[HTML content, ${char_count} chars. Text extracted:]
${stripped}"
  fi
fi

# Log/text detection: 40+ lines -> head 15 + tail 15.
if [[ "$content_type" == "text" && $line_count -gt 40 ]]; then
  content_type="log"
  head_lines=$(printf '%s' "$OUTPUT" | head -15)
  tail_lines=$(printf '%s' "$OUTPUT" | tail -15)
  omitted=$((line_count - 30))
  compressed="${head_lines}

[... ${omitted} lines omitted (${char_count} chars total) ...]

${tail_lines}"
fi

# Short text below line threshold but above char threshold: head 15 + tail 15.
if [[ "$content_type" == "text" && -z "$compressed" ]]; then
  head_lines=$(printf '%s' "$OUTPUT" | head -15)
  tail_lines=$(printf '%s' "$OUTPUT" | tail -15)
  omitted=$((line_count - 30))
  if [[ $omitted -gt 0 ]]; then
    compressed="${head_lines}

[... ${omitted} lines omitted (${char_count} chars total) ...]

${tail_lines}"
  else
    compressed=$(printf '%s' "$OUTPUT" | head -30)
  fi
fi

[[ -z "$compressed" ]] && exit 0

# Escape compressed summary for JSON string value.
summary=$(printf '%s' "$compressed" | python3 -c "
import json, sys
text = sys.stdin.read()
# json.dumps produces a quoted string; strip surrounding quotes
print(json.dumps(text)[1:-1])
" 2>/dev/null || printf '%s' "$compressed" | head -5)

printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "$summary"
exit 0
