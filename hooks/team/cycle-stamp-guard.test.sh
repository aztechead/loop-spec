#!/usr/bin/env bash
# Tests for hooks/team/cycle-stamp-guard.sh (Stop): an unconsumed cycle stamp is a
# session that never began the cycle it was invoked for.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/cycle-stamp-guard.sh"
STAMP_HOOK="$HERE/invocation-stamp.sh"
DRIVER="$HERE/../../lib/cycle-driver.sh"
ROOT="${TMPDIR:-/tmp}/cycle-stamp-guard-test-$$"
mkdir -p "$ROOT"
ROOT="$(cd "$ROOT" && pwd -P)"
trap 'rm -rf "$ROOT"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export LOOP_SPEC_HARNESS=codex LOOP_SPEC_TEAMS_MODE=none LOOP_SPEC_WORKFLOWS_AVAILABLE=0
unset LOOP_SPEC_STAMP_MAX_AGE_MIN
# The guard reads this session's id from the shell; the harness that runs this suite
# must not leak its own into the fixtures.
unset CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID

PASS=0
FAIL=0

check() {
  local name="$1" expected_exit="$2" project="$3"; shift 3
  local actual_exit=0
  env CLAUDE_PROJECT_DIR="$project" "$@" bash "$HOOK" >/dev/null 2>&1 \
    <<<"${PAYLOAD:-{\}}" || actual_exit=$?
  if [[ "$actual_exit" -eq "$expected_exit" ]]; then
    echo "PASS: $name"; ((PASS++)) || true
  else
    echo "FAIL: $name (expected exit $expected_exit, got $actual_exit)"; ((FAIL++)) || true
  fi
}

# stamp <project> <skill> <args> [<age seconds>]: what invocation-stamp.sh leaves.
stamp() {
  mkdir -p "$1/.loop-spec"
  printf '{"schema":1,"skill":"%s","args":"%s","ts":%s}\n' "$2" "$3" "$(( $(date +%s) - ${4:-0} ))" \
    > "$1/.loop-spec/invocation-stamp.json"
}

# a: the reported run. The prompt was stamped and the driver never consumed it: the
# hook reads the stamp and the result file, nothing else (what the lead edited is not
# its evidence) -> BLOCK.
DRIFT="$ROOT/drift"; mkdir -p "$DRIFT/.loop-spec"
printf '%s\n' '{"prompt":"/loop-spec:cycle autonomous add a --json flag to wc_tool.py"}' \
  | env CLAUDE_PROJECT_DIR="$DRIFT" bash "$STAMP_HOOK" >/dev/null
[[ -f "$DRIFT/.loop-spec/invocation-stamp.json" ]] && { echo "PASS: a0: the prompt hook stamped the invocation"; PASS=$((PASS+1)); } || { echo "FAIL: a0: the prompt hook stamped the invocation"; FAIL=$((FAIL+1)); }
PAYLOAD='{"stop_hook_active":false}' check "a: unconsumed cycle stamp, no result -> BLOCK" 2 "$DRIFT"
# The deny names the begin call through the DRV the cycle skill binds, never a path to
# retype (a live lead retyped a 120-character path with one digit wrong).
msg="$(env CLAUDE_PROJECT_DIR="$DRIFT" CLAUDE_PLUGIN_ROOT=/opt/plugin bash "$HOOK" 2>&1 >/dev/null <<<'{}' || true)"
for needle in 'bash "$DRV" begin -- "autonomous add a --json flag to wc_tool.py"' "write-terminal"; do
  if grep -qF -- "$needle" <<<"$msg"; then
    echo "PASS: a2: denial carries: $needle"; PASS=$((PASS+1))
  else
    echo "FAIL: a2: denial carries: $needle"; FAIL=$((FAIL+1)); echo "$msg"
  fi
done
if grep -q '/opt/plugin' <<<"$msg"; then echo "FAIL: a3: the denial prints no absolute driver path"; FAIL=$((FAIL+1)); else echo "PASS: a3: the denial prints no absolute driver path"; PASS=$((PASS+1)); fi

# b: the driver consumed the stamp -> ALLOW. The real `start`, so the two agree on
# what "consumed" means.
BEGUN="$ROOT/begun"; mkdir -p "$BEGUN"
git -C "$BEGUN" init -q -b main && git -C "$BEGUN" commit -q --allow-empty -m init
stamp "$BEGUN" cycle "autonomous fix slug"
(cd "$BEGUN" && env -u CLAUDE_CODE_ENTRYPOINT bash "$DRIVER" start --dir "$BEGUN" -- autonomous fix slug >/dev/null 2>&1) || true
[[ -f "$BEGUN/.loop-spec/invocation-stamp.json" ]] && echo "FAIL: b0: driver start consumed the stamp" || { echo "PASS: b0: driver start consumed the stamp"; PASS=$((PASS+1)); }
check "b: stamp consumed by the driver -> ALLOW" 0 "$BEGUN"

