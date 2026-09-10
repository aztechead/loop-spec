#!/usr/bin/env bash
# Stop hook: a /loop-spec:cycle invocation begins a cycle or declines, and a phase it
# opened closes through the driver; the session never drifts out of either.
#
# Claude Code contract:
#   exit 0  = allow
#   exit 2  = block (with stderr message shown to the model)
#
# Two states deny the stop, both read from files the driver owns:
#   1. An unconsumed cycle stamp. hooks/team/invocation-stamp.sh writes
#      .loop-spec/invocation-stamp.json at prompt time for every /loop-spec:<skill>
#      prompt, and `cycle-driver.sh start` consumes the stamp (deletes it) as its
#      first act. A `skill: cycle` stamp still present at Stop is a session that loaded
#      the cycle skill and never called the driver. The dda2cca wc-json eval run did
#      that: the ambient micro directive and the cycle skill both loaded, the lead
#      followed the one that needs no driver call, edited in place, and stopped with no
#      branch, no result, and no `begin` (port audit 1,
#      F1). From inside the session that looks like success; the caller reads a run
#      with no cycle.
#   2. An open phase. lib/graph/engine.py emits phase_start when a phase opens and
#      phase_end when the driver closes it; every driver answer that ends a session
#      (HANDOFF, REWIND, PAUSED, DONE, escalate) publishes .loop-spec/last-result.json
#      after that. A feature whose newest phase_start has no later phase_end and no
#      later result is a phase the lead walked out of: the f0959f6 wc-json run ended
#      its second round on `phase_start oneshot` after the exit gate refused it, by
#      declaring the phase complete (port audit 2, F1 point 2;
#      port audit 3, N5). The driver's `next --returned-from <phase>` is the only close.
#
# Stands down (exit 0) when:
#   - the project has no .loop-spec/ dir (never hijack unrelated projects)
#   - no stamp, or the stamp names another skill (auto arms a run that
#     route-terminal-guard.sh holds accountable; micro, debug, and intake consume
#     nothing and are not the cycle), and no feature has an open phase
#   - .loop-spec/last-result.json is newer than the stamp or the open phase_start: a
#     route exit was published (write-terminal for a request that is not repository
#     work), or the driver ended the session, which are the honest ways past it
#   - the stamp is older than LOOP_SPEC_STAMP_MAX_AGE_MIN (default 30), or the open
#     phase_start is older than LOOP_SPEC_PHASE_TIMEOUT_MINS (default 60): the driver
#     ignores such a stamp too, and a phase past its own watchdog ceiling was left by
#     a session that died, not this session's contract
#   - stop_hook_active: Claude Code is already continuing from a previous block
#
# Fail-open: missing python3, an unreadable stamp or ledger, or a malformed payload
# -> exit 0.
#
# No kill switch of its own: a guard adds no variable (the port principles,
# rule 9). LOOP_SPEC_INVOCATION_STAMP=0 stops the stamp, and with it deny 1; deny 2
# reads the driver's own ledger and has no switch, because a phase the driver opened
# is closed by the driver or not at all.
#
# Environment variables (all optional):
#   LOOP_SPEC_STAMP_MAX_AGE_MIN   Stand-down age of the stamp in minutes, shared with
#                                 the driver. Default: 30.
#   LOOP_SPEC_PHASE_TIMEOUT_MINS  Stand-down age of an open phase in minutes, the
#                                 driver's watchdog ceiling. Default: 60.
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
RESULT="$PROJECT_DIR/.loop-spec/last-result.json"

INPUT="$(cat 2>/dev/null || true)"
if printf '%s' "$INPUT" | python3 -c \
  "import json,sys; sys.exit(0 if json.load(sys.stdin).get('stop_hook_active') else 1)" 2>/dev/null; then
  exit 0
fi

# One line: `stamp <args>` for an unconsumed cycle invocation, `phase <feature_dir> <phase>`
# for an open phase, else `allow`. The stamp is read first: a session that never began
# the cycle has no phase of its own to close.
verdict="$(python3 - "$PROJECT_DIR" "$STAMP" "$RESULT" "${LOOP_SPEC_STAMP_MAX_AGE_MIN:-30}" "${LOOP_SPEC_PHASE_TIMEOUT_MINS:-60}" <<'PY'
import glob, json, os, sys, time, calendar
project, stamp_path, result_path, max_age, phase_age = sys.argv[1:6]
try:
    max_age, phase_age = int(max_age), int(phase_age)
