#!/usr/bin/env bash
# Stop hook: a /loop-spec:cycle invocation begins a cycle or declines; it never drifts.
#
# Claude Code contract:
#   exit 0  = allow
#   exit 2  = block (with stderr message shown to the model)
#
# hooks/team/invocation-stamp.sh writes .loop-spec/invocation-stamp.json at prompt time
# for every /loop-spec:<skill> prompt, and `cycle-driver.sh start` consumes the stamp
# (deletes it) as its first act. A `skill: cycle` stamp still present at Stop is a
# session that loaded the cycle skill and never called the driver. The dda2cca wc-json
# eval run did that: the ambient micro directive and the cycle skill both loaded, the
# lead followed the one that needs no driver call, edited in place, and stopped with
# no branch, no result, and no `begin` (docs/loop-spec/orchestrator-port-followup.md,
# F1). From inside the session that looks like success; the caller reads a run with
# no cycle. This hook refuses the stop until the driver runs or the route declines.
#
# Stands down (exit 0) when:
#   - the project has no .loop-spec/ dir (never hijack unrelated projects)
#   - no stamp, or the stamp names another skill (auto arms a run that
#     route-terminal-guard.sh holds accountable; micro, debug, and intake consume
#     nothing and are not the cycle)
#   - .loop-spec/last-result.json is newer than the stamp: a route exit was published
#     (write-terminal for a request that is not repository work), which is the one
#     honest way past the driver
#   - the stamp is older than LOOP_SPEC_STAMP_MAX_AGE_MIN (default 30): the driver
#     ignores such a stamp too, and one left by a session that died is not this
#     session's contract
#   - stop_hook_active: Claude Code is already continuing from a previous block
#
# Fail-open: missing python3, an unreadable stamp, or a malformed payload -> exit 0.
#
# No kill switch of its own: a guard adds no variable (orchestrator-port-principles.md,
# rule 9). LOOP_SPEC_INVOCATION_STAMP=0 stops the stamp, and with it this deny.
#
# Environment variables (all optional):
#   LOOP_SPEC_STAMP_MAX_AGE_MIN   Stand-down age in minutes, shared with the driver.
#                                 Default: 30.
#   CLAUDE_PROJECT_DIR            Project root; default $PWD.
set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
if [[ ! -d "${PROJECT_DIR}/.loop-spec" && ! -d "$PWD/.loop-spec" ]]; then
  exit 0
fi
[[ -d "${PROJECT_DIR}/.loop-spec" ]] || PROJECT_DIR="$PWD"

# Fail-open: any unexpected error must not block the session.
trap 'exit 0' ERR
command -v python3 >/dev/null 2>&1 || exit 0

STAMP="$PROJECT_DIR/.loop-spec/invocation-stamp.json"
[[ -f "$STAMP" ]] || exit 0

INPUT="$(cat 2>/dev/null || true)"
if printf '%s' "$INPUT" | python3 -c \
  "import json,sys; sys.exit(0 if json.load(sys.stdin).get('stop_hook_active') else 1)" 2>/dev/null; then
  exit 0
fi

# One line: `deny <args>` when the stamp is an unconsumed cycle invocation, else `allow`.
verdict="$(python3 - "$STAMP" "$PROJECT_DIR/.loop-spec/last-result.json" "${LOOP_SPEC_STAMP_MAX_AGE_MIN:-30}" <<'PY'
import json, os, sys, time
stamp_path, result_path, max_age = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    stamp = json.load(open(stamp_path))
    ts = int(stamp.get("ts") or 0)
    max_age = int(max_age)
except (OSError, ValueError, TypeError, AttributeError):
    print("allow"); sys.exit(0)
if stamp.get("skill") != "cycle":
    print("allow"); sys.exit(0)
if time.time() - ts > max_age * 60:
    print("allow"); sys.exit(0)
if os.path.isfile(result_path) and os.path.getmtime(result_path) >= ts:
    print("allow"); sys.exit(0)
print("deny " + str(stamp.get("args") or ""))
PY
)"
[[ "${verdict%% *}" == "deny" ]] || exit 0
args="${verdict#deny}"; args="${args# }"

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
cat >&2 <<MESSAGE
DENY: this session was invoked as /loop-spec:cycle and never began the cycle.
.loop-spec/invocation-stamp.json (skill: cycle) is still present; the driver consumes
it as its first act, so no driver call happened. Whatever was edited in this session
is not the cycle's work: no feature, no branch, no result.

Begin the cycle now (skills/cycle/SKILL.md, step 1), then act on .action:

  st="\$(bash "${PLUGIN_ROOT}/lib/cycle-driver.sh" begin -- "${args}")"

A request that is not repository work is declined with the write-terminal snippet in
skills/shared/route-exit-contract.md (protocol-mismatch), which publishes
.loop-spec/last-result.json; that is the only honest way past the driver. The ad-hoc
micro protocol stands down under /loop-spec:cycle: it is not a way to finish this run.
MESSAGE
exit 2
