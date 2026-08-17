#!/usr/bin/env bash
# harness.sh - Identify the agent harness loop-spec is running under.
#
# loop-spec ships for three peer harnesses from one source tree: Claude Code
# (including the Claude Agent SDK), opencode (https://opencode.ai), and Google's
# Agent Development Kit (https://google.github.io/adk-docs/). None of them is the
# reference implementation — each expresses the same cycle through the surface it
# actually has, and every difference between them is a branch keyed on this one
# probe rather than an ad hoc tool sniff. The adaptation contracts that consume
# these answers are skills/shared/claude-harness.md,
# skills/shared/opencode-harness.md, and skills/shared/adk-harness.md.
#
# Usage:
#   harness.sh detect      -> "claude" | "opencode" | "adk"
#   harness.sh cli         -> headless dispatch binary for THIS harness
#                             ("claude" | "opencode" | "adk"); loop-fleet rungs
#                             spawn this.
#   harness.sh subagents   -> "true" | "false"  (does the harness have a
#                             one-shot subagent tool taking {description,
#                             prompt, subagent_type}: claude has Agent,
#                             opencode has task, adk has the bundled
#                             dispatch_subagent tool over AgentTool — all three
#                             share that parameter shape)
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
#   1. LOOP_SPEC_HARNESS=claude|opencode|adk   explicit override. The bundled
#      opencode plugin (extensions/opencode/loop-spec.ts) and ADK bridge
#      (extensions/adk/loop_spec_adk/bridge.py) both export it into every shell
#      invocation — opencode through the documented `shell.env` plugin hook,
#      ADK through its session-aware Execute wrapper — so under those harnesses
#      this is the NORMAL signal, not just the escape hatch. Unknown values
#      fall through.
#   2. CLAUDECODE=1                  set by Claude Code's Bash tool -> claude
#   3. default                       -> claude (back-compat: every pre-2.14
#                                     install is a Claude Code plugin)
#
# Neither opencode nor ADK stamps an identifying variable of its own: opencode's
# shell env is a plain process.env spread plus plugin `shell.env` output, and ADK
# runs shell commands through whatever environment the embedding program built.
# Detection under both therefore REQUIRES the bundled bridge; there is no weak
# hint to fall back on, and inventing one would guess wrong on any machine with
# the other harness installed.
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
#   opencode and ADK publish no equivalent stamp, so they assert the profile on the
#   channel that already exists: `opencode run` and `adk run` are one-shot, and the
#   bundled launch paths export LOOP_SPEC_NON_INTERACTIVE=1 for one-shot runs
#   (ADK: loop.py and issue-intake.sh; direct `adk run` callers set it explicitly,
#   unlike persistent `adk web` / `adk api_server`). That is an assertion rather than a proof, which is why it
#   ranks below a stamp and above an inherited EXECUTION_PROFILE claim.
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
    claude|opencode|adk) echo "${LOOP_SPEC_HARNESS}"; return ;;
  esac
  if [[ "${CLAUDECODE:-}" == "1" ]]; then
    echo "claude"; return
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
    # harnesses (claude -p / opencode run --format json / adk run --output jsonl).
    # Kept as a separate verb so call sites read as intent (which binary do I
    # spawn) and so a future harness where the two diverge only changes here.
    detect
    ;;
  subagents)
    # Capability, not harness name: all three harnesses expose a one-shot
    # dispatch taking {description, prompt, subagent_type} — claude's Agent,
    # opencode's task, and the dispatch_subagent tool the ADK bridge builds over
    # AgentTool — so the subagent rungs stay live everywhere. This stays a verb
    # rather than a constant because it is a CAPABILITY question: a harness that
    # cannot dispatch must answer false and fall back to the inline rung.
    case "$(detect)" in
      claude|opencode|adk) echo "true" ;;
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
