#!/usr/bin/env bash
# Print the agent-team capability MODE for the running Claude Code harness.
#
# Output is exactly one word on stdout:
#   none      Agent teams are off. CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS != 1.
#             -> phases use the no-teams fallback (skills/shared/no-teams-fallback.md).
#   explicit  Legacy agent teams (CC < 2.1.178): the TeamCreate / TeamDelete tools
#             exist. Each phase creates and tears down its own named team.
#   implicit  Modern agent teams (CC >= 2.1.178): TeamCreate / TeamDelete were
#             REMOVED. Every session has one implicit team; teammates are spawned
#             directly via Agent({name}) and addressed with SendMessage. See
#             skills/shared/implicit-team-mode.md.
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
# Overrides (checked in order, first wins):
#   LOOP_SPEC_TEAMS_MODE=none|explicit|implicit   forces the mode verbatim.
#
# Always exits 0; the answer is on stdout.
set -euo pipefail

MIN_IMPLICIT="2.1.178"

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

# Unknown version: assume the modern (implicit) harness. New installs are the
# common case, and `implicit` degrades safely -- if the explicit tools turn out
# to still exist, the lead simply never calls TeamCreate. Guessing `explicit`
# on an unknown-but-modern harness would instead throw on the removed tools.
if [[ -z "$ver" ]]; then
  echo "implicit"
  exit 0
fi

# implicit iff ver >= MIN_IMPLICIT (sort -V ascending puts MIN first when ver >= MIN)
if [[ "$(printf '%s\n%s\n' "$ver" "$MIN_IMPLICIT" | sort -V | head -1)" == "$MIN_IMPLICIT" ]]; then
  echo "implicit"
else
  echo "explicit"
fi
