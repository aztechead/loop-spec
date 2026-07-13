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

echo "== 1. max-iterations ceiling halts and reports =="
newrepo
python3 "$SCRIPTS/loop.py" "do the thing forever" --task-id iters --claude-bin "$FAKE" \
  --max-iterations 3 --no-progress 99 >/dev/null 2>&1
check "exit 1"            "$?" "1"
check "halt_reason"       "$(reason .loop/iters/result.json)" "max_iterations"

echo "== 2. verifier pass → complete, exit 0, result contract =="
newrepo
python3 "$SCRIPTS/loop.py" "make work.txt have two lines" --task-id done --claude-bin "$FAKE" \
  --verify 'test "$(wc -l < work.txt)" -ge 2' --max-iterations 99 >/dev/null 2>&1
check "exit 0"            "$?" "0"
check "halt_reason"       "$(reason .loop/done/result.json)" "complete"
check "verifier.passed"   "$(python3 -c "import json;print(json.load(open('.loop/done/result.json'))['verifier']['passed'])")" "True"
check "iter raw log kept" "$(test -f .loop/done/iter-001.raw.json && echo yes)" "yes"
check "progress notes"    "$(test -f .loop/done/PROGRESS.md && echo yes)" "yes"
check "cost summed"       "$(python3 -c "import json;c=json.load(open('.loop/done/result.json'))['total_cost_usd'];print(isinstance(c,float) and c>0)")" "True"

echo "== 3. stall: no file changes =="
newrepo
FAKE_STILL=1 python3 "$SCRIPTS/loop.py" "spin" --task-id still --claude-bin "$FAKE" \
  --no-progress 2 --max-iterations 99 >/dev/null 2>&1
check "exit 1"            "$?" "1"
check "halt_reason"       "$(reason .loop/still/result.json)" "no_progress"

echo "== 4. stall: files churn but same verifier failure =="
newrepo
python3 "$SCRIPTS/loop.py" "churn files" --task-id churn --claude-bin "$FAKE" \
  --verify 'echo "FAILED: widget missing on line 42"; exit 1' \
  --no-progress 2 --max-iterations 99 >/dev/null 2>&1
check "exit 1"            "$?" "1"
check "halt_reason"       "$(reason .loop/churn/result.json)" "no_progress"

echo "== 5. verifier integrity: agent edits a protected file → fleet-fatal halt =="
newrepo
mkdir tests_dir; echo 'exit 1' > tests_dir/check.sh; git add -A; git commit -qm tests
FAKE_TAMPER=tests_dir/check.sh python3 "$SCRIPTS/loop.py" "cheat" --task-id cheat \
  --claude-bin "$FAKE" --verify 'bash tests_dir/check.sh' \
  --max-iterations 99 --no-progress 99 >/dev/null 2>&1
check "exit 1"            "$?" "1"
check "halt_reason"       "$(reason .loop/cheat/result.json)" "verifier_integrity"

echo "== 6. resume after interruption carries state =="
newrepo
python3 "$SCRIPTS/loop.py" "long job" --task-id long --claude-bin "$FAKE" \
  --max-iterations 2 --no-progress 99 >/dev/null 2>&1
ITER1=$(python3 -c "import json;print(json.load(open('.loop/long/state.json'))['iteration'])")
OUT=$(python3 "$SCRIPTS/loop.py" "long job" --task-id long --claude-bin "$FAKE" \
  --max-iterations 5 --no-progress 99 2>&1)
check "first run stopped at 2" "$ITER1" "2"
check "resume announced"  "$(grep -c 'Resuming' <<< "$OUT")" "1"
check "continued to 5"    "$(python3 -c "import json;print(json.load(open('.loop/long/state.json'))['iteration'])")" "5"

echo "== 7. config-file mode + library API =="
newrepo
cat > cfg.json << EOF
{"task":"make work.txt have two lines","task_id":"cfg",
 "verify":"test \"\$(wc -l < work.txt)\" -ge 2",
 "max_iterations":99,"claude_bin":"$FAKE"}
