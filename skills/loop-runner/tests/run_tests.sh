#!/usr/bin/env bash
# run_tests.sh — offline regression suite for loop-runner. No real claude needed:
# uses tests/fakeclaude. Run this after ANY change to the harness — derivative skills
# stand on these guardrails.
#
# Usage: bash tests/run_tests.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="$HERE/../scripts"
FAKE="$HERE/fakeclaude"
chmod +x "$FAKE"

PASS=0; FAIL=0
check() { # check <name> <got> <want>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); echo "  ✓ $1"
  else FAIL=$((FAIL+1)); echo "  ✗ $1 (got '$2', want '$3')"; fi
}
reason() { python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['halt_reason'])" "$1" 2>/dev/null || echo "MISSING"; }

newrepo() {
  R="$(mktemp -d)"; cd "$R"
  git init -q -b main; git config user.email t@t.t; git config user.name t
  echo base > base.txt; git add -A; git commit -qm init
}

echo "== 1. budget ceiling halts and reports =="
newrepo
python3 "$SCRIPTS/loop.py" "do the thing forever" --task-id budget --claude-bin "$FAKE" \
  --budget 3.00 --max-iterations 99 --no-progress 99 >/dev/null 2>&1
check "exit 1"            "$?" "1"
check "halt_reason"       "$(reason .loop/budget/result.json)" "budget"

echo "== 2. verifier pass → complete, exit 0, result contract =="
newrepo
python3 "$SCRIPTS/loop.py" "make work.txt have two lines" --task-id done --claude-bin "$FAKE" \
  --verify 'test "$(wc -l < work.txt)" -ge 2' --budget 99 --max-iterations 99 >/dev/null 2>&1
check "exit 0"            "$?" "0"
check "halt_reason"       "$(reason .loop/done/result.json)" "complete"
check "verifier.passed"   "$(python3 -c "import json;print(json.load(open('.loop/done/result.json'))['verifier']['passed'])")" "True"
check "iter raw log kept" "$(test -f .loop/done/iter-001.raw.json && echo yes)" "yes"
check "progress notes"    "$(test -f .loop/done/PROGRESS.md && echo yes)" "yes"

echo "== 3. stall: no file changes =="
newrepo
FAKE_STILL=1 python3 "$SCRIPTS/loop.py" "spin" --task-id still --claude-bin "$FAKE" \
  --no-progress 2 --max-iterations 99 --budget 99 >/dev/null 2>&1
check "exit 1"            "$?" "1"
check "halt_reason"       "$(reason .loop/still/result.json)" "no_progress"

echo "== 4. stall: files churn but same verifier failure =="
newrepo
python3 "$SCRIPTS/loop.py" "churn files" --task-id churn --claude-bin "$FAKE" \
  --verify 'echo "FAILED: widget missing on line 42"; exit 1' \
  --no-progress 2 --max-iterations 99 --budget 99 >/dev/null 2>&1
check "exit 1"            "$?" "1"
check "halt_reason"       "$(reason .loop/churn/result.json)" "no_progress"

echo "== 5. verifier integrity: agent edits a protected file → fleet-fatal halt =="
newrepo
mkdir tests_dir; echo 'exit 1' > tests_dir/check.sh; git add -A; git commit -qm tests
FAKE_TAMPER=tests_dir/check.sh python3 "$SCRIPTS/loop.py" "cheat" --task-id cheat \
  --claude-bin "$FAKE" --verify 'bash tests_dir/check.sh' \
  --max-iterations 99 --budget 99 --no-progress 99 >/dev/null 2>&1
check "exit 1"            "$?" "1"
check "halt_reason"       "$(reason .loop/cheat/result.json)" "verifier_integrity"

echo "== 6. resume after interruption carries state and cost =="
newrepo
python3 "$SCRIPTS/loop.py" "long job" --task-id long --claude-bin "$FAKE" \
  --max-iterations 2 --budget 999 --no-progress 99 >/dev/null 2>&1
ITER1=$(python3 -c "import json;print(json.load(open('.loop/long/state.json'))['iteration'])")
OUT=$(python3 "$SCRIPTS/loop.py" "long job" --task-id long --claude-bin "$FAKE" \
  --max-iterations 5 --budget 999 --no-progress 99 2>&1)
check "first run stopped at 2" "$ITER1" "2"
check "resume announced"  "$(grep -c 'Resuming' <<< "$OUT")" "1"
check "continued to 5"    "$(python3 -c "import json;print(json.load(open('.loop/long/state.json'))['iteration'])")" "5"

echo "== 7. config-file mode + library API =="
newrepo
cat > cfg.json << EOF
{"task":"make work.txt have two lines","task_id":"cfg",
 "verify":"test \"\$(wc -l < work.txt)\" -ge 2",
 "budget_usd":99,"max_iterations":99,"claude_bin":"$FAKE"}
