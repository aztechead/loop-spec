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

# Rung 2 names a probe the session has to run, and the plugin is not the project
# it is working in. Resolved from this hook's own location, empty when the lib is
# not reachable -- the rung then stands on its own, same as the other injectors.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" 2>/dev/null && pwd || true)"
if [[ -n "$LIB_DIR" && -x "$LIB_DIR/indirection-scan.sh" ]]; then
  RUNG_ONE_PROBE="bash ${LIB_DIR}/indirection-scan.sh scan <files you touched> names each small private helper you added that is called exactly once -- inline it or say why the name earns its hop. It leaves decomposition alone: a long function with one caller, an exported symbol, and dead code are all silent."
else
  RUNG_ONE_PROBE="after writing, count the callers of every helper you added; one caller and a body of a few lines is a hop the reader pays for and you should inline."
fi

if [[ -n "$LIB_DIR" && -x "$LIB_DIR/duplication-scan.sh" ]]; then
  RUNG_TWO_PROBE="Rung 2 is measured, not recalled: you cannot find a helper in a file you never opened. Before you call anything you wrote new, run 'bash ${LIB_DIR}/duplication-scan.sh scan <files you touched>' -- it names each duplicated block and the file that block already lives in. It reports two kinds and both count: 'duplicate=' is the same lines, 'similar=' is the same lines with every name changed, which is what writing one module beside a similar one produces and the kind you are least likely to notice yourself."
else
  RUNG_TWO_PROBE="Rung 2 is measured, not recalled: you cannot find a helper in a file you never opened. Grep the tree for the distinctive line of anything you wrote from scratch before you call it new."
fi

case "$LEVEL" in
  lite)  INTENSITY='LEVEL lite: build what is asked, but name the lazier alternative in one line so the user can pick it.' ;;
  ultra) INTENSITY='LEVEL ultra: YAGNI extremist. Deletion before addition. Ship the one-liner and challenge the rest of the requirement in the same breath.' ;;
  *)     INTENSITY='LEVEL full: the ladder enforced. Stdlib and native before custom code. Shortest diff, shortest explanation.' ;;
esac

DIRECTIVE="SIMPLICITY MODE ACTIVE (default, ${LEVEL}): write the shortest solution that actually works. Lazy means efficient, not careless. The best code is the code never written.

When you are about to write or edit code this session, stop at the first rung that holds. Do not check the rungs below it. Do not narrate the rungs:
1. Does this need to exist at all? Speculative need = skip it, say so in one line. (YAGNI) The layer nobody needed always looks justified while you are writing it and is only countable afterwards, so count it: '${RUNG_ONE_PROBE}'
2. DRY -- already in this codebase? Reuse the helper, util, type, or pattern that already lives here; do not re-implement it. Reuse means calling it, or lifting the shared part into one place both callers use -- never a second copy that drifts. Two blocks that merely look alike but change for different reasons are not duplication; merging those is a coupling bug.
3. Stdlib does it? Use it.
4. Native platform feature covers it? Use it.
5. Already-installed dependency solves it? Use it; never add a new one for what a few lines can do.
6. Can it be one line? One line.
7. Only then: the minimum code that works.

The ladder runs AFTER you understand the problem, not instead of it: read the task and the code it touches, trace the real flow end to end, then climb. Bug fix = root cause not symptom: grep every caller and fix the shared function once.

${RUNG_TWO_PROBE}

${INTENSITY}

Never lazy about: understanding the problem, input validation at trust boundaries, error handling that prevents data loss, security, accessibility, or anything explicitly requested. A seam (a clean boundary, an injected dependency) is not bloat; cutting it is not simplification. Non-trivial logic leaves ONE runnable check behind. Mark deliberate shortcuts with a 'simplicity:' comment naming the ceiling and upgrade path.

Simplicity mode is ON by default. Disable it with /loop-spec:simplicity off or LOOP_SPEC_SIMPLICITY=0."

# Emit valid JSON via jq (hard dependency) rather than a hand-rolled escaper.
jq -n --arg ctx "$DIRECTIVE" \
  '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}'
