#!/usr/bin/env bash
# Assert GDD architecture docs and shared contracts exist and are referenced.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name (expected '$expected', got '$actual')"; FAIL=$((FAIL + 1))
  fi
}

for f in \
  skills/shared/graph-contract.md \
  skills/shared/dual-process.md \
  skills/shared/handoff-port.md \
  docs/loop-spec/gdd.md
do
  [[ -f "$ROOT/$f" ]]
  check "$f exists" "0" "$?"
done

# Each contract has at least one referencing skill
for doc in graph-contract.md dual-process.md handoff-port.md; do
  hits="$(rg -l "$doc" "$ROOT/skills" "$ROOT/docs" 2>/dev/null | wc -l | tr -d ' ')"
  check "$doc referenced" "1" "$([[ "$hits" -ge 1 ]] && echo 1 || echo 0)"
done

# Pattern table has five shapes, not evaluator-optimizer
n="$(grep -cE '^\| (Prompt chaining|Routing|Parallelization|Reflection|Human-in-the-loop) \|' "$ROOT/docs/loop-spec/gdd.md")" || n=0
check "five pattern rows" "5" "$n"
n="$(grep -cE '^\| Evaluator-optimizer \|' "$ROOT/docs/loop-spec/gdd.md")" || n=0
check "no Evaluator-optimizer row" "0" "$n"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
