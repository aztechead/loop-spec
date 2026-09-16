#!/usr/bin/env bash
# Read .loop-spec/runtime.json; when workflowsAvailable=false, name the fallback the
# cycle runs instead and the condition under which the Workflow tool would be on.
# Non-fatal, printed once per cycle start (lib/graph/driver.py cmd_start).
#
# Why: the old text named a TeamCreate fallback and a /permissions fix. Under the Agent
# SDK the tool is simply not exposed and teams were off, so a live run read four bare
# "unavailable" lines with no idea what was lost or whether the fallback was equivalent.
set -euo pipefail

RUNTIME=".loop-spec/runtime.json"
[[ -f "$RUNTIME" ]] || exit 0

avail="$(jq -r '.workflowsAvailable // false' "$RUNTIME")"
[[ "$avail" != "true" ]] || exit 0

teams="$(jq -r '.teamsMode // "none"' "$RUNTIME")"
fallback="agent teams"
[[ "$teams" != "none" ]] || fallback="bounded one-shot subagent waves"

cat <<EOF
[loop-spec] Workflow tool off for this session; fan-out runs as $fallback instead. Same phases, gates, and artifacts; only the parallel width differs. The tool is on only in a Claude Code CLI session >= 2.1.154 with \`claude\` on PATH; the Agent SDK, opencode, ADK, and codex never expose it. LOOP_SPEC_WORKFLOWS_AVAILABLE=1 forces it on.
EOF
exit 0
