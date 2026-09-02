#!/usr/bin/env bash
# Print the agent-team capability MODE for the running harness.
#
# Output is exactly one word on stdout:
#   none      Agent teams are off. CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS != 1.
#             -> phases use the no-teams fallback (skills/shared/dispatch.md).
#   explicit  Legacy agent teams (CC < 2.1.178): the TeamCreate / TeamDelete tools
#             exist. Each phase creates and tears down its own named team.
#   implicit  Modern agent teams (CC >= 2.1.178): TeamCreate / TeamDelete were
#             REMOVED. Every session has one implicit team; teammates are spawned
#             directly via Agent({name}) and addressed with SendMessage. See
#             skills/shared/dispatch.md.
#
# The 2.1.178 boundary is the Claude Code release that removed TeamCreate /
# TeamDelete ("every session now has one implicit team -- spawn teammates
# directly with the Agent tool's name parameter"). loop-spec's explicit-team
# call sites throw on that harness, so the cycle must route to the implicit
# model instead of attempting the removed tools.
#
# Usage:
#   teams-capability.sh [version]
#     [version]  Optional explicit version string (e.g. "2.1.181") for testing.
#                When omitted, the version is read from `claude --version`.
#
# Policy and overrides (checked in order, first wins):
#   LOOP_SPEC_MAX_PARALLEL_SUBAGENTS=N            forces no-teams bounded waves.
#   LOOP_SPEC_TEAMS_MODE=none|explicit|implicit   forces the mode verbatim.
#
# Exits 0 with the answer on stdout, or propagates an invalid explicit harness
# as a usage error.
set -euo pipefail

MIN_IMPLICIT="2.1.178"

# A deployment-wide one-shot cap cannot be enforced inside a persistent team.
# Force the bounded no-teams path whenever the operator supplies it.
if [[ -n "${LOOP_SPEC_MAX_PARALLEL_SUBAGENTS:-}" ]]; then
  [[ "$LOOP_SPEC_MAX_PARALLEL_SUBAGENTS" =~ ^[1-9][0-9]*$ ]] || {
    echo "none"
    exit 0
  }
  echo "none"
  exit 0
fi

# Harness gate: named, addressable teammates are a Claude Code surface today.
# opencode's resumable task sessions and ADK's AgentTool dispatch both return a
# result to the caller and nothing more — no named peers, no peer messaging, no
# shared task list — so the mode is `none` on every non-claude harness even when
# the experimental flag is exported globally (and a `claude` binary happens to be
# on PATH; without this gate that combination would mis-resolve to `implicit` and
# every spawn would throw). skills/shared/opencode-harness.md and
# skills/shared/adk-harness.md carry the substitution rules.
#
# This gate runs BEFORE LOOP_SPEC_TEAMS_MODE. An operator override can turn a
# capability OFF anywhere, but it cannot conjure one that the harness does not
# have: `LOOP_SPEC_HARNESS=adk LOOP_SPEC_TEAMS_MODE=implicit` must not answer
# `implicit` and route EXECUTE onto a team rung whose every spawn throws, which
# is precisely the mis-resolution the comment above says this gate exists to
# prevent. Absence of a surface is a fact; only a negative override is honored here.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
harness="$(bash "$SCRIPT_DIR/harness.sh" detect)" || exit $?
if [[ "$harness" != "claude" ]]; then
  echo "none"
  exit 0
fi

# Hard override for constrained / test environments.
if [[ -n "${LOOP_SPEC_TEAMS_MODE:-}" ]]; then
  case "${LOOP_SPEC_TEAMS_MODE}" in
    none|explicit|implicit) echo "${LOOP_SPEC_TEAMS_MODE}"; exit 0 ;;
    *) echo "none"; exit 0 ;;
  esac
fi

# Necessary gate: the experimental flag must be opted in. Without it there is no
# team surface in any harness generation, so the mode is `none` regardless of version.
if [[ "${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS:-}" != "1" ]]; then
  echo "none"
  exit 0
fi

ver="${1:-}"
if [[ -z "$ver" ]]; then
  ver="$(claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
fi
[[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || ver=""

# Unknown version: fail safe to no teams. Team dispatch requires named agents,
# shared task metadata, messaging, and claim serialization; guessing either
# generation can strand EXECUTE. The one-shot subagent path works at any width.
if [[ -z "$ver" ]]; then
  echo "none"
  exit 0
fi

# implicit iff ver >= MIN_IMPLICIT (sort -V ascending puts MIN first when ver >= MIN)
if [[ "$(printf '%s\n%s\n' "$ver" "$MIN_IMPLICIT" | sort -V | head -1)" == "$MIN_IMPLICIT" ]]; then
  echo "implicit"
else
  echo "explicit"
fi