# c: a route exit was published after the stamp (the honest decline) -> ALLOW.
DECLINED="$ROOT/declined"; stamp "$DECLINED" cycle "what is the architecture" 5
printf '{"schema":1,"status":"escalated","outcome":"protocol-mismatch"}\n' > "$DECLINED/.loop-spec/last-result.json"
check "c: last-result.json newer than the stamp -> ALLOW" 0 "$DECLINED"

# c2: a result older than the stamp is a previous run's, not this one's.
OLDRESULT="$ROOT/old-result"; mkdir -p "$OLDRESULT/.loop-spec"
printf '{"schema":1,"status":"completed"}\n' > "$OLDRESULT/.loop-spec/last-result.json"
touch -t 202001010000 "$OLDRESULT/.loop-spec/last-result.json"
stamp "$OLDRESULT" cycle "add a flag"
check "c2: last-result.json older than the stamp -> BLOCK" 2 "$OLDRESULT"

# d: other skills' stamps are not the cycle's contract.
for skill in auto micro debug intake; do
  OTHER="$ROOT/other-$skill"; stamp "$OTHER" "$skill" "fix it"
  check "d: a $skill stamp -> ALLOW" 0 "$OTHER"
done

# e: a stamp past the driver's own stand-down age is a dead session's.
STALE="$ROOT/stale"; stamp "$STALE" cycle "add a flag" 7200
check "e: stamp past LOOP_SPEC_STAMP_MAX_AGE_MIN -> ALLOW" 0 "$STALE"
check "e2: the age is the driver's setting" 2 "$STALE" LOOP_SPEC_STAMP_MAX_AGE_MIN=99999

# f: nothing stamped, no .loop-spec, kill switch, re-block suppression, fail-open.
IDLE="$ROOT/idle"; mkdir -p "$IDLE/.loop-spec"
check "f: no stamp -> ALLOW" 0 "$IDLE"
FOREIGN="$ROOT/foreign"; mkdir -p "$FOREIGN"
check "f2: project without .loop-spec -> ALLOW" 0 "$FOREIGN"
# No kill switch: the guard adds no variable. Stopping the stamp stops the deny.
NOSTAMP="$ROOT/nostamp"; mkdir -p "$NOSTAMP/.loop-spec"
printf '%s\n' '{"prompt":"/loop-spec:cycle autonomous x"}' | env CLAUDE_PROJECT_DIR="$NOSTAMP" LOOP_SPEC_INVOCATION_STAMP=0 bash "$STAMP_HOOK" >/dev/null
check "g: LOOP_SPEC_INVOCATION_STAMP=0 writes no stamp, so nothing denies" 0 "$NOSTAMP"
PAYLOAD='{"stop_hook_active":true}' check "h: stop_hook_active -> ALLOW" 0 "$DRIFT"
BROKEN="$ROOT/broken"; mkdir -p "$BROKEN/.loop-spec"; printf 'not json' > "$BROKEN/.loop-spec/invocation-stamp.json"
check "i: unreadable stamp -> ALLOW (fail-open)" 0 "$BROKEN"
PAYLOAD='not json' check "j: malformed payload -> BLOCK (the stamp stands)" 2 "$DRIFT"

# k: an open phase. The driver's engine emitted phase_start and nothing closed it: no
# phase_end, no newer result. A lead that declares the phase done in prose -> BLOCK.
ledger() { # ledger <project> <slug> <event> <phase> <age seconds>
  mkdir -p "$1/.loop-spec/features/$2"
  printf '{"ts":"%s","slug":"%s","event":"%s","phase":"%s","data":{}}\n' \
    "$(python3 -c 'import sys,time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time()-int(sys.argv[1]))))' "$5")" "$2" "$3" "$4" >> "$1/.loop-spec/features/$2/events.jsonl"
}
OPEN="$ROOT/open"; mkdir -p "$OPEN/.loop-spec"
ledger "$OPEN" fix-slug phase_start spec 300
ledger "$OPEN" fix-slug phase_end spec 200
ledger "$OPEN" fix-slug phase_start oneshot 100
check "k: phase_start with no phase_end and no newer result -> BLOCK" 2 "$OPEN"
msg="$(env CLAUDE_PROJECT_DIR="$OPEN" bash "$HOOK" 2>&1 >/dev/null <<<'{}' || true)"
for needle in 'next --feature-dir "'"$OPEN"'/.loop-spec/features/fix-slug" --returned-from oneshot' 'escalate --feature-dir' 'no newer result.json'; do
  if grep -qF -- "$needle" <<<"$msg"; then echo "PASS: k2: denial carries: $needle"; PASS=$((PASS+1)); else echo "FAIL: k2: denial carries: $needle"; FAIL=$((FAIL+1)); echo "$msg"; fi
