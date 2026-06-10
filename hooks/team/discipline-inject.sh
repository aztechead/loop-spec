#!/usr/bin/env bash
# discipline-inject.sh - Inject discipline directive on SessionStart.
# Reads .super-spec/discipline.conf from CLAUDE_PROJECT_DIR (or CWD).
# Outputs a hookSpecificOutput JSON blob when ENABLED=1 in conf file.
#
# Environment variables:
#   SUPER_SPEC_DISCIPLINE   Set to "0" to disable (kill switch). Default: 1.
#   CLAUDE_PROJECT_DIR      Project root to find conf file. Defaults to CWD.

set -euo pipefail

# Fail-open: any unexpected error must not block the session.
trap 'exit 0' ERR

# Kill switch.
if [[ "${SUPER_SPEC_DISCIPLINE:-1}" == "0" ]]; then
  printf '{}\n'
  exit 0
fi

CONF_FILE="${CLAUDE_PROJECT_DIR:-.}/.super-spec/discipline.conf"

# If conf file is absent or ENABLED=1 not present, exit silently.
if [[ ! -f "$CONF_FILE" ]] || ! grep -q "ENABLED=1" "$CONF_FILE" 2>/dev/null; then
  printf '{}\n'
  exit 0
fi

# Discipline is ON - inject the 5-gate directive.
DIRECTIVE='DISCIPLINE MODE ACTIVE: Five behavioral gates are enforced this session.

1. brainstorm-before-coding: Before writing code or making changes, confirm the approach has been discussed. If not, pause and brainstorm first. Even simple changes require an explicit plan.
2. verification-before-claims: Before claiming work is done, fixed, or passing - run the actual verification command and show the output. No "should work" or "looks correct." Evidence only.
3. investigation-before-fixes: When encountering any bug, error, or test failure - investigate root cause before proposing fixes. No guessing.
4. decision-gate: When comparing options or choosing between approaches - present a structured comparison with criteria and a recommendation. Do not just list pros and cons in prose.
5. intent-gate: Before any creative or writing task, lock in the goal and audience first. What is this for? Who reads it? What should they do after? Validate output against these locked goals.

These gates are active for this session. Setting SUPER_SPEC_DISCIPLINE=0 disables injection at the hook level.'

# Escape for JSON: backslashes, double-quotes, then collapse newlines to spaces.
ESCAPED=$(printf '%s' "$DIRECTIVE" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ' | sed 's/  */ /g')

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$ESCAPED"