EOF
python3 "$SCRIPTS/loop.py" --config cfg.json >/dev/null 2>&1
check "config-mode exit 0" "$?" "0"
LIB=$(PYTHONPATH="$SCRIPTS" python3 - "$FAKE" << 'EOF'
import sys
from loop import LoopConfig, run_loop
r = run_loop(LoopConfig(task="two lines again", task_id="lib",
    verify='test "$(wc -l < work.txt)" -ge 4',
    budget_usd=99, max_iterations=99, claude_bin=sys.argv[1]))
print(r["halt_reason"])
EOF
)
check "library API complete" "$(tail -1 <<< "$LIB")" "complete"

echo "== 8. plan validation rejects garbage =="
BAD=$(PYTHONPATH="$SCRIPTS" python3 - << 'EOF'
from planlib import validate_plan
errs = validate_plan({"tasks":[
  {"id":"a","prompt":"do a thing that is long enough","verify":"","deps":["zz"],"budget_usd":0},
  {"id":"b","prompt":"do b which is also long enough","verify":"true","budget_usd":1,"deps":["c"]},
  {"id":"c","prompt":"do c which is also long enough","verify":"true","budget_usd":1,"deps":["b"]}]})
print(len(errs) >= 4)
EOF
)
check "catches empty verify, bad dep, zero budget, cycle" "$BAD" "True"

echo "== 9. compiler: spec → validated plan (offline) =="
newrepo
echo "Build a greeter. AC1: a exists. AC2: b exists." > SPEC.md
git add -A; git commit -qm spec
cat > goodplan.json << 'EOF'
{"spec":"SPEC.md","fleet_budget_usd":6,
 "tasks":[
  {"id":"make-a","prompt":"Create file a.txt per the spec acceptance criterion AC1. TOUCH:a.txt",
   "verify":"test -f a.txt","protected":[],"budget_usd":2,"max_iterations":5,"deps":[]},
  {"id":"make-b","prompt":"Create file b.txt per AC2, building on a. TOUCH:b.txt",
   "verify":"test -f a.txt && test -f b.txt","protected":[],"budget_usd":2,"max_iterations":5,"deps":["make-a"]}]}
EOF
FAKE_PLAN="$R/goodplan.json" python3 "$SCRIPTS/compile_spec.py" SPEC.md \
  --claude-bin "$FAKE" --out plan/tasks.json >/dev/null 2>&1
check "compile exit 0"    "$?" "0"
check "plan written"      "$(test -f plan/tasks.json && echo yes)" "yes"
check "spec auto-protected" "$(python3 -c "import json;p=json.load(open('plan/tasks.json'));print(all('SPEC.md' in t['protected'] for t in p['tasks']))")" "True"

echo "== 10. supervisor e2e: worktrees, dep order, merge, fleet result =="
git add -A; git commit -qm plan
python3 "$SCRIPTS/supervisor.py" --plan plan/tasks.json --claude-bin "$FAKE" >/dev/null 2>&1
check "fleet exit 0"      "$?" "0"
check "dep output merged into base" "$(test -f a.txt && test -f b.txt && echo yes)" "yes"
check "merge commits exist" "$(git log --oneline | grep -c 'merge autonomous work')" "2"
FLEET_OK=$(python3 -c "import json;f=json.load(open('.loop/fleet-result.json'));print(sorted(f['completed'])==['make-a','make-b'] and not f['failed'])")
check "fleet-result.json" "$FLEET_OK" "True"

echo "== 11. supervisor: failing task skips dependents, fleet exits 1 =="
newrepo
cat > plan.json << 'EOF'
{"fleet_budget_usd":6,"tasks":[
 {"id":"doomed","prompt":"this task can never satisfy its verifier no matter what",
  "verify":"test -f never-created.txt","budget_usd":1.5,"max_iterations":3,"deps":[]},
 {"id":"child","prompt":"depends on doomed and should be skipped entirely. TOUCH:c.txt",
  "verify":"test -f c.txt","budget_usd":2,"max_iterations":3,"deps":["doomed"]}]}
EOF
git add -A; git commit -qm plan
python3 "$SCRIPTS/supervisor.py" --plan plan.json --claude-bin "$FAKE" --retries 0 >/dev/null 2>&1
check "fleet exit 1"      "$?" "1"
check "dependent skipped" "$(python3 -c "import json;print(json.load(open('.loop/fleet-result.json'))['skipped'])")" "['child']"
check "child never ran"   "$(test ! -f c.txt && echo yes)" "yes"

echo
echo "================= $PASS passed, $FAIL failed ================="
exit $([[ $FAIL -eq 0 ]] && echo 0 || echo 1)
