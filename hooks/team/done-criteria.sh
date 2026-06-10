#!/usr/bin/env bash
# UserPromptSubmit hook: compound task detection.
#
# Reads a UserPromptSubmit JSON payload from stdin, extracts the user prompt,
# applies three heuristics to detect compound tasks, and injects an
# additionalContext directive when a compound task is detected.
#
# Heuristics (no LLM calls):
#   H1: Numbered list  - two or more "1." / "2." / "1)" patterns in the prompt.
#   H2: Multi-verb     - action verb + and|then|also conjunction + action verb.
#   H3: Bullet list    - two or more lines starting with "- " or "* ".
#
# Kill switch: LOOP_SPEC_DONE_CRITERIA=0 -> exit 0 immediately.
# Fail-open:   trap 'exit 0' ERR
#
# Hook event: UserPromptSubmit

set -euo pipefail

# Kill switch.
if [[ "${LOOP_SPEC_DONE_CRITERIA:-1}" == "0" ]]; then
  exit 0
fi

# Scope: only active in projects that use loop-spec.
if [[ ! -d "${CLAUDE_PROJECT_DIR:-$PWD}/.loop-spec" && ! -d "$PWD/.loop-spec" ]]; then
  exit 0
fi

# Fail-open: unexpected errors must not disrupt the session.
trap 'exit 0' ERR

# Read stdin. If nothing is provided (e.g. interactive terminal), exit silently.
if [ -t 0 ]; then exit 0; fi
input=$(cat 2>/dev/null || true)
[[ -z "$input" ]] && exit 0

# Extract user prompt via python3 inline. Fall back gracefully.
prompt=""
if command -v python3 &>/dev/null; then
  prompt=$(printf '%s' "$input" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('prompt', d.get('message', d.get('content', ''))))
except Exception:
    pass
" 2>/dev/null) || true
fi

# If python3 extraction failed, fall back to a simple grep heuristic.
if [[ -z "$prompt" ]]; then
  prompt=$(printf '%s' "$input" | grep -oE '"(prompt|message|content)":"[^"]*"' | head -1 | sed 's/.*":"//' | sed 's/"$//' 2>/dev/null || true)
fi

# Nothing to analyze.
[[ -z "$prompt" ]] && exit 0

# Skip very short prompts (< 30 chars are unlikely to be compound tasks).
[[ ${#prompt} -lt 30 ]] && exit 0

# ── Compound task detection ──────────────────────────────────────────────────

compound=false

# H1: Numbered lists - two or more items using "N." or "N)" notation.
# Matches either two items on the same line or multiple lines each with a number.
if printf '%s' "$prompt" | grep -qE '(^|[[:space:]])[0-9]+[.)][[:space:]].*[0-9]+[.)][[:space:]]'; then
  compound=true
fi

# H2: Multi-verb prompts with and/then/also conjunctions.
verb_pat='(add|create|fix|update|implement|remove|delete|change|modify|refactor|write|build|test|deploy|configure|setup|install|move|rename|merge|split|extract|convert)'
if printf '%s' "$prompt" | grep -qiE "${verb_pat}.*(and|then|also).*${verb_pat}"; then
  compound=true
fi

# H3: Bullet lists - two or more lines starting with "- " or "* ".
bullet_count=$(printf '%s' "$prompt" | grep -cE '(^|\\n)[[:space:]]*[-*][[:space:]]' 2>/dev/null || echo 0)
if [[ "$bullet_count" -ge 2 ]]; then
  compound=true
fi

# ── Emit additionalContext when compound task detected ───────────────────────

if $compound; then
  DIRECTIVE="Enumerate completion criteria explicitly before starting. Verify each before declaring done."
  printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"%s"}}\n' "$DIRECTIVE"
fi

exit 0