except ValueError:
    print("allow"); sys.exit(0)
result_at = os.path.getmtime(result_path) if os.path.isfile(result_path) else None
if os.path.isfile(stamp_path):
    try:
        stamp = json.load(open(stamp_path))
        ts = int(stamp.get("ts") or 0)
    except (OSError, ValueError, TypeError, AttributeError):
        print("allow"); sys.exit(0)
    if stamp.get("skill") == "cycle" and time.time() - ts <= max_age * 60 \
            and not (result_at is not None and result_at >= ts):
        print("stamp " + str(stamp.get("args") or "")); sys.exit(0)

def epoch(ts):
    try:
        return calendar.timegm(time.strptime(ts, "%Y-%m-%dT%H:%M:%SZ"))
    except (TypeError, ValueError):
        return None

# A Claude feature lives in a linked worktree of the project, with its own .loop-spec.
roots = [project]
try:
    import subprocess
    out = subprocess.run(["git", "-C", project, "worktree", "list", "--porcelain"],
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, universal_newlines=True).stdout
    roots += [line[9:] for line in out.splitlines() if line.startswith("worktree ")]
except (OSError, ValueError):
    pass
ledgers = []
for root in roots:
    for ledger in glob.glob(os.path.join(root, ".loop-spec", "features", "*", "events.jsonl")):
        real = os.path.realpath(ledger)
        if real not in ledgers:
            ledgers.append(real)
for ledger in sorted(ledgers):
    opened = None
    try:
        for line in open(ledger, encoding="utf-8", errors="replace"):
            try:
                e = json.loads(line)
            except ValueError:
                continue
            at = epoch(e.get("ts"))
            if at is None:
                continue
            if e.get("event") == "phase_start":
                opened = (at, e.get("phase") or "")
            elif e.get("event") == "phase_end":
                opened = None
    except OSError:
        continue
    if opened is None:
        continue
    at, phase = opened
    if time.time() - at > phase_age * 60:
        continue
    if result_at is not None and result_at >= at:
        continue
    print("phase %s %s" % (os.path.dirname(ledger), phase)); sys.exit(0)
print("allow")
PY
)"
kind="${verdict%% *}"
[[ "$kind" == "stamp" || "$kind" == "phase" ]] || exit 0
rest="${verdict#"$kind"}"; rest="${rest# }"

if [[ "$kind" == "stamp" ]]; then
  cat >&2 <<MESSAGE
DENY: this session was invoked as /loop-spec:cycle and never began the cycle.
.loop-spec/invocation-stamp.json (skill: cycle) is still present; the driver consumes
it as its first act, so no driver call happened. Whatever was edited in this session
is not the cycle's work: no feature, no branch, no result.

Begin the cycle now, with DRV as skills/cycle/SKILL.md binds it, then act on .action:

  st="\$(bash "\$DRV" begin -- "${rest}")"

A request that is not repository work is declined with the write-terminal snippet in
skills/shared/route-exit-contract.md (protocol-mismatch), which publishes
.loop-spec/last-result.json; that is the only honest way past the driver.
MESSAGE
  exit 2
fi

feature_dir="${rest% *}"; phase="${rest##* }"
cat >&2 <<MESSAGE
DENY: phase ${phase} of the feature in ${feature_dir} is open: its phase_start has no
phase_end and no newer .loop-spec/last-result.json. Only the driver closes a phase; a
phase declared complete in prose is a phase the exit gate never saw.

Return the phase to the cycle now, with DRV as skills/cycle/SKILL.md binds it, and act
on the answer (REDO fixes the artifact in place; DONE, HANDOFF, and escalate publish the
result this hook reads):

  ans="\$(bash "\$DRV" next --feature-dir "${feature_dir}" --returned-from ${phase})"

A phase that cannot close escalates through the driver, never by stopping:
  bash "\$DRV" escalate --feature-dir "${feature_dir}" --reason "<why>"
MESSAGE
exit 2
