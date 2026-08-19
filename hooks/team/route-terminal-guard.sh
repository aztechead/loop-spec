#!/usr/bin/env bash
# Stop hook: no route ends without a terminal result.
#
# Claude Code contract:
#   exit 0  = allow
#   exit 2  = block (with stderr message shown to user)
#
# /loop-spec:auto arms a run (lib/task-route.sh -> cycle-result.sh begin) before the
# routed skill starts, and only a published terminal result disarms it. An armed run
# at Stop time therefore means the route ended without writing
# .loop-spec/last-result.json -- the pointer a headless caller gates success on. That
# gap is invisible from inside the session: the model reports success, exits 0, and the
# supervisor reads the missing pointer as a failed run. This hook is what makes it
# visible, by refusing the stop until some honest result is published.
#
# Stands down (exit 0) when:
#   - LOOP_SPEC_ROUTE_GUARD=0 (kill switch)
#   - the project has no .loop-spec/ dir (never hijack unrelated projects)
#   - the armed run is not autonomous. An interactive cycle ends turns to ask the
#     human questions, and blocking those stops would fight the orchestrator; the
#     contract this guard protects is the headless one.
#   - the armed run is older than LOOP_SPEC_ROUTE_GUARD_MAX_AGE_MIN (default 720).
#     A record left by a run that died days ago is not this session's contract.
#   - stop_hook_active: Claude Code is already continuing from a previous block.
#
# Fail-open: an unreadable probe answer, missing lib, or malformed payload -> exit 0.
# An armed run whose age cannot be parsed reports 0 and blocks, because the loud
# direction is the one that keeps an unattended run accountable.
#
# Environment variables (all optional):
#   LOOP_SPEC_ROUTE_GUARD              Set to "0" to disable. Default: 1 (active).
#   LOOP_SPEC_ROUTE_GUARD_MAX_AGE_MIN  Stand-down age in minutes. Default: 720.
#   LOOP_SPEC_CYCLE_RESULT_BIN         Path to lib/cycle-result.sh (tests override it).
#   LOOP_SPEC_ROUTE_GUARD_TRACE_LOG    Path for trace log.
#                                      Default: /tmp/claude-hooks/loop-spec-route-guard-trace.log
set -euo pipefail

if [[ "${LOOP_SPEC_ROUTE_GUARD:-1}" == "0" ]]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CYCLE_RESULT_BIN="${LOOP_SPEC_CYCLE_RESULT_BIN:-$SCRIPT_DIR/../../lib/cycle-result.sh}"
TRACE_LOG="${LOOP_SPEC_ROUTE_GUARD_TRACE_LOG:-/tmp/claude-hooks/loop-spec-route-guard-trace.log}"
MAX_AGE_MIN="${LOOP_SPEC_ROUTE_GUARD_MAX_AGE_MIN:-720}"

# Scope: only active in projects that use loop-spec.
if [[ ! -d "${PROJECT_DIR}/.loop-spec" && ! -d "$PWD/.loop-spec" ]]; then
  exit 0
fi
[[ -d "${PROJECT_DIR}/.loop-spec" ]] || PROJECT_DIR="$PWD"

# Fail-open: any unexpected error must not block the session.
trap 'exit 0' ERR

trace() {
  mkdir -p "$(dirname "$TRACE_LOG")" 2>/dev/null || true
  printf '%s|route-terminal-guard|%s|%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >> "$TRACE_LOG" 2>/dev/null || true
}

INPUT="$(cat 2>/dev/null || true)"
if printf '%s' "$INPUT" | python3 -c \
  "import json,sys; sys.exit(0 if json.load(sys.stdin).get('stop_hook_active') else 1)" 2>/dev/null; then
  trace "skip" "stop_hook_active"
  exit 0
fi

[[ -f "$CYCLE_RESULT_BIN" ]] || { trace "fail-open" "no cycle-result.sh"; exit 0; }
answer="$(bash "$CYCLE_RESULT_BIN" state --result-root "$PROJECT_DIR" 2>/dev/null || true)"
state="${answer%% *}"
if [[ "$state" != "unaccounted" ]]; then
  trace "allow" "${answer:-no probe answer}"
  exit 0
fi

age_field="${answer#*ageSeconds=}"
age_seconds="${age_field%% *}"
[[ "$age_seconds" =~ ^[0-9]+$ ]] || age_seconds=0
autonomous_field="${answer#*autonomous=}"
autonomous="${autonomous_field%% *}"
[[ "$MAX_AGE_MIN" =~ ^[0-9]+$ ]] || MAX_AGE_MIN=720

if [[ "$autonomous" != "true" ]]; then
  trace "allow" "armed run is interactive; the human owns its ending"
  exit 0
fi
if (( age_seconds > MAX_AGE_MIN * 60 )); then
  trace "allow" "armed ${age_seconds}s ago, past the ${MAX_AGE_MIN}m stand-down"
  exit 0
fi

trace "deny" "$answer"
cat >&2 <<'MESSAGE'
DENY: this autonomous run was routed but never published a terminal result, so
.loop-spec/last-result.json does not exist. A headless caller gates success on that
pointer and reads its absence as a failed run -- including when the work went fine.

Publish the result that matches what actually happened, then stop:

  bash lib/cycle-result.sh write-terminal --result-root <repo root> \
    --cycle-type <full|micro|debug> --status <status> --outcome <outcome> \
    --title "<title>" --converged <true|false> --summary "<what happened>"

- The request was not repository work and you changed nothing: --status escalated
  --outcome protocol-mismatch --converged false --reason "<why this is not a
  code-change task>". Do not use this to decline a rebase, branch sync,
  merge-conflict resolution, re-review, or chore the router already accepted.
- You completed a full cycle: `--outcome delivered` (alias for
  `write <feature_dir> --status completed`). Do not hand-build `converged`.
- You stopped part-way: --status failed --outcome interrupted --converged false.
- You completed a reduced route: finish that route's own delivery contract
  (PR included) and let it emit the result.

Leaving the route to finish the task by hand is the failure this guard exists to
catch: the work may be right, but the run is unaccountable without the record.
(To disable this check, set LOOP_SPEC_ROUTE_GUARD=0.)
MESSAGE
exit 2