done
printf '{"schema":1,"status":"paused","reason":"phase-handoff"}\n' > "$OPEN/.loop-spec/features/fix-slug/result.json"
check "k3: a result newer than the open phase_start (the driver ended the session) -> ALLOW" 0 "$OPEN"
rm -f "$OPEN/.loop-spec/features/fix-slug/result.json"
ledger "$OPEN" fix-slug phase_end oneshot 50
check "k4: phase_end after the phase_start -> ALLOW" 0 "$OPEN"
STALEPHASE="$ROOT/stale-phase"; mkdir -p "$STALEPHASE/.loop-spec"
ledger "$STALEPHASE" fix-slug phase_start execute 7200
check "k5: an open phase past LOOP_SPEC_PHASE_TIMEOUT_MINS is a dead session's -> ALLOW" 0 "$STALEPHASE"
check "k6: the age is the driver's watchdog ceiling" 2 "$STALEPHASE" LOOP_SPEC_PHASE_TIMEOUT_MINS=99999
# The feature lives in a linked worktree of the project (Claude enters one): its
# ledger is read from there.
WTROOT="$ROOT/wt-root"; mkdir -p "$WTROOT/.loop-spec"
git -C "$WTROOT" init -q -b main && git -C "$WTROOT" commit -q --allow-empty -m init
git -C "$WTROOT" worktree add -q "$WTROOT/.claude/worktrees/fix-slug" -b feat/fix-slug
ledger "$WTROOT/.claude/worktrees/fix-slug" fix-slug phase_start oneshot 100
check "k8: an open phase in the feature's linked worktree -> BLOCK" 2 "$WTROOT"
BADLEDGER="$ROOT/bad-ledger"; mkdir -p "$BADLEDGER/.loop-spec/features/x"; printf 'not json\n' > "$BADLEDGER/.loop-spec/features/x/events.jsonl"
check "k7: an unreadable ledger -> ALLOW (fail-open)" 0 "$BADLEDGER"

# l: a dispatched agent is legitimately still running the open phase (lib/events.sh
# writes .pending-dispatch on the `dispatch` event) -> ALLOW; the same marker past its
# own window is a dead dispatch's, not a reason to stand down -> BLOCK.
# LOOP_SPEC_PHASE_TIMEOUT_MINS is pinned huge throughout so the normal watchdog
# (which the phase's own age would otherwise satisfy) never masks what is under test.
DISPATCHED="$ROOT/dispatched"; mkdir -p "$DISPATCHED/.loop-spec"
ledger "$DISPATCHED" fix-slug phase_start execute 14400
check "l0: open phase, no marker -> BLOCK" 2 "$DISPATCHED" LOOP_SPEC_PHASE_TIMEOUT_MINS=99999
touch "$DISPATCHED/.loop-spec/features/fix-slug/.pending-dispatch"
check "l: fresh .pending-dispatch marker -> ALLOW" 0 "$DISPATCHED" LOOP_SPEC_PHASE_TIMEOUT_MINS=99999
python3 -c 'import os,sys,time; t=time.time()-7200; os.utime(sys.argv[1], (t, t))' \
  "$DISPATCHED/.loop-spec/features/fix-slug/.pending-dispatch"
check "l2: a marker past LOOP_SPEC_DISPATCH_WAIT_MINS -> BLOCK" 2 "$DISPATCHED" LOOP_SPEC_PHASE_TIMEOUT_MINS=99999
check "l3: the window is the driver's setting" 0 "$DISPATCHED" \
  LOOP_SPEC_PHASE_TIMEOUT_MINS=99999 LOOP_SPEC_DISPATCH_WAIT_MINS=99999

