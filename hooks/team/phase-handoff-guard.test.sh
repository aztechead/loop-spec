#!/usr/bin/env bash
# Tests for hooks/team/phase-handoff-guard.sh.
set -euo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/phase-handoff-guard.sh"
PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" payload="$3"
  shift 3
  local actual=0
  # A real cycle in the calling checkout must not outrank the fixture.
  env -u LOOP_SPEC_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID "$@" bash -c 'cd "$CLAUDE_PROJECT_DIR" && exec bash "$1"' _ "$HOOK" >/dev/null 2>&1 <<<"$payload" || actual=$?
  if [[ "$actual" -eq "$expected" ]]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name (expected exit $expected, got $actual)"
    ((FAIL++)) || true
  fi
}

check_value() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"
    ((FAIL++)) || true
  fi
}

ROOT="${TMPDIR:-/tmp}/phase-handoff-guard-test-$$"
trap 'rm -rf "$ROOT"' EXIT
FDIR="$ROOT/.loop-spec/features/demo"
mkdir -p "$FDIR"
printf '%s\n' \
  '{"schemaVersion":7,"slug":"demo","feature_title":"Demo","branch":"feat/demo","baseBranch":"main","currentPhase":"plan","completedPhases":["spec"],"warnings":[],"iterate":{"used":0,"maxIterations":3},"autonomous":true,"updatedAt":"2026-07-30T12:00:00Z"}' \
  > "$FDIR/feature.json"

FIRST='{"tool_name":"Skill","tool_input":{"skill":"loop-spec:spec"},"transcript":[]}'
SECOND='{"tool_name":"Skill","tool_input":{"skill":"loop-spec:plan"},"transcript":[{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"loop-spec:spec"}}]}]}'
SAME='{"tool_name":"Skill","tool_input":{"skill":"loop-spec:spec"},"transcript":[{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"loop-spec:spec"}}]}]}'
OTHER='{"tool_name":"Skill","tool_input":{"skill":"loop-spec:retro"},"transcript":[{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"loop-spec:spec"}}]}]}'

check "first phase in transcript allowed" 0 "$FIRST" \
  CLAUDE_PROJECT_DIR="$ROOT"
check "second phase denied" 2 "$SECOND" \
  CLAUDE_PROJECT_DIR="$ROOT"

# An empty tool_name answer (no jq on PATH, or a payload jq refuses) must fall through
# to the python parsing path below rather than reading as "not a Skill call".
PY_DIR="$(bash "$(cd "$(dirname "$HOOK")/../.." && pwd)/lib/python-path.sh" 2>/dev/null || true)"
if [[ -n "$PY_DIR" ]]; then
  check "a jq-less PATH falls through to the python path, not silently open" 2 "$SECOND" \
    CLAUDE_PROJECT_DIR="$ROOT" "PATH=$PY_DIR:/usr/bin:/bin"
else
  echo "SKIP: no version-manager shim on this machine; lib/python-path.sh printed nothing"
fi
NOT_SKILL='{"tool_name":"Bash","tool_input":{"command":"ls"},"transcript":[{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"loop-spec:spec"}}]}]}'
check "a non-Skill tool call is not a phase entry and passes" 0 "$NOT_SKILL" \
  CLAUDE_PROJECT_DIR="$ROOT"
check_value "denial writes paused result" "paused:phase-handoff:plan" \
  "$(jq -r '[.status,.reason,.phaseReached] | join(":")' "$ROOT/.loop-spec/last-result.json")"
check "same-phase retry allowed" 0 "$SAME" \
  CLAUDE_PROJECT_DIR="$ROOT"
check "non-phase skill allowed" 0 "$OTHER" \
  CLAUDE_PROJECT_DIR="$ROOT"
# The spec node names skills/spec-lite/SKILL.md (graph `skill`, port audit 3 N4): the
# lite skill is not a phase name, and the full spec skill it hands to is the same
# phase, so neither call is a second phase.
LITE_THEN_FULL='{"tool_name":"Skill","tool_input":{"skill":"loop-spec:spec"},"transcript":[{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"loop-spec:spec-lite"}}]}]}'
check "the full spec skill after the lite one is the same phase, allowed" 0 "$LITE_THEN_FULL" \
  CLAUDE_PROJECT_DIR="$ROOT"
LITE='{"tool_name":"Skill","tool_input":{"skill":"loop-spec:spec-lite"},"transcript":[]}'
check "the lite spec skill is not a phase name, allowed" 0 "$LITE" \
  CLAUDE_PROJECT_DIR="$ROOT"
check "no switch exists: an active feature is enough to enforce" 2 "$SECOND" \
  CLAUDE_PROJECT_DIR="$ROOT"
check "malformed payload fails open" 0 "not json" \
  CLAUDE_PROJECT_DIR="$ROOT"

