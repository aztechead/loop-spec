#!/usr/bin/env bash
# micro-inject.sh - Inject the micro-cycle protocol directive on SessionStart.
# Reads .loop-spec/micro.conf from CLAUDE_PROJECT_DIR (or CWD).
#
# DEFAULT IS ON (same polarity as grill-inject.sh): for ad-hoc work outside the
# cycle, the session should carry the micro-cycle invariants (stated done-criteria,
# grounded claims, test-first, evidence-before-done, mistakes-become-rules) without
# the user having to invoke /loop-spec:micro every time. The skill defines the
# protocol; this hook makes it ambient; adhoc-verify-guard.sh enforces the
# grounding and validation halves at Stop.
#
# Suppressed only when:
#   - .loop-spec/micro.conf contains ENABLED=0, OR
#   - LOOP_SPEC_MICRO=0 is set (session-level kill switch), OR
#   - LOOP_SPEC_AUTONOMOUS=1 is set (headless runs are cycle/loop-runner driven;
#     the cycle phases own these invariants at feature scale), OR
#   - the project has no .loop-spec/ dir (never hijack unrelated projects).
#
# Environment variables:
#   LOOP_SPEC_MICRO     Set to "0" to disable (kill switch). Default: on.
#   CLAUDE_PROJECT_DIR  Project root to find conf file. Defaults to CWD.

set -euo pipefail

# Fail-open: any unexpected error must not block the session.
trap 'exit 0' ERR

# Kill switch.
if [[ "${LOOP_SPEC_MICRO:-1}" == "0" ]]; then
  printf '{}\n'
  exit 0
fi

# Autonomous mode: cycle/loop-runner machinery owns the invariants.
if [[ "${LOOP_SPEC_AUTONOMOUS:-0}" == "1" ]]; then
  printf '{}\n'
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-.}"

# Self-scope: only act inside loop-spec projects.
if [[ ! -d "${PROJECT_DIR}/.loop-spec" ]]; then
  printf '{}\n'
  exit 0
fi

CONF_FILE="${PROJECT_DIR}/.loop-spec/micro.conf"

# Opt-out: if the conf file exists AND pins ENABLED=0, stay silent.
# Absent conf file => default ON (inject).
if [[ -f "$CONF_FILE" ]] && grep -q "ENABLED=0" "$CONF_FILE" 2>/dev/null; then
  printf '{}\n'
  exit 0
fi

# Resolve the plugin root so the directive carries a runnable ledger path.
# In CC hooks CLAUDE_PLUGIN_ROOT is set; fall back to this script's grandparent.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

case "${LOOP_SPEC_HARNESS:-claude}" in
  pi)
    MICRO_CMD="/skill:micro"; INTAKE_CMD="/skill:intake"; AUTO_CMD="/skill:auto";;
  opencode)
    MICRO_CMD="/loop-spec/micro"; INTAKE_CMD="/loop-spec/intake"; AUTO_CMD="/loop-spec/auto";;
  *)
    MICRO_CMD="/loop-spec:micro"; INTAKE_CMD="/loop-spec:intake"; AUTO_CMD="/loop-spec:auto";;
esac

DIRECTIVE="MICRO MODE ACTIVE (default): for small ad-hoc tasks outside a running loop-spec cycle, apply the micro-cycle protocol inline (full definition: ${MICRO_CMD}).

1. Before editing any file, state 1-3 verifiable done-criteria bullets.
2. If the highest-leverage unknown would change what you build, ask exactly one sharp question; otherwise proceed.
3. Probe before asserting: any premise about external systems or unfamiliar code gets a read-only command or file read before you rely on it.
4. Test-first where a test fits: write the failing test before the fix; if there is no test surface, say so explicitly.
5. Run a post-change grounding review after the final edit: inspect the final diff, re-read every changed file plus the nearest affected caller/test/config/contract, and tie each criterion to concrete file:line evidence. A passing command alone is not grounding.
6. Then run the real verification command and show the output. Both gates must pass before DONE. Record them: bash \"${PLUGIN_ROOT}/lib/adhoc-ledger.sh\" add --title \"...\" --criteria \"...\" --grounding \"<criterion | repo: file:line | integration: file:line>\" --verify \"<command you ran>\" --result pass|fail|partial
7. If the task outgrows ad-hoc scale (>~5 files, a new seam or dependency, criteria will not fit in 3 bullets, ambiguity survives one question), stop expanding scope and promote it via ${INTAKE_CMD}.
8. A repeated mistake becomes a permanent rule: bash \"${PLUGIN_ROOT}/lib/rules.sh\" add.

During explicit autonomous routing (${AUTO_CMD}) this ambient directive stands down until the router delegates; the selected protocol owns the task. Inside a running cycle this protocol also stands down - the phases own these invariants at feature scale. Micro mode is ON by default; disable with ${MICRO_CMD} off or LOOP_SPEC_MICRO=0."

# Emit valid JSON via jq (hard dependency) rather than a hand-rolled escaper.
jq -n --arg ctx "$DIRECTIVE" \
  '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}'
