#!/usr/bin/env bash
# Tests for hooks/team/phase-handoff-guard.sh.
set -euo pipefail

HOOK="$(dirname "$0")/phase-handoff-guard.sh"
PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" payload="$3"
  shift 3
  local actual=0
  env "$@" bash "$HOOK" >/dev/null 2>&1 <<<"$payload" || actual=$?
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
  '{"schemaVersion":7,"slug":"demo","feature_title":"Demo","branch":"feat/demo","baseBranch":"main","currentPhase":"discuss","completedPhases":["spec"],"warnings":[],"iterate":{"used":0,"maxIterations":3},"autonomous":true,"updatedAt":"2026-07-30T12:00:00Z"}' \
  > "$FDIR/feature.json"

FIRST='{"tool_name":"Skill","tool_input":{"skill":"loop-spec:spec"},"transcript":[]}'
SECOND='{"tool_name":"Skill","tool_input":{"skill":"loop-spec:discuss"},"transcript":[{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"loop-spec:spec"}}]}]}'
SAME='{"tool_name":"Skill","tool_input":{"skill":"loop-spec:spec"},"transcript":[{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"loop-spec:spec"}}]}]}'
OTHER='{"tool_name":"Skill","tool_input":{"skill":"loop-spec:retro"},"transcript":[{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"loop-spec:spec"}}]}]}'

check "first phase in transcript allowed" 0 "$FIRST" \
  CLAUDE_PROJECT_DIR="$ROOT"
check "second phase denied" 2 "$SECOND" \
  CLAUDE_PROJECT_DIR="$ROOT"
check_value "denial writes paused result" "paused:phase-handoff:discuss" \
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
jq '.currentPhase = "discuss" | .completedPhases = ["spec","oneshot"]' "$FDIR/feature.json" > "$ODIR/feature.json"
DISCUSS_AFTER_ONESHOT='{"tool_name":"Skill","tool_input":{"skill":"loop-spec:discuss"},"transcript":[{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"loop-spec:oneshot"}}]}]}'
check "discuss after an escalated oneshot still hands off" 2 "$DISCUSS_AFTER_ONESHOT" \
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
  '{tool_name:"Skill",tool_input:{skill:"loop-spec:discuss"},transcript_path:$p}')"
JSONL_SAME="$(jq -cn --arg p "$TRANSCRIPT" \
  '{tool_name:"Skill",tool_input:{skill:"loop-spec:spec"},transcript_path:$p}')"

# A denied attempt is not a prior phase: spec ran, discuss was denied once, and the
# second discuss call must still be denied instead of passing as a same-phase retry.
DENIED="$ROOT/transcript-denied.jsonl"
{
  cat "$TRANSCRIPT"
  printf '%s\n' '{"type":"assistant","uuid":"a3","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_2","name":"Skill","input":{"skill":"loop-spec:discuss"}}]}}'
  printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_2","is_error":true,"content":"PreToolUse:Skill hook error: DENY: loop-spec runs one phase per main-agent invocation."}]}}'
} > "$DENIED"
JSONL_AFTER_DENIAL="$(jq -cn --arg p "$DENIED" \
  '{tool_name:"Skill",tool_input:{skill:"loop-spec:discuss"},transcript_path:$p}')"
rm -f "$ROOT/.loop-spec/last-result.json"
check "JSONL transcript: a phase denied once is denied again, not a retry" 2 "$JSONL_AFTER_DENIAL" \
  CLAUDE_PROJECT_DIR="$ROOT"

rm -f "$ROOT/.loop-spec/last-result.json"
check "JSONL transcript: second phase denied" 2 "$JSONL_SECOND" \
  CLAUDE_PROJECT_DIR="$ROOT"
check_value "JSONL transcript: denial writes paused result" "paused:phase-handoff:discuss" \
  "$(jq -r '[.status,.reason,.phaseReached] | join(":")' "$ROOT/.loop-spec/last-result.json")"
check "JSONL transcript: same-phase retry allowed" 0 "$JSONL_SAME" \
  CLAUDE_PROJECT_DIR="$ROOT"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