# The short route is one session: the graph's spec -> oneshot edge carries sameSession,
# so oneshot after spec is allowed, and oneshot -> deliver still hands off.
ONESHOT_ROOT="$ROOT/oneshot"; ODIR="$ONESHOT_ROOT/.loop-spec/features/demo"; mkdir -p "$ODIR"
jq '.currentPhase = "oneshot"' "$FDIR/feature.json" > "$ODIR/feature.json"
ONESHOT_AFTER_SPEC='{"tool_name":"Skill","tool_input":{"skill":"loop-spec:oneshot"},"transcript":[{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"loop-spec:spec"}}]}]}'
check "oneshot after spec is the same session (graph sameSession edge)" 0 "$ONESHOT_AFTER_SPEC" \
  CLAUDE_PROJECT_DIR="$ONESHOT_ROOT"
jq '.currentPhase = "deliver" | .completedPhases = ["spec","oneshot"]' "$FDIR/feature.json" > "$ODIR/feature.json"
DELIVER_AFTER_ONESHOT='{"tool_name":"Skill","tool_input":{"skill":"loop-spec:deliver"},"transcript":[{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"loop-spec:oneshot"}}]}]}'
check "deliver after oneshot is the same session too" 0 "$DELIVER_AFTER_ONESHOT" \
  CLAUDE_PROJECT_DIR="$ONESHOT_ROOT"
jq '.currentPhase = "spec" | .completedPhases = ["spec","oneshot"]' "$FDIR/feature.json" > "$ODIR/feature.json"
SPEC_AFTER_ONESHOT='{"tool_name":"Skill","tool_input":{"skill":"loop-spec:spec"},"transcript":[{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"loop-spec:oneshot"}}]}]}'
check "spec after an escalated oneshot still hands off" 2 "$SPEC_AFTER_ONESHOT" \
  CLAUDE_PROJECT_DIR="$ONESHOT_ROOT"

# Production path: Claude Code passes `transcript_path`, not an inline transcript.
# Entries are JSONL with top-level `type:"assistant"` and the blocks under
# `.message.content` -- the shape a real ~/.claude/projects/*.jsonl carries. The inline
# `transcript` array above is the legacy fallback, so it cannot prove this branch.
TRANSCRIPT="$ROOT/transcript.jsonl"
{
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"go"}}'
  printf '%s\n' '{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"thinking","thinking":"..."}]}}'
  printf '%s\n' '{"type":"assistant","uuid":"a2","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Skill","input":{"skill":"loop-spec:spec"}}]}}'
  printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"ok"}]}}'
} > "$TRANSCRIPT"

JSONL_SECOND="$(jq -cn --arg p "$TRANSCRIPT" \
  '{tool_name:"Skill",tool_input:{skill:"loop-spec:plan"},transcript_path:$p}')"
JSONL_SAME="$(jq -cn --arg p "$TRANSCRIPT" \
  '{tool_name:"Skill",tool_input:{skill:"loop-spec:spec"},transcript_path:$p}')"

# A denied attempt is not a prior phase: spec ran, plan was denied once, and the
# second plan call must still be denied instead of passing as a same-phase retry.
DENIED="$ROOT/transcript-denied.jsonl"
{
  cat "$TRANSCRIPT"
  printf '%s\n' '{"type":"assistant","uuid":"a3","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_2","name":"Skill","input":{"skill":"loop-spec:plan"}}]}}'
  printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_2","is_error":true,"content":"PreToolUse:Skill hook error: DENY: loop-spec runs one phase per main-agent invocation."}]}}'
} > "$DENIED"
JSONL_AFTER_DENIAL="$(jq -cn --arg p "$DENIED" \
  '{tool_name:"Skill",tool_input:{skill:"loop-spec:plan"},transcript_path:$p}')"
rm -f "$ROOT/.loop-spec/last-result.json"
check "JSONL transcript: a phase denied once is denied again, not a retry" 2 "$JSONL_AFTER_DENIAL" \
  CLAUDE_PROJECT_DIR="$ROOT"

rm -f "$ROOT/.loop-spec/last-result.json"
check "JSONL transcript: second phase denied" 2 "$JSONL_SECOND" \
  CLAUDE_PROJECT_DIR="$ROOT"
check_value "JSONL transcript: denial writes paused result" "paused:phase-handoff:plan" \
  "$(jq -r '[.status,.reason,.phaseReached] | join(":")' "$ROOT/.loop-spec/last-result.json")"
check "JSONL transcript: same-phase retry allowed" 0 "$JSONL_SAME" \
  CLAUDE_PROJECT_DIR="$ROOT"

