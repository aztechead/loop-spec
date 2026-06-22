#!/usr/bin/env bash
# grill-inject.sh - Inject the "grill me" disambiguation directive on SessionStart.
# Reads .loop-spec/grill.conf from CLAUDE_PROJECT_DIR (or CWD).
#
# DEFAULT IS ON. Unlike discipline-inject.sh (opt-in), grill mode is the default:
# the directive is injected unless explicitly disabled. This makes "grill me to
# lower ambiguity right after the initial prompt" the out-of-the-box behavior.
#
# Suppressed only when:
#   - .loop-spec/grill.conf contains ENABLED=0, OR
#   - LOOP_SPEC_GRILL=0 is set (session-level kill switch).
#
# Environment variables:
#   LOOP_SPEC_GRILL     Set to "0" to disable (kill switch). Default: on.
#   CLAUDE_PROJECT_DIR  Project root to find conf file. Defaults to CWD.

set -euo pipefail

# Fail-open: any unexpected error must not block the session.
trap 'exit 0' ERR

# Kill switch.
if [[ "${LOOP_SPEC_GRILL:-1}" == "0" ]]; then
  printf '{}\n'
  exit 0
fi

CONF_FILE="${CLAUDE_PROJECT_DIR:-.}/.loop-spec/grill.conf"

# Opt-out: if the conf file exists AND pins ENABLED=0, stay silent.
# Absent conf file => default ON (inject).
if [[ -f "$CONF_FILE" ]] && grep -q "ENABLED=0" "$CONF_FILE" 2>/dev/null; then
  printf '{}\n'
  exit 0
fi

# Grill mode is ON (default) - inject the disambiguation directive.
DIRECTIVE='GRILL MODE ACTIVE (default): Lower ambiguity before acting on the opening request.

After the user'"'"'s initial substantive prompt, and before writing code, planning, or committing to an approach, run one short grill pass:

1. Identify the highest-leverage unknowns - the ambiguities whose answers would most change what you build (goal, scope boundary, constraints, acceptance). Ignore trivia.
2. Ask 2-4 sharp clarifying questions in a single AskUserQuestion call. When a question has discernible answers (a scope cut, a data shape, an integration point, a yes/no), present structured multiple-choice options with explicit tradeoffs and a recommended default first. Reserve free-text for genuinely open prompts.
3. Carry the answers forward as locked decisions - do not re-ask what is already answered.

Skip the grill pass only when the request is already unambiguous, purely informational, or trivially reversible. Inside the loop-spec cycle, the SPEC phase Socratic interview is the in-cycle realization of this directive; do not double-grill once SPEC is running.

Grill mode is ON by default. Disable it with /loop-spec:grill off or LOOP_SPEC_GRILL=0.'

# Escape for JSON: backslashes, double-quotes, then collapse newlines to spaces.
ESCAPED=$(printf '%s' "$DIRECTIVE" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ' | sed 's/  */ /g')

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' "$ESCAPED"