EOF
python3 "$SCRIPTS/loop.py" --config cfg.json >/dev/null 2>&1
check "config-mode exit 0" "$?" "0"
LIB=$(PYTHONPATH="$SCRIPTS" python3 - "$FAKE" << 'EOF'
import sys
from loop import LoopConfig, run_loop
r = run_loop(LoopConfig(task="two lines again", task_id="lib",
    verify='test "$(wc -l < work.txt)" -ge 4',
    max_iterations=99, claude_bin=sys.argv[1]))
print(r["halt_reason"])
EOF
)
check "library API complete" "$(tail -1 <<< "$LIB")" "complete"

echo "== 8. plan validation rejects garbage =="
BAD=$(PYTHONPATH="$SCRIPTS" python3 - << 'EOF'
from planlib import validate_plan
errs = validate_plan({"tasks":[
  {"id":"a","prompt":"do a thing that is long enough","verify":"","deps":["zz"]},
  {"id":"b","prompt":"do b which is also long enough","verify":"true","deps":["c"]},
  {"id":"c","prompt":"do c which is also long enough","verify":"true","deps":["b"]}]})
print(len(errs) >= 3)
EOF
)
check "catches empty verify, bad dep, cycle" "$BAD" "True"

echo "== 9. compiler: spec → validated plan (offline) =="
newrepo
echo "Build a greeter. AC1: a exists. AC2: b exists." > SPEC.md
git add -A; git commit -qm spec
cat > goodplan.json << 'EOF'
{"spec":"SPEC.md",
 "tasks":[
  {"id":"make-a","prompt":"Create file a.txt per the spec acceptance criterion AC1. TOUCH:a.txt",
   "verify":"test -f a.txt","protected":[],"max_iterations":5,"deps":[]},
  {"id":"make-b","prompt":"Create file b.txt per AC2, building on a. TOUCH:b.txt",
   "verify":"test -f a.txt && test -f b.txt","protected":[],"max_iterations":5,"deps":["make-a"]}]}
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
check "fleet cost summed" "$(python3 -c "import json;c=json.load(open('.loop/fleet-result.json'))['total_cost_usd'];print(isinstance(c,float) and c>0)")" "True"

echo "== 11. supervisor: failing task skips dependents, fleet exits 1 =="
newrepo
cat > plan.json << 'EOF'
{"tasks":[
 {"id":"doomed","prompt":"this task can never satisfy its verifier no matter what",
  "verify":"test -f never-created.txt","max_iterations":3,"deps":[]},
 {"id":"child","prompt":"depends on doomed and should be skipped entirely. TOUCH:c.txt",
  "verify":"test -f c.txt","max_iterations":3,"deps":["doomed"]}]}
EOF
git add -A; git commit -qm plan
python3 "$SCRIPTS/supervisor.py" --plan plan.json --claude-bin "$FAKE" --retries 0 >/dev/null 2>&1
check "fleet exit 1"      "$?" "1"
check "dependent skipped" "$(python3 -c "import json;print(json.load(open('.loop/fleet-result.json'))['skipped'])")" "['child']"
check "child never ran"   "$(test ! -f c.txt && echo yes)" "yes"

echo "== 12. --fallback-model flag + --retry-watchdog env reach the claude invocation =="
newrepo
REC="$R/rec.txt"
cat > recstub.sh << EOF
#!/usr/bin/env bash
{ echo "ARGV: \$*"; echo "WATCHDOG: \${CLAUDE_CODE_RETRY_WATCHDOG:-unset}"; } >> "$REC"
echo '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.1,"session_id":"s","num_turns":1,"result":"ok"}'
EOF
chmod +x recstub.sh
python3 "$SCRIPTS/loop.py" "noop" --task-id fb --claude-bin "$R/recstub.sh" \
  --fallback-model claude-haiku-4-5-20251001 --retry-watchdog 5 \
  --max-iterations 1 --verify 'true' >/dev/null 2>&1