# LOOP_SPEC_SAME_SESSION=1 makes every edge one, not only the graph's declared
# sameSession edges (#10, 6.6.4 live run): a second, non-sameSession phase is allowed.
rm -f "$ROOT/.loop-spec/last-result.json"
check "LOOP_SPEC_SAME_SESSION=1 allows a non-sameSession edge too" 0 "$SECOND" \
  CLAUDE_PROJECT_DIR="$ROOT" LOOP_SPEC_SAME_SESSION=1

# A real marker is assistant text and closes every later tool path in this
# invocation, including Bash and Agent. Tool input that merely documents the
# marker does not establish a handoff.
MARKER='{"tool_name":"Bash","tool_input":{"command":"echo after"},"session_id":"session-a","transcript":[{"role":"assistant","content":[{"type":"text","text":"LOOP_SPEC_HANDOFF {\"next\":\"discuss\"}"}]}]}'
check "premature handoff marker allows a later Bash tool" 0 "$MARKER" \
  CLAUDE_PROJECT_DIR="$ROOT"
TOOL_INPUT_MARKER='{"tool_name":"Agent","tool_input":{"prompt":"LOOP_SPEC_HANDOFF {\"next\":\"discuss\"}"},"session_id":"session-a","transcript":[{"role":"assistant","content":[{"type":"tool_use","name":"Agent","input":{"prompt":"LOOP_SPEC_HANDOFF {\"next\":\"discuss\"}"}}]}]}'
check "marker in tool input does not deny Agent" 0 "$TOOL_INPUT_MARKER" \
  CLAUDE_PROJECT_DIR="$ROOT"
printf '%s\n' '{"schemaVersion":7,"currentPhase":"discuss","handoffSession":{"id":"session-a","from":"spec","next":"discuss","at":"2026-07-30T12:00:00Z"}}' > "$FDIR/feature.json"
check "durable handoff denies same-session Agent" 2 \
  '{"tool_name":"Agent","tool_input":{"description":"continue"},"session_id":"session-a","transcript":[]}' \
  CLAUDE_PROJECT_DIR="$ROOT"
check "durable handoff allows a fresh session" 0 \
  '{"tool_name":"Bash","tool_input":{"command":"echo fresh"},"session_id":"session-b","transcript":[]}' \
  CLAUDE_PROJECT_DIR="$ROOT"

# Provider prose and a pretty-printed marker still correlate to the durable
# same-session handoff, while the marker alone remains harmless.
MULTILINE_MARKER='{"tool_name":"Bash","tool_input":{"command":"echo after"},"session_id":"session-a","transcript":[{"role":"assistant","content":[{"type":"text","text":"handoff follows:\nLOOP_SPEC_HANDOFF {\n  \"next\": \"discuss\"\n}"}]}]}'
check "prefixed multiline marker denies durable same-session handoff" 2 "$MULTILINE_MARKER" \
  CLAUDE_PROJECT_DIR="$ROOT"

# Native adapters must preserve the same boundary for Bash and Agent. These calls
# exercise hooks/pre-tool-guard.py rather than the shared hook directly.
ADAPTER="$(cd "$(dirname "$HOOK")/.." && pwd)/pre-tool-guard.py"
adapter_check() {
  local name="$1" expected="$2" payload="$3" actual=0
  (cd "$ROOT" && env -u LOOP_SPEC_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_SESSION_ID python3 "$ADAPTER") >/dev/null 2>&1 <<<"$payload" || actual=$?
  if [[ "$actual" -eq "$expected" ]]; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name (expected exit $expected, got $actual)"
    ((FAIL++)) || true
  fi
}
adapter_check "native Bash adapter denies same-session handoff" 2 \
  '{"tool_name":"Bash","tool_input":{"command":"echo after"},"cwd":"'"$ROOT"'","session_id":"session-a"}'
adapter_check "native Agent adapter denies same-session handoff" 2 \
  '{"tool_name":"Agent","tool_input":{"description":"continue"},"cwd":"'"$ROOT"'","session_id":"session-a"}'
adapter_check "native Bash adapter allows fresh session" 0 \
  '{"tool_name":"Bash","tool_input":{"command":"echo fresh"},"cwd":"'"$ROOT"'","session_id":"session-b"}'

# Marker-like text from a user message or a tool result is not emitted protocol
# output and must not close the invocation.
check "user marker text does not deny a later Bash tool" 0 \
  '{"tool_name":"Bash","tool_input":{"command":"echo after"},"transcript":[{"role":"user","content":"LOOP_SPEC_HANDOFF {\"next\":\"discuss\"}"}]}' \
  CLAUDE_PROJECT_DIR="$ROOT"
check "tool result marker text does not deny a later Bash tool" 0 \
  '{"tool_name":"Bash","tool_input":{"command":"echo after"},"transcript":[{"role":"user","content":[{"type":"tool_result","content":"LOOP_SPEC_HANDOFF {\"next\":\"discuss\"}"}]}]}' \
  CLAUDE_PROJECT_DIR="$ROOT"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
