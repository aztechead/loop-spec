#!/usr/bin/env bash
# harness.sh - Identify the agent harness loop-spec is running under.
#
# loop-spec ships as a Claude Code plugin, a pi package (https://pi.dev), AND
# an opencode install (https://opencode.ai). The harnesses expose different
# surfaces (pi has no Agent/subagent tool, no AskUserQuestion, no TaskCreate,
# no hooks.json; opencode has native equivalents for most of them but no agent
# teams or Workflow tool), so skills and libs branch on this one probe instead
# of sniffing tools ad hoc. The adaptation contracts that consume these answers
# are skills/shared/pi-harness.md and skills/shared/opencode-harness.md.
#
# Usage:
#   harness.sh detect      -> "claude" | "pi" | "opencode"
#   harness.sh cli         -> headless dispatch binary for THIS harness
#                             ("claude" | "pi" | "opencode"); loop-fleet rungs
#                             spawn this.
#   harness.sh subagents   -> "true" | "false"  (does the harness have a
#                             one-shot subagent tool taking {description,
#                             prompt, subagent_type}: claude has Agent,
#                             opencode has task (same parameter shape),
#                             pi has none)
#
# Detection order (first match wins):
#   1. LOOP_SPEC_HARNESS=claude|pi|opencode   explicit override. The bundled
#      pi extension (extensions/pi/loop-spec.ts) and opencode plugin
#      (extensions/opencode/loop-spec.ts) both export it into every bash
#      invocation (pi: command prepend; opencode: the documented `shell.env`
#      plugin hook), so under those harnesses this is the NORMAL signal,
#      not just the escape hatch. Unknown values fall through.
#   2. CLAUDECODE=1                  set by Claude Code's Bash tool -> claude
#   3. PI_CODING_AGENT_DIR set      pi config-dir override present -> pi
#      (weak hint: only reachable when the extension env is absent; opencode
#      sets no identifying env var of its own — its bash env is a plain
#      process.env spread plus plugin `shell.env` output — so opencode has
#      no equivalent hint and detection there REQUIRES the bundled plugin)
#   4. default                       -> claude (back-compat: every pre-2.14
#                                     install is a Claude Code plugin)
#
# detect/cli/subagents always exit 0 with the answer on stdout; an unknown
# command exits 2.
set -euo pipefail

detect() {
  case "${LOOP_SPEC_HARNESS:-}" in
    claude|pi|opencode) echo "${LOOP_SPEC_HARNESS}"; return ;;
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
    # Today the harness name IS the headless binary name for all three
    # harnesses (claude -p / pi --mode json / opencode run --format json).
    # Kept as a separate verb so call sites read as intent (which binary do I
    # spawn) and so a future harness where the two diverge only changes here.
    detect
    ;;
  subagents)
    # Capability, not harness name: claude's Agent and opencode's task tool
    # share the {description, prompt, subagent_type} call shape, so both keep
    # the subagent rungs; pi has no one-shot dispatch tool at all.
    case "$(detect)" in
      claude|opencode) echo "true" ;;
      *) echo "false" ;;
    esac
    ;;
  *)
    echo "harness.sh: unknown command '${cmd}' (detect|cli|subagents)" >&2
    exit 2
    ;;
esac
