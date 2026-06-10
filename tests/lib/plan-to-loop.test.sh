#!/usr/bin/env bash
# Unit tests for lib/plan-to-loop.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/lib/plan-to-loop.sh"
PLANLIB_DIR="$ROOT/skills/loop-runner/scripts"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

TASKS_OK='[
  {"id":"task-001","brief":"add adder","files":["src/add.py"],"blockedBy":[],
   "verifyCommand":"pytest tests/test_add.py -q",
   "acceptanceCriteria":["add(2,2)==4"],"readFirst":["src/__init__.py"],"specPath":null},
  {"id":"task-002","brief":"add subtractor","files":["src/sub.py"],"blockedBy":["task-001"],
   "verifyCommand":"pytest tests/test_sub.py -q",
   "acceptanceCriteria":["sub(4,2)==2"],"readFirst":[],"specPath":"docs/sub-spec.md"}
]'

# A: valid conversion exits 0 and emits valid JSON
if OUT=$(printf '%s' "$TASKS_OK" | bash "$SCRIPT" --slug demo \
    --spec docs/super-spec/features/demo/SPEC.md \
    --plan docs/super-spec/features/demo/PLAN.md 2>/dev/null); then
  pass "A: valid tasks convert (exit 0)"
else
  fail "A: valid tasks convert (exit 0)"
  OUT="{}"
fi

# B: output validates against planlib.validate_plan
if printf '%s' "$OUT" | python3 -c "
import json, sys
sys.path.insert(0, '$PLANLIB_DIR')
from planlib import validate_plan
errs = validate_plan(json.load(sys.stdin))
sys.exit(1 if errs else 0)
"; then
  pass "B: output passes planlib.validate_plan"
else
  fail "B: output passes planlib.validate_plan"
fi

# C: deps map from blockedBy
DEP=$(printf '%s' "$OUT" | python3 -c "
import json,sys; p=json.load(sys.stdin)
t={x['id']:x for x in p['tasks']}
print(','.join(t['task-002']['deps']))")
if [[ "$DEP" == "task-001" ]]; then
  pass "C: blockedBy maps to deps"
else
  fail "C: blockedBy maps to deps (got '$DEP')"
fi

# D: SPEC + PLAN force-protected in every task; per-task specPath added
PROT=$(printf '%s' "$OUT" | python3 -c "
import json,sys; p=json.load(sys.stdin)
t={x['id']:x for x in p['tasks']}
ok1 = all('docs/super-spec/features/demo/SPEC.md' in x['protected'] and
          'docs/super-spec/features/demo/PLAN.md' in x['protected'] for x in p['tasks'])
ok2 = 'docs/sub-spec.md' in t['task-002']['protected']
print('ok' if ok1 and ok2 else 'bad')")
if [[ "$PROT" == "ok" ]]; then
  pass "D: spec/plan/specPath protected"
else
  fail "D: spec/plan/specPath protected"
fi

# E: prompt carries acceptance criteria and file scope
PROMPT_OK=$(printf '%s' "$OUT" | python3 -c "
import json,sys; p=json.load(sys.stdin)
t={x['id']:x for x in p['tasks']}
pr=t['task-001']['prompt']
print('ok' if 'add(2,2)==4' in pr and 'src/add.py' in pr and 'Do NOT modify' in pr else 'bad')")
if [[ "$PROMPT_OK" == "ok" ]]; then
  pass "E: prompt carries criteria + scope + don'ts"
else
  fail "E: prompt carries criteria + scope + don'ts"
fi

# F: missing verifyCommand rejected with exit 1
if printf '%s' '[{"id":"task-003","brief":"x","files":[],"blockedBy":[],"verifyCommand":"","acceptanceCriteria":[]}]' \
    | bash "$SCRIPT" --slug demo --spec S.md --plan P.md >/dev/null 2>&1; then
  fail "F: empty verifyCommand rejected"
else
  pass "F: empty verifyCommand rejected"
fi

# G: empty tasks array rejected
if printf '%s' '[]' | bash "$SCRIPT" --slug demo --spec S.md --plan P.md >/dev/null 2>&1; then
  fail "G: empty tasks rejected"
else
  pass "G: empty tasks rejected"
fi

# H: missing required args -> exit 2
RC=0
printf '%s' "$TASKS_OK" | bash "$SCRIPT" --slug demo >/dev/null 2>&1 || RC=$?
if [[ "$RC" -eq 2 ]]; then
  pass "H: missing args -> exit 2"
else
  fail "H: missing args -> exit 2 (got $RC)"
fi

# I: budgets and iteration caps land in the plan
NUMS=$(printf '%s' "$TASKS_OK" | bash "$SCRIPT" --slug demo --spec S.md --plan P.md \
  --fleet-budget 12 --task-budget 2.5 --max-iterations 6 2>/dev/null | python3 -c "
import json,sys; p=json.load(sys.stdin)
t=p['tasks'][0]
print(p['fleet_budget_usd'], t['budget_usd'], t['max_iterations'])")
if [[ "$NUMS" == "12.0 2.5 6" ]]; then
  pass "I: budget/iteration overrides applied"
else
  fail "I: budget/iteration overrides applied (got '$NUMS')"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