# m: two cycle sessions in one repo. A phase_start stamped with a peer session's id is
# the peer's to close -> ALLOW; the same id, or no id on either side, is this
# session's -> BLOCK. The result arbiter for a phase is <feature_dir>/result.json, the
# file cycle-result.sh write always leaves, so the shared pointer it copies to the
# control checkout neither quiets nor flags a worktree feature.
owned() { # owned <project> <slug> <phase> <session> <age seconds>
  mkdir -p "$1/.loop-spec/features/$2"
  printf '{"ts":"%s","slug":"%s","event":"phase_start","phase":"%s","data":{},"session":"%s"}\n' \
    "$(python3 -c 'import sys,time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time()-int(sys.argv[1]))))' "$5")" "$2" "$3" "$4" >> "$1/.loop-spec/features/$2/events.jsonl"
}
PEER="$ROOT/peer"; mkdir -p "$PEER/.loop-spec"
owned "$PEER" peer-slug execute sess-A 100
PAYLOAD='{"session_id":"sess-B"}' check "m1: open phase owned by a peer session -> ALLOW" 0 "$PEER"
PAYLOAD='{"session_id":"sess-A"}' check "m2: open phase owned by this session -> BLOCK" 2 "$PEER"
PAYLOAD='{}' check "m3: payload names no session -> BLOCK (fail safe)" 2 "$PEER"
NOID="$ROOT/no-id"; mkdir -p "$NOID/.loop-spec"; ledger "$NOID" fix-slug phase_start execute 100
PAYLOAD='{"session_id":"sess-B"}' check "m4: phase_start with no session field -> BLOCK (fail safe)" 2 "$NOID"
WT2="$ROOT/wt-result"; mkdir -p "$WT2/.loop-spec"
git -C "$WT2" init -q -b main && git -C "$WT2" commit -q --allow-empty -m init
git -C "$WT2" worktree add -q "$WT2/.claude/worktrees/wt-slug" -b feat/wt-slug
WT2_FEAT="$WT2/.claude/worktrees/wt-slug/.loop-spec/features/wt-slug"
ledger "$WT2/.claude/worktrees/wt-slug" wt-slug phase_start execute 100
# A peer feature's honest close: the writer's pointer lands in the control checkout.
OTHER_FEAT="$WT2/.loop-spec/features/other-slug"; mkdir -p "$OTHER_FEAT"
jq -n '{schemaVersion:7,slug:"other-slug",feature_title:"other",currentPhase:"execute",branch:"feat/other",baseBranch:"main",autonomous:false,createdAt:"2026-01-01T00:00:00Z",updatedAt:"2026-01-01T00:00:00Z",warnings:[]}' > "$OTHER_FEAT/feature.json"
bash "$HERE/../../lib/cycle-result.sh" write "$OTHER_FEAT" --status paused --reason phase-handoff --summary "peer paused" >/dev/null 2>&1
if [[ -f "$WT2/.loop-spec/last-result.json" ]]; then echo "PASS: m5 fixture: the writer left the control pointer"; PASS=$((PASS+1)); else echo "FAIL: m5 fixture: the writer left no control pointer"; FAIL=$((FAIL+1)); fi
check "m5: a peer feature's newer pointer in the control checkout does not close a worktree feature's phase -> BLOCK" 2 "$WT2"
# This feature's own close, through the same writer.
jq -n '{schemaVersion:7,slug:"wt-slug",feature_title:"wt",currentPhase:"execute",branch:"feat/wt-slug",baseBranch:"main",autonomous:false,createdAt:"2026-01-01T00:00:00Z",updatedAt:"2026-01-01T00:00:00Z",warnings:[]}' > "$WT2_FEAT/feature.json"
bash "$HERE/../../lib/cycle-result.sh" write "$WT2_FEAT" --status paused --reason phase-handoff --summary "handed off" >/dev/null 2>&1
if [[ -f "$WT2_FEAT/result.json" ]]; then echo "PASS: m6 fixture: the writer left result.json"; PASS=$((PASS+1)); else echo "FAIL: m6 fixture: the writer left no result.json"; FAIL=$((FAIL+1)); fi
check "m6: the feature's own result.json from the writer closes it -> ALLOW" 0 "$WT2"
# Round trip through the real emitter: the id the guard compares is the one the
# emitter stamped, so this session's own phase is never mistaken for a peer's.
RT="$ROOT/round-trip"; mkdir -p "$RT/.loop-spec/features/rt-slug"
CLAUDE_CODE_SESSION_ID=sess-A bash "$HERE/../../lib/events.sh" emit "$RT/.loop-spec/features/rt-slug" phase_start --phase execute >/dev/null 2>&1
PAYLOAD='{"session_id":"sess-A"}' check "m7: emitted under sess-A, Stop payload sess-A -> BLOCK" 2 "$RT"
PAYLOAD='{"session_id":"sess-B"}' check "m8: the env var the emitter read outranks the payload -> BLOCK" 2 "$RT" CLAUDE_CODE_SESSION_ID=sess-A
PAYLOAD='{"session_id":"sess-B"}' check "m9: no env var, payload names a peer -> ALLOW" 0 "$RT"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
