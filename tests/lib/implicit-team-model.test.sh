#!/usr/bin/env bash
# Tests for lib/implicit-team-model.sh — named implicit-team spawns inherit the
# session model, so a role alias must take the nameless oneshot path.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/lib/implicit-team-model.sh"
PASS=0
FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL + 1))
  fi
}

spawn() {
  bash "$SCRIPT" spawn-kind --teams-mode "$1" --selector "$2"
}

check "implicit inherit stays a named teammate" \
  "named inherit-session" "$(spawn implicit inherit)"
check "implicit empty selector inherits" \
  "named inherit-session" "$(spawn implicit "")"
check "implicit sonnet is a nameless oneshot" \
  "oneshot implicit-named-ignores-model" "$(spawn implicit sonnet)"
check "implicit opus is a nameless oneshot" \
  "oneshot implicit-named-ignores-model" "$(spawn implicit opus)"
check "implicit haiku is a nameless oneshot" \
  "oneshot implicit-named-ignores-model" "$(spawn implicit haiku)"
check "implicit fable is a nameless oneshot" \
  "oneshot implicit-named-ignores-model" "$(spawn implicit fable)"
check "no-teams is always oneshot" \
  "oneshot no-teams" "$(spawn none sonnet)"
check "explicit roster stays named even with an alias" \
  "named explicit-roster" "$(spawn explicit sonnet)"
check "unknown mode fails safe to oneshot" \
  "oneshot unknown-teams-mode" "$(spawn mystery sonnet)"

rc=0
bash "$SCRIPT" >/dev/null 2>&1 || rc=$?
check "missing command is a bad invocation" "2" "$rc"
rc=0
bash "$SCRIPT" spawn-kind --teams-mode implicit >/dev/null 2>&1 || rc=$?
check "missing selector is still valid inherit" "0" "$rc"
rc=0
bash "$SCRIPT" spawn-kind --selector sonnet >/dev/null 2>&1 || rc=$?
check "missing teams-mode is a bad invocation" "2" "$rc"
rc=0
bash "$SCRIPT" spawn-kind --teams-mode implicit --selector sonnet --bogus x \
  >/dev/null 2>&1 || rc=$?
check "unknown flag is a bad invocation" "2" "$rc"

# The contract docs and phase skills must name the probe; a model that still
# "adds the model key per teammate" in implicit mode silently burns the override.
IMPLICIT_DOC="$ROOT/skills/shared/dispatch.md"
check "implicit-team contract names the probe" "1" \
  "$(grep -Fq 'lib/implicit-team-model.sh' "$IMPLICIT_DOC" && echo 1 || echo 0)"
check "implicit-team contract records in-process inheritance" "1" \
  "$(grep -Fq 'in-process teammate' "$IMPLICIT_DOC" && echo 1 || echo 0)"
check "implicit-team contract names the nameless oneshot path" "1" \
  "$(grep -Fq 'nameless one-shot' "$IMPLICIT_DOC" && echo 1 || echo 0)"

CYCLE="$ROOT/skills/cycle/SKILL.md"
check "cycle dispatch convention names the probe" "1" \
  "$(grep -Fq 'implicit-team-model.sh' "$CYCLE" && echo 1 || echo 0)"

EXEC="$ROOT/skills/execute/SKILL.md"
check "EXECUTE passes the implementer selector into the rung probe" "1" \
  "$(grep -Fq -- '--implementer-model' "$EXEC" && echo 1 || echo 0)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
