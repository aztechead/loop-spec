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
  printf '%s' "$payload" | env "$@" bash "$HOOK" >/dev/null 2>&1 || actual=$?
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
  '{"schemaVersion":7,"slug":"demo","feature_title":"Demo","branch":"feat/demo","baseBranch":"main","currentPhase":"discuss","completedPhases":["spec"],"phaseHandoff":true,"warnings":[],"iterate":{"used":0,"maxIterations":3},"autonomous":true,"updatedAt":"2026-07-30T12:00:00Z"}' \
  > "$FDIR/feature.json"

FIRST='{"tool_name":"Skill","tool_input":{"skill":"loop-spec:spec"},"transcript":[]}'
SECOND='{"tool_name":"Skill","tool_input":{"skill":"loop-spec:discuss"},"transcript":[{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"loop-spec:spec"}}]}]}'
SAME='{"tool_name":"Skill","tool_input":{"skill":"loop-spec:spec"},"transcript":[{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"loop-spec:spec"}}]}]}'
OTHER='{"tool_name":"Skill","tool_input":{"skill":"loop-spec:map-codebase"},"transcript":[{"role":"assistant","content":[{"type":"tool_use","name":"Skill","input":{"skill":"loop-spec:spec"}}]}]}'

check "first phase in transcript allowed" 0 "$FIRST" \
  CLAUDE_PROJECT_DIR="$ROOT" LOOP_SPEC_PHASE_HANDOFF=1
check "second phase denied from env policy" 2 "$SECOND" \
  CLAUDE_PROJECT_DIR="$ROOT" LOOP_SPEC_PHASE_HANDOFF=1
check_value "denial writes paused result" "paused:phase-handoff:discuss" \
  "$(jq -r '[.status,.reason,.phaseReached] | join(":")' "$ROOT/.loop-spec/last-result.json")"
check "same-phase retry allowed" 0 "$SAME" \
  CLAUDE_PROJECT_DIR="$ROOT" LOOP_SPEC_PHASE_HANDOFF=1
check "non-phase skill allowed" 0 "$OTHER" \
  CLAUDE_PROJECT_DIR="$ROOT" LOOP_SPEC_PHASE_HANDOFF=1
check "explicit env zero overrides persisted true" 0 "$SECOND" \
  CLAUDE_PROJECT_DIR="$ROOT" LOOP_SPEC_PHASE_HANDOFF=0
check "persisted true enforces when env unset" 2 "$SECOND" \
  CLAUDE_PROJECT_DIR="$ROOT"
check "invalid env value denied" 2 "$FIRST" \
  CLAUDE_PROJECT_DIR="$ROOT" LOOP_SPEC_PHASE_HANDOFF=maybe
check "malformed payload fails open" 0 "not json" \
  CLAUDE_PROJECT_DIR="$ROOT" LOOP_SPEC_PHASE_HANDOFF=1

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

rm -f "$ROOT/.loop-spec/last-result.json"
check "JSONL transcript: second phase denied" 2 "$JSONL_SECOND" \
  CLAUDE_PROJECT_DIR="$ROOT" LOOP_SPEC_PHASE_HANDOFF=1
check_value "JSONL transcript: denial writes paused result" "paused:phase-handoff:discuss" \
  "$(jq -r '[.status,.reason,.phaseReached] | join(":")' "$ROOT/.loop-spec/last-result.json")"
check "JSONL transcript: same-phase retry allowed" 0 "$JSONL_SAME" \
  CLAUDE_PROJECT_DIR="$ROOT" LOOP_SPEC_PHASE_HANDOFF=1

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