check "fallback-model flag passed" "$(grep -c -- '--fallback-model claude-haiku-4-5-20251001' "$REC")" "1"
check "retry-watchdog env set"      "$(grep -c 'WATCHDOG: 5' "$REC")" "1"

# Default (flags omitted): no fallback flag, watchdog inherited (unset here)
newrepo
REC2="$R/rec.txt"
cat > recstub.sh << EOF
#!/usr/bin/env bash
{ echo "ARGV: \$*"; echo "WATCHDOG: \${CLAUDE_CODE_RETRY_WATCHDOG:-unset}"; } >> "$REC2"
echo '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.1,"session_id":"s","num_turns":1,"result":"ok"}'
EOF
chmod +x recstub.sh
env -u CLAUDE_CODE_RETRY_WATCHDOG python3 "$SCRIPTS/loop.py" "noop" --task-id nofb --claude-bin "$R/recstub.sh" \
  --max-iterations 1 --verify 'true' >/dev/null 2>&1
check "no fallback flag by default"  "$(grep -c -- '--fallback-model' "$REC2")" "0"
check "watchdog unset by default"    "$(grep -c 'WATCHDOG: unset' "$REC2")" "1"

echo "== 13. git error degrade: non-git dir returns safe empty values =="
NOGIT="$(mktemp -d)"   # NOT a git repo — git commands return rc=128
cd "$NOGIT"

