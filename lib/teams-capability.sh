#!/usr/bin/env bash
# Print the agent-team capability MODE for the running harness.
#
# Output is exactly `none`: persistent teams cannot enforce the finite resource
# cap, so phases use bounded one-shot dispatch (`skills/shared/dispatch.md`).
#
# Usage:
#   teams-capability.sh [ignored-version]
#     The optional argument remains accepted by offline callers; resource policy
#     selects the bounded path before version capability can affect dispatch.
#
# Policy: all finite caps use one-shot waves, whose width the lead can enforce.
# Persistent teams have no equivalent global bound, so a mode override may only
# select `none`; it cannot turn a bounded dispatch back into an unbounded one.
#
# Exits 0 with the answer on stdout, or propagates an invalid explicit harness
# as a usage error.
set -euo pipefail

# A deployment-wide one-shot cap cannot be enforced inside a persistent team.
# The resolver always returns a finite cap, including its conservative default.
subagent_cap="$(bash "$(dirname "${BASH_SOURCE[0]}")/resource-bounds.sh" get subagents)" || exit $?

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

# The cap is deliberately finite even when it is greater than one. Teams do not
# consume this cap, so allowing them here would make the advertised limit false.
echo "none"
exit 0
