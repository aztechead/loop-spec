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
trap 'rm -rf "$ROOT"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export LOOP_SPEC_HARNESS=codex LOOP_SPEC_TEAMS_MODE=none LOOP_SPEC_WORKFLOWS_AVAILABLE=0
unset LOOP_SPEC_STAMP_MAX_AGE_MIN

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

# a: the reported run. The prompt was stamped, the lead edited in place, no driver call,
# and the Stop payload names a transcript with no cycle-driver call in it -> BLOCK.
DRIFT="$ROOT/drift"; mkdir -p "$DRIFT/.loop-spec"
printf '%s\n' '{"prompt":"/loop-spec:cycle autonomous add a --json flag to wc_tool.py"}' \
  | env CLAUDE_PROJECT_DIR="$DRIFT" bash "$STAMP_HOOK" >/dev/null
TRANSCRIPT="$DRIFT/transcript.jsonl"
{
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"/loop-spec:cycle autonomous add a --json flag to wc_tool.py"}}'
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"MICRO: done-criteria ..."}]}}'
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Edit","input":{"file_path":"wc_tool.py"}}]}}'
} > "$TRANSCRIPT"
PAYLOAD="$(jq -cn --arg p "$TRANSCRIPT" '{transcript_path:$p,stop_hook_active:false}')" \
  check "a: unconsumed cycle stamp, edits, no driver call -> BLOCK" 2 "$DRIFT"
msg="$(env CLAUDE_PROJECT_DIR="$DRIFT" CLAUDE_PLUGIN_ROOT=/opt/plugin bash "$HOOK" 2>&1 >/dev/null <<<'{}' || true)"
for needle in '/opt/plugin/lib/cycle-driver.sh" begin -- "autonomous add a --json flag to wc_tool.py"' \
              "write-terminal" "micro protocol stands down"; do
  if grep -qF -- "$needle" <<<"$msg"; then
    echo "PASS: a2: denial carries: $needle"; PASS=$((PASS+1))
  else
    echo "FAIL: a2: denial carries: $needle"; FAIL=$((FAIL+1)); echo "$msg"
  fi
done

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
touch -d '2020-01-01' "$OLDRESULT/.loop-spec/last-result.json"
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

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
