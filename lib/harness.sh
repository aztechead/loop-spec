#!/usr/bin/env bash
# harness.sh - Identify the agent harness loop-spec is running under.
#
# loop-spec ships as a Claude Code plugin AND a pi package (https://pi.dev).
# The two harnesses expose different surfaces (pi has no Agent/subagent tool,
# no AskUserQuestion, no TaskCreate, no hooks.json), so skills and libs branch
# on this one probe instead of sniffing tools ad hoc. The adaptation contract
# that consumes these answers is skills/shared/pi-harness.md.
#
# Usage:
#   harness.sh detect      -> "claude" | "pi"
#   harness.sh cli         -> headless dispatch binary for THIS harness
#                             ("claude" | "pi"); loop-fleet rungs spawn this.
#   harness.sh subagents   -> "true" | "false"  (does the harness have the
#                             Agent tool: claude -> true, pi -> false)
#
# Detection order (first match wins):
#   1. LOOP_SPEC_HARNESS=claude|pi   explicit override. The bundled pi
#      extension (extensions/pi/loop-spec.ts) exports LOOP_SPEC_HARNESS=pi
#      into every bash invocation, so under pi this is the NORMAL signal,
#      not just the escape hatch. Unknown values fall through.
#   2. CLAUDECODE=1                  set by Claude Code's Bash tool -> claude
#   3. PI_CODING_AGENT_DIR set      pi config-dir override present -> pi
#      (weak hint: only reachable when the extension env is absent)
#   4. default                       -> claude (back-compat: every pre-2.14
#                                     install is a Claude Code plugin)
#
# detect/cli/subagents always exit 0 with the answer on stdout; an unknown
# command exits 2.
set -euo pipefail

detect() {
  case "${LOOP_SPEC_HARNESS:-}" in
    claude|pi) echo "${LOOP_SPEC_HARNESS}"; return ;;
  esac
  if [[ "${CLAUDECODE:-}" == "1" ]]; then
    echo "claude"; return
  fi
  if [[ -n "${PI_CODING_AGENT_DIR:-}" ]]; then
    echo "pi"; return
  fi
  echo "claude"
}

cmd="${1:-}"
case "$cmd" in
  detect)
    detect
    ;;
  cli)
    # Today the harness name IS the headless binary name for both harnesses.
    # Kept as a separate verb so call sites read as intent (which binary do I
    # spawn) and so a future harness where the two diverge only changes here.
    detect
    ;;
  subagents)
    [[ "$(detect)" == "claude" ]] && echo "true" || echo "false"
    ;;
  *)
    echo "harness.sh: unknown command '${cmd}' (detect|cli|subagents)" >&2
    exit 2
    ;;
esac
