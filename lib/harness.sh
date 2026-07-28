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
#   harness.sh entrypoint  -> the raw CLAUDE_CODE_ENTRYPOINT stamp, or
#                             "unknown" when unset (see below)
#   harness.sh headless    -> "true" | "false" (is this a one-shot, unattended
#                             invocation with no human and no persistent
#                             session? the single execution-profile answer)
#   harness.sh loop-runtime -> "true" | "false" (can this invocation keep a
#                              synchronous, long-running fleet tool call alive?)
#   harness.sh loop-runtime-reason -> stable reason for rung telemetry
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
# Headless proof (`entrypoint` / `headless`):
#   Claude Code stamps CLAUDE_CODE_ENTRYPOINT into every child process it spawns,
#   naming how the session was launched. Three of its values are one-shot agent
#   invocations with no interactive session behind them:
#     sdk-cli  `claude -p` / `--print` (the CLI rewrites the `cli` stamp to
#              `sdk-cli` when print mode is on)
#     sdk-py   the Claude Agent SDK for Python (`claude-agent-sdk`)
#     sdk-ts   the Claude Agent SDK for TypeScript
#   `cli` is the interactive TUI; the remaining values (mcp, bench, remote,
#   claude-desktop, claude-code-github-action, ...) are neither proven headless
#   nor proven interactive here, so they stay unknown and fail safe.
#
#   This matters because it is DETERMINISTIC. Before it, an unattended run had to
#   remember to export LOOP_SPEC_NON_INTERACTIVE=1; forgetting it left the
#   execution profile "unproven", and a stale LOOP_SPEC_EXECUTION_PROFILE=interactive
#   export could actively claim a persistent runtime that a `claude -p` job does
#   not have — which is how a headless run gets routed onto the loop-fleet rung it
#   cannot execute. A stamped headless entrypoint is a fact and outranks that claim.
#
# detect/cli/subagents/entrypoint/headless always exit 0 with the answer on
# stdout; an unknown command exits 2.
set -euo pipefail

# Entrypoint stamps that prove a one-shot, unattended invocation.
HEADLESS_ENTRYPOINTS=" sdk-cli sdk-py sdk-ts "

entrypoint() {
  local ep="${CLAUDE_CODE_ENTRYPOINT:-}"
  if [[ -n "$ep" ]]; then echo "$ep"; else echo "unknown"; fi
}

# "true" when the entrypoint stamp itself proves a headless invocation.
entrypoint_headless() {
  local ep
  ep="$(entrypoint)"
  if [[ "$HEADLESS_ENTRYPOINTS" == *" $ep "* ]]; then echo "true"; else echo "false"; fi
}

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
  entrypoint)
    entrypoint
    ;;
  headless)
    # One execution-profile answer, from strongest evidence down:
    #   1. operator assertion (LOOP_SPEC_NON_INTERACTIVE / EXECUTION_PROFILE=headless)
    #   2. the harness's own entrypoint stamp
    #   3. EXECUTION_PROFILE=interactive, or no evidence -> not headless
    if [[ "${LOOP_SPEC_NON_INTERACTIVE:-}" == "1" || "${LOOP_SPEC_EXECUTION_PROFILE:-}" == "headless" ]]; then
      echo "true"
    else
      entrypoint_headless
    fi
    ;;
  loop-runtime|loop-runtime-reason)
    runtime="false"
    reason="unproven-runtime"
    case "${LOOP_SPEC_LOOP_RUNTIME:-}" in
      # Absolute: the integrator asserting their wrapper can (or cannot) hold a
      # foreground call open. Outranks every probe below, including the stamp.
      1) runtime="true"; reason="operator-enabled" ;;
      0) runtime="false"; reason="operator-disabled" ;;
      *)
        if [[ "${LOOP_SPEC_NON_INTERACTIVE:-}" == "1" ]]; then
          runtime="false"
          reason="headless/non-interactive"
        elif [[ "$(entrypoint_headless)" == "true" ]]; then
          # Proven headless by the harness itself. Deliberately checked BEFORE
          # EXECUTION_PROFILE: a stamped `claude -p` / SDK job has no persistent
          # runtime no matter what an inherited `interactive` export claims.
          runtime="false"
          reason="headless/$(entrypoint)"
        else
          case "${LOOP_SPEC_EXECUTION_PROFILE:-}" in
            interactive) runtime="true"; reason="interactive-profile" ;;
            headless) runtime="false"; reason="headless/non-interactive" ;;
          esac
        fi
        ;;
    esac
    if [[ "$cmd" == "loop-runtime" ]]; then echo "$runtime"; else echo "$reason"; fi
    ;;
  *)
    echo "harness.sh: unknown command '${cmd}' (detect|cli|subagents|entrypoint|headless|loop-runtime|loop-runtime-reason)" >&2
    exit 2
    ;;
esac
