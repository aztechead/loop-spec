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
#   - no person is proven at the keyboard (`lib/harness.sh attended` answers false).
#     A headless cycle run carries no LOOP_SPEC_* name (the eval strips them and
#     passes `autonomous` as a prompt token), so the check above never fired, this
#     directive landed on top of the cycle skill, and the lead followed the one that
#     needs no driver call: it edited in place and never began a cycle (the dda2cca
#     wc-json run, docs/loop-spec/orchestrator-port-followup.md F1). The probe fails
#     safe: an unknown launch answers false. `ENABLED=1` in micro.conf is the
#     project's word and outranks an unknown launch, never a proven headless one, OR
#   - the project has no .loop-spec/ dir (never hijack unrelated projects).
#
# Environment variables:
#   LOOP_SPEC_MICRO     Set to "0" to disable (kill switch). Default: on.
#   LOOP_SPEC_EXECUTION_PROFILE=interactive  The operator's word that a person is
#                       present on a launch the harness does not stamp as `cli`.
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

# A person is proven, or this directive is not injected.
HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/harness.sh"
case "$(bash "$HARNESS" attended-reason 2>/dev/null || echo unknown)" in
  attended/*|interactive-profile|bridge/*) ;;
  unproven/*)
    if ! { [[ -f "$CONF_FILE" ]] && grep -q "ENABLED=1" "$CONF_FILE" 2>/dev/null; }; then
      printf '{}\n'
      exit 0
    fi
    ;;
  *)
    printf '{}\n'
    exit 0
    ;;
esac

# Resolve the plugin root so the directive carries a runnable ledger path.
# In CC hooks CLAUDE_PLUGIN_ROOT is set; fall back to this script's grandparent.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

case "${LOOP_SPEC_HARNESS:-claude}" in
  adk)
    # ADK has no slash commands: skills are entered through the skill tool.
    MICRO_CMD='load_skill({skill_name: "micro"})'
    INTAKE_CMD='load_skill({skill_name: "intake"})';;
  opencode)
    MICRO_CMD="/loop-spec/micro"; INTAKE_CMD="/loop-spec/intake";;
  codex)
    MICRO_CMD='$loop-spec-micro'; INTAKE_CMD='$loop-spec-intake';;
  *)
    MICRO_CMD="/loop-spec:micro"; INTAKE_CMD="/loop-spec:intake";;
esac

DIRECTIVE="MICRO MODE ACTIVE (default): for small ad-hoc tasks outside a running loop-spec cycle, apply the micro-cycle protocol inline (full definition: ${MICRO_CMD}).

1. Before editing any file, state 1-3 verifiable done-criteria bullets.
2. If the highest-leverage unknown would change what you build, ask exactly one sharp question; otherwise proceed.
3. Probe before asserting: any premise about external systems or unfamiliar code gets a read-only command or file read before you rely on it.
4. Test-first where a test fits: write the failing test before the fix; if there is no test surface, say so explicitly.
5. Run a post-change grounding review after the final edit: inspect the final diff, re-read every changed file plus the nearest affected caller/test/config/contract, and tie each criterion to concrete file:line evidence. A passing command alone is not grounding.
6. Then run the real verification command and show the output. Both gates must pass before DONE. For pass, copy each --criteria value byte-for-byte as exactly one --grounding prefix and use positive single line numbers: bash \"${PLUGIN_ROOT}/lib/adhoc-ledger.sh\" add --title \"...\" --criteria \"<criterion>\" --grounding \"<criterion> | repo: <file>:<positive line> | integration: <file>:<positive line>\" --verify \"<command you ran>\" --result pass. With no separate integration site use \"integration: none - <reason of at least 10 characters>\". Failed/partial results may omit grounding.
7. If the task outgrows ad-hoc scale (>~5 files, a new seam or dependency, criteria will not fit in 3 bullets, ambiguity survives one question), stop expanding scope and promote it via ${INTAKE_CMD}.
8. A repeated mistake becomes a permanent rule: bash \"${PLUGIN_ROOT}/lib/rules.sh\" add.

Micro mode is ON by default; disable with ${MICRO_CMD} off or LOOP_SPEC_MICRO=0."

# Emit valid JSON via jq (hard dependency) rather than a hand-rolled escaper.
jq -n --arg ctx "$DIRECTIVE" \
  '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}'