# workspace_hash returns "" in a non-git dir (fixes latent bug: previously hashed
# empty stdout to a non-empty constant, making files_changed permanently False).
# Use tail -1 to get just the repr line (warn_once prints before the return value).
WH=$(PYTHONPATH="$SCRIPTS" python3 -c "
import sys; sys.path.insert(0, '$SCRIPTS')
from loop import workspace_hash, _warned
_warned.clear()
print(repr(workspace_hash('x')))
" 2>/dev/null | tail -1)
check "workspace_hash returns empty string in non-git dir" "$WH" "''"

# degraded warning is printed (and only once across two calls)
WH_OUT=$(PYTHONPATH="$SCRIPTS" python3 -c "
import sys; sys.path.insert(0, '$SCRIPTS')
from loop import workspace_hash, _warned
_warned.clear()
workspace_hash('x')
workspace_hash('x')
" 2>&1)
check "workspace_hash prints stall-detection-degraded warning" \
  "$(echo "$WH_OUT" | grep -c 'stall detection degraded')" "1"

# git_commit_scoped returns "failed" in a non-git dir
CS_OUT=$(PYTHONPATH="$SCRIPTS" python3 -c "
import sys; sys.path.insert(0, '$SCRIPTS')
from loop import git_commit_scoped
print(git_commit_scoped('msg', '.loop'))
" 2>&1)
check "git_commit_scoped returns failed in non-git dir" \
  "$(echo "$CS_OUT" | tail -1)" "failed"
check "git_commit_scoped prints commit-failed warning in non-git dir" \
  "$(echo "$CS_OUT" | grep -c 'commit failed')" "1"

# git_sha returns "" in a non-git dir; use tail -1 to get just the repr line
GS=$(PYTHONPATH="$SCRIPTS" python3 -c "
import sys; sys.path.insert(0, '$SCRIPTS')
from loop import git_sha, _warned
_warned.clear()
print(repr(git_sha()))
" 2>/dev/null | tail -1)
check "git_sha returns empty string in non-git dir" "$GS" "''"

echo "== 14. hung-tick timeout: per-tick subprocess timeout kills a hung claude -p =="
newrepo
HUNG_OUT=$(FAKE_HANG=15 PYTHONPATH="$SCRIPTS" python3 - "$FAKE" << 'EOF'
import sys
import loop
loop.MIN_TICK_TIMEOUT = 1.0
from loop import LoopConfig, run_loop
r = run_loop(LoopConfig(task="hang", task_id="hang",
    claude_bin=sys.argv[1], timeout_s=8, max_iterations=3))
print(r["halt_reason"])
EOF
2>&1)
check "hung-tick halts with timeout" "$(echo "$HUNG_OUT" | tail -1)" "timeout"

echo "== 15. read_result: missing and corrupt result.json =="
TMPDIR_RR="$(mktemp -d)"
RR_MISS=$(PYTHONPATH="$SCRIPTS" python3 -c "
import sys; sys.path.insert(0, '$SCRIPTS')
from pathlib import Path
from supervisor import read_result
r = read_result(Path('$TMPDIR_RR/nofile.json'), 't1', Path('$TMPDIR_RR/t.log'))
print(r['halt_reason'])
print('no result.json' in r.get('error', ''))
")
check "missing → agent_error"         "$(echo "$RR_MISS" | head -1)" "agent_error"
check "missing → 'no result.json'"    "$(echo "$RR_MISS" | tail -1)" "True"

echo "bad json" > "$TMPDIR_RR/bad.json"
RR_BAD=$(PYTHONPATH="$SCRIPTS" python3 -c "
import sys; sys.path.insert(0, '$SCRIPTS')
from pathlib import Path
from supervisor import read_result
r = read_result(Path('$TMPDIR_RR/bad.json'), 't2', Path('$TMPDIR_RR/t.log'))
print(r['halt_reason'])
print('corrupt result.json' in r.get('error', ''))
")
check "corrupt → agent_error"               "$(echo "$RR_BAD" | head -1)" "agent_error"
check "corrupt → 'corrupt result.json'"     "$(echo "$RR_BAD" | tail -1)" "True"

echo "== 16. pi backend: --agent-cli pi speaks the event-stream protocol =="
FAKEPI="$HERE/fakepi"; chmod +x "$FAKEPI"

# 16a. complete run: same result contract as the claude backend
newrepo
python3 "$SCRIPTS/loop.py" "make work.txt have two lines" --task-id pidone \
  --agent-cli pi --claude-bin "$FAKEPI" \
  --verify 'test "$(wc -l < work.txt)" -ge 2' --max-iterations 99 >/dev/null 2>&1
check "pi exit 0"          "$?" "0"
check "pi halt_reason"     "$(reason .loop/pidone/result.json)" "complete"
check "pi cost from usage" "$(python3 -c "import json;c=json.load(open('.loop/pidone/result.json'))['total_cost_usd'];print(isinstance(c,float) and c>0)")" "True"
check "pi raw log kept"    "$(test -f .loop/pidone/iter-001.raw.json && echo yes)" "yes"

# 16b. flag shape: pi gets pi flags, never claude-only ones
newrepo
PILOG="$R/piargv.txt"
FAKE_ARGV_LOG="$PILOG" python3 "$SCRIPTS/loop.py" "noop" --task-id piflags \
  --agent-cli pi --claude-bin "$FAKEPI" --model claude-sonnet-4-5 \
  --fallback-model some-model --retry-watchdog 5 \
  --max-iterations 1 --verify 'true' >/dev/null 2>&1
check "pi: --mode json"            "$(grep -c -- '--mode json' "$PILOG")" "1"
check "pi: --no-session (fresh)"   "$(grep -c -- '--no-session' "$PILOG")" "1"
check "pi: --model passed"         "$(grep -c -- '--model claude-sonnet-4-5' "$PILOG")" "1"
check "pi: claude-only flags dropped" "$(grep -cE -- '--fallback-model|--permission-mode|--output-format|--allowedTools' "$PILOG")" "0"

# 16c. compiler via pi backend: read-only pass = --no-builtin-tools
newrepo
echo "Build a greeter. AC1: a exists. AC2: b exists." > SPEC.md
git add -A; git commit -qm spec
cat > goodplan.json << 'EOF'
{"spec":"SPEC.md",
 "tasks":[
  {"id":"make-a","prompt":"Create a.txt per AC1. TOUCH:a.txt",
   "verify":"test -f a.txt","protected":[],"max_iterations":5,"deps":[]}]}
EOF
PILOG2="$R/piargv2.txt"
FAKE_PLAN="$R/goodplan.json" FAKE_ARGV_LOG="$PILOG2" python3 "$SCRIPTS/compile_spec.py" SPEC.md \
  --agent-cli pi --claude-bin "$FAKEPI" --out plan/tasks.json >/dev/null 2>&1
check "pi compile exit 0"      "$?" "0"
check "pi plan written"        "$(test -f plan/tasks.json && echo yes)" "yes"
check "pi read-only compile"   "$(grep -c -- '--no-builtin-tools' "$PILOG2")" "1"

# 16d. auto-detection: a binary named `pi` selects the pi protocol on its own
newrepo
cp "$FAKEPI" "$R/pi"; chmod +x "$R/pi"
python3 "$SCRIPTS/loop.py" "make work.txt have two lines" --task-id piauto \
  --claude-bin "$R/pi" \
  --verify 'test "$(wc -l < work.txt)" -ge 2' --max-iterations 99 >/dev/null 2>&1
check "pi auto exit 0"      "$?" "0"
check "pi auto halt_reason" "$(reason .loop/piauto/result.json)" "complete"

# 16e. supervisor passes --agent-cli through to every loop tick
newrepo
cat > plan.json << 'EOF'
{"tasks":[
 {"id":"solo","prompt":"make the file. TOUCH:s.txt",
  "verify":"test -f s.txt","max_iterations":3,"deps":[]}]}
EOF
git add -A; git commit -qm plan
python3 "$SCRIPTS/supervisor.py" --plan plan.json --agent-cli pi --claude-bin "$FAKEPI" >/dev/null 2>&1
check "pi fleet exit 0"     "$?" "0"
check "pi fleet completed"  "$(python3 -c "import json;print(json.load(open('.loop/fleet-result.json'))['completed'])")" "['solo']"

# 16f. transport conflict fails fast: --agent-cli pi pointed at a claude binary
newrepo
cp "$FAKE" "$R/claude"; chmod +x "$R/claude"
python3 "$SCRIPTS/loop.py" "noop" --task-id conflict --agent-cli pi --claude-bin "$R/claude" \
  --max-iterations 1 >/dev/null 2>"$R/err.txt"
check "conflict exit 2"     "$?" "2"
check "conflict names both flags" "$(grep -c 'does not speak' "$R/err.txt")" "1"

echo "== 17. opencode backend: --agent-cli opencode speaks run --format json =="
FAKEOC="$HERE/fakeopencode"; chmod +x "$FAKEOC"

# 17a. complete run: same result contract as the claude backend
newrepo
python3 "$SCRIPTS/loop.py" "make work.txt have two lines" --task-id ocdone \
  --agent-cli opencode --claude-bin "$FAKEOC" \
  --verify 'test "$(wc -l < work.txt)" -ge 2' --max-iterations 99 >/dev/null 2>&1
check "oc exit 0"          "$?" "0"
check "oc halt_reason"     "$(reason .loop/ocdone/result.json)" "complete"
check "oc cost from step_finish" "$(python3 -c "import json;c=json.load(open('.loop/ocdone/result.json'))['total_cost_usd'];print(isinstance(c,float) and c>0)")" "True"
check "oc raw log kept"    "$(test -f .loop/ocdone/iter-001.raw.json && echo yes)" "yes"

# 17b. flag shape: opencode gets opencode flags, never claude-only ones
newrepo
OCLOG="$R/ocargv.txt"
FAKE_ARGV_LOG="$OCLOG" python3 "$SCRIPTS/loop.py" "noop" --task-id ocflags \
  --agent-cli opencode --claude-bin "$FAKEOC" --model anthropic/claude-sonnet-4-5 \
  --fallback-model some-model --retry-watchdog 5 \
  --max-iterations 1 --verify 'true' >/dev/null 2>&1
check "oc: run --format json"      "$(grep -c -- 'run --format json' "$OCLOG")" "1"
check "oc: --auto (work tick)"     "$(grep -c -- '--auto' "$OCLOG")" "1"
check "oc: --model passed"         "$(grep -c -- '--model anthropic/claude-sonnet-4-5' "$OCLOG")" "1"
check "oc: claude-only flags dropped" "$(grep -cE -- '--fallback-model|--permission-mode|--output-format|--allowedTools' "$OCLOG")" "0"

# 17c. compiler via opencode backend: read-only pass = --agent plan, no --auto
newrepo
echo "Build a greeter. AC1: a exists. AC2: b exists." > SPEC.md
git add -A; git commit -qm spec
cat > goodplan.json << 'EOF'
{"spec":"SPEC.md",
 "tasks":[
  {"id":"make-a","prompt":"Create a.txt per AC1. TOUCH:a.txt",
   "verify":"test -f a.txt","protected":[],"max_iterations":5,"deps":[]}]}
EOF
OCLOG2="$R/ocargv2.txt"
FAKE_PLAN="$R/goodplan.json" FAKE_ARGV_LOG="$OCLOG2" python3 "$SCRIPTS/compile_spec.py" SPEC.md \
  --agent-cli opencode --claude-bin "$FAKEOC" --out plan/tasks.json >/dev/null 2>&1
check "oc compile exit 0"      "$?" "0"
check "oc plan written"        "$(test -f plan/tasks.json && echo yes)" "yes"
check "oc read-only compile"   "$(grep -c -- '--agent plan' "$OCLOG2")" "1"
check "oc plan tick has no --auto" "$(grep -c -- '--auto' "$OCLOG2")" "0"

# 17d. auto-detection: a binary named `opencode` selects the protocol on its own
newrepo
cp "$FAKEOC" "$R/opencode"; chmod +x "$R/opencode"
python3 "$SCRIPTS/loop.py" "make work.txt have two lines" --task-id ocauto \
  --claude-bin "$R/opencode" \
  --verify 'test "$(wc -l < work.txt)" -ge 2' --max-iterations 99 >/dev/null 2>&1
check "oc auto exit 0"      "$?" "0"
check "oc auto halt_reason" "$(reason .loop/ocauto/result.json)" "complete"

# 17e. supervisor passes --agent-cli opencode through to every loop tick
newrepo
cat > plan.json << 'EOF'
{"tasks":[
 {"id":"solo","prompt":"make the file. TOUCH:s.txt",
  "verify":"test -f s.txt","max_iterations":3,"deps":[]}]}
EOF
git add -A; git commit -qm plan
python3 "$SCRIPTS/supervisor.py" --plan plan.json --agent-cli opencode --claude-bin "$FAKEOC" >/dev/null 2>&1
check "oc fleet exit 0"     "$?" "0"
check "oc fleet completed"  "$(python3 -c "import json;print(json.load(open('.loop/fleet-result.json'))['completed'])")" "['solo']"

# 17f. transport conflict fails fast: --agent-cli opencode at a claude binary
newrepo
cp "$FAKE" "$R/claude"; chmod +x "$R/claude"
python3 "$SCRIPTS/loop.py" "noop" --task-id occonflict --agent-cli opencode \
  --claude-bin "$R/claude" --max-iterations 1 >/dev/null 2>"$R/ocerr.txt"
check "oc conflict exit 2"     "$?" "2"
check "oc conflict names both flags" "$(grep -c 'does not speak' "$R/ocerr.txt")" "1"

# 17g. resume passes --session (continue mode threads the session id through)
newrepo
OCLOG3="$R/ocargv3.txt"
FAKE_ARGV_LOG="$OCLOG3" python3 "$SCRIPTS/loop.py" "two lines. TOUCH:work.txt" --task-id ocresume \
  --mode continue --agent-cli opencode --claude-bin "$FAKEOC" \
  --verify 'test "$(wc -l < work.txt)" -ge 2' --max-iterations 3 >/dev/null 2>&1
check "oc resume exit 0"       "$?" "0"
check "oc --session on resume" "$(grep -c -- '--session ses_opencode_abc' "$OCLOG3")" "1"

echo
echo "================= $PASS passed, $FAIL failed ================="
exit $([[ $FAIL -eq 0 ]] && echo 0 || echo 1)
