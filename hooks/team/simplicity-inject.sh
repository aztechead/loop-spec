#!/usr/bin/env bash
# simplicity-inject.sh - Inject the laziness-ladder directive on SessionStart.
# Reads .loop-spec/simplicity.conf from CLAUDE_PROJECT_DIR (or CWD).
#
# DEFAULT IS ON at level "full" (like grill-inject, unlike opt-in discipline):
# the directive is injected unless explicitly disabled. Ported from ponytail
# (https://github.com/DietrichGebert/ponytail).
#
# Suppressed only when:
#   - .loop-spec/simplicity.conf contains ENABLED=0, OR
#   - LOOP_SPEC_SIMPLICITY=0 is set (session-level kill switch), OR
#   - the project is not a loop-spec project (no .loop-spec/ dir).
#
# Environment variables:
#   LOOP_SPEC_SIMPLICITY  Set to "0" to disable (kill switch). Default: on.
#   CLAUDE_PROJECT_DIR    Project root to find conf file. Defaults to CWD.

set -euo pipefail

# Fail-open: any unexpected error must not block the session.
trap 'exit 0' ERR

# Kill switch.
if [[ "${LOOP_SPEC_SIMPLICITY:-1}" == "0" ]]; then
  printf '{}\n'
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"

# Self-scope: only act inside loop-spec projects, matching every other loop-spec
# SessionStart hook. A default-ON directive must not inject into unrelated
# projects just because the plugin is installed.
if [[ ! -d "${PROJECT_DIR}/.loop-spec" ]]; then
  printf '{}\n'
  exit 0
fi

CONF_FILE="${PROJECT_DIR}/.loop-spec/simplicity.conf"

# Opt-out: if the conf file exists AND pins ENABLED=0, stay silent.
# Absent conf file => default ON (inject).
if [[ -f "$CONF_FILE" ]] && grep -q "ENABLED=0" "$CONF_FILE" 2>/dev/null; then
  printf '{}\n'
  exit 0
fi

# Resolve level: conf LEVEL=, else full. Validate against the known set.
LEVEL="full"
if [[ -f "$CONF_FILE" ]]; then
  conf_level=$(grep -E '^LEVEL=' "$CONF_FILE" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '[:space:]' || true)
  case "$conf_level" in
    lite|full|ultra) LEVEL="$conf_level" ;;
  esac
fi

case "$LEVEL" in
  lite)  INTENSITY='LEVEL lite: build what is asked, but name the lazier alternative in one line so the user can pick it.' ;;
  ultra) INTENSITY='LEVEL ultra: YAGNI extremist. Deletion before addition. Ship the one-liner and challenge the rest of the requirement in the same breath.' ;;
  *)     INTENSITY='LEVEL full: the ladder enforced. Stdlib and native before custom code. Shortest diff, shortest explanation.' ;;
esac

DIRECTIVE="SIMPLICITY MODE ACTIVE (default, ${LEVEL}): write the shortest solution that actually works. Lazy means efficient, not careless. The best code is the code never written.

Before writing any code, stop at the first rung that holds:
1. Does this need to exist at all? Speculative need = skip it, say so in one line. (YAGNI)
2. Already in this codebase? Reuse the helper, util, type, or pattern that already lives here; do not re-implement it.
3. Stdlib does it? Use it.
4. Native platform feature covers it? Use it.
5. Already-installed dependency solves it? Use it; never add a new one for what a few lines can do.
6. Can it be one line? One line.
7. Only then: the minimum code that works.

The ladder runs AFTER you understand the problem, not instead of it: read the task and the code it touches, trace the real flow end to end, then climb. Bug fix = root cause not symptom: grep every caller and fix the shared function once.

${INTENSITY}

Never lazy about: understanding the problem, input validation at trust boundaries, error handling that prevents data loss, security, accessibility, or anything explicitly requested. Non-trivial logic leaves ONE runnable check behind. Mark deliberate shortcuts with a 'simplicity:' comment naming the ceiling and upgrade path.

Simplicity mode is ON by default. Disable it with /loop-spec:simplicity off or LOOP_SPEC_SIMPLICITY=0."

# Emit valid JSON via jq (hard dependency) rather than a hand-rolled escaper.
jq -n --arg ctx "$DIRECTIVE" \
  '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}'
