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

# The directive names a contract to READ and probes to RUN. The session cwd is the
# user's project, not the plugin, so both resolve from this hook's location.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" 2>/dev/null && pwd || true)"
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd || true)"

case "$LEVEL" in
  lite)  INTENSITY='LEVEL lite: build what is asked, but name the lazier alternative in one line so the user can pick it.' ;;
  ultra) INTENSITY='LEVEL ultra: YAGNI extremist. Deletion before addition. Ship the one-liner and challenge the rest of the requirement in the same breath.' ;;
  *)     INTENSITY='LEVEL full: the ladder enforced. Stdlib and native before custom code. Shortest diff, shortest explanation.' ;;
esac

# Pointer-style on purpose: the ladder lives in laziness-ladder.md and every session
# paid to re-read it here. What stays inline is what must bind without a file read.
DIRECTIVE="SIMPLICITY MODE ACTIVE (default, ${LEVEL}): the shortest solution that actually works. Read ${PLUGIN_ROOT}/skills/shared/laziness-ladder.md before writing code — do not paste it. When you are about to write or edit code this session, climb it AFTER you understand the problem (trace the real flow first), stop at the first rung that holds, and do not narrate: YAGNI, then DRY (reuse the helper that already lives here; two blocks that change for different reasons are not duplication and merging them is a coupling bug), stdlib, native platform, installed dependency, one line, then the minimum that works. Bug fix = root cause: grep every caller, fix the shared function once.
Before DONE: bash ${LIB_DIR}/indirection-scan.sh scan <files you touched> names each one-caller helper to inline (a long function with one caller is decomposition and earns its hop); bash ${LIB_DIR}/duplication-scan.sh scan <files you touched> names each block that already exists (duplicate= same lines, similar= names changed; both count).
${INTENSITY}
Never lazy about: understanding the problem, validation at trust boundaries, error handling that prevents data loss, security, accessibility, anything explicitly requested. A seam is not bloat. Non-trivial logic leaves ONE runnable check. Mark deliberate shortcuts with a 'simplicity:' comment naming the ceiling and upgrade path.
Disable with /loop-spec:settings simplicity off or LOOP_SPEC_SIMPLICITY=0."

# Emit valid JSON via jq (hard dependency) rather than a hand-rolled escaper.
jq -n --arg ctx "$DIRECTIVE" \
  '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}'
