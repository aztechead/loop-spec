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

python3 "$HERE/config_flags.py" || exit 1

newrepo() {
  R="$(mktemp -d)"; cd "$R"
  git init -q -b main; git config user.email t@t.t; git config user.name t
  echo base > base.txt; git add -A; git commit -qm init
}

write_compiler_fixture() {
  echo "Build a greeter. AC1: a exists. AC2: b exists." > SPEC.md
  git add -A; git commit -qm spec
  cat > goodplan.json << 'EOF'
{"spec":"SPEC.md",
 "tasks":[
  {"id":"make-a","prompt":"Create a.txt per AC1. TOUCH:a.txt",
   "verify":"test -f a.txt","protected":[],"max_iterations":5,"deps":[]}]}
EOF
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

LOOP_SPEC_WORKTREES=0 python3 "$SCRIPTS/supervisor.py" --plan plan/tasks.json \
  --dry-run >/dev/null 2>&1
check "worktree opt-out supports serial supervisor" "$?" "0"
LOOP_SPEC_WORKTREES=0 python3 "$SCRIPTS/supervisor.py" --plan plan/tasks.json \
  --dry-run --parallel 2 >/dev/null 2>&1
check "worktree opt-out rejects parallel supervisor" "$?" "2"
LOOP_SPEC_WORKTREES=invalid python3 "$SCRIPTS/supervisor.py" --plan plan/tasks.json \
  --dry-run >/dev/null 2>&1
check "invalid worktree env rejects supervisor" "$?" "2"

echo "== 10. supervisor e2e: worktrees, dep order, merge, fleet result =="
git add -A; git commit -qm plan
python3 "$SCRIPTS/supervisor.py" --plan plan/tasks.json --claude-bin "$FAKE" >/dev/null 2>&1
check "fleet exit 0"      "$?" "0"
check "dep output merged into base" "$(test -f a.txt && test -f b.txt && echo yes)" "yes"
check "merge commits exist" "$(git log --oneline | grep -c 'merge autonomous work')" "2"
FLEET_OK=$(python3 -c "import json;f=json.load(open('.loop/fleet-result.json'));print(sorted(f['completed'])==['make-a','make-b'] and not f['failed'])")
check "fleet-result.json" "$FLEET_OK" "True"
check "fleet terminal status" "$(python3 -c "import json;print(json.load(open('.loop/fleet-result.json'))['status'])")" "complete"
check "fleet cost summed" "$(python3 -c "import json;c=json.load(open('.loop/fleet-result.json'))['total_cost_usd'];print(isinstance(c,float) and c>0)")" "True"

SUPERVISOR_CANDIDATE=$(PYTHONPATH="$SCRIPTS" python3 - << 'EOF'
import json
import subprocess
from pathlib import Path
import supervisor

candidate = "b" * 40
feature_before = "a" * 40
commands = []

def fake_sh(cmd, cwd, timeout=300):
    commands.append(cmd)
    if cmd[:4] == ["git", "symbolic-ref", "--quiet", "--short"]:
        return subprocess.CompletedProcess(cmd, 0, "main\n", "")
    if cmd and cmd[0] == "bash":
        result = {"status": "success", "reason": "ready", "detail": "preflight-complete",
                  "candidate": candidate, "featureBefore": feature_before}
        return subprocess.CompletedProcess(cmd, 0, json.dumps(result), "")
    if cmd == ["git", "rev-parse", "HEAD"]:
        return subprocess.CompletedProcess(cmd, 0, feature_before + "\n", "")
    if cmd[:2] == ["git", "merge"]:
        return subprocess.CompletedProcess(cmd, 0, "", "")
    return subprocess.CompletedProcess(cmd, 1, "", "unexpected command")

supervisor.sh = fake_sh
class Args:
    feature_dir = ".loop-spec/features/demo"
s = supervisor.Supervisor({"tasks": [{"id": "immutable", "verify": "true"}]},
                          Path("/tmp/repo"), Args())
ok = s.merge("immutable")
merge_cmd = next(cmd for cmd in commands if cmd[:2] == ["git", "merge"])
preflight_cmd = next(cmd for cmd in commands if cmd and cmd[0] == "bash")
print(ok and merge_cmd[-1] == candidate and "loop/immutable" not in merge_cmd
      and "--no-ff" in merge_cmd and "feature-validation.sh" in preflight_cmd[preflight_cmd.index("--verify") + 1])
EOF
)
check "supervisor merges immutable preflight candidate with no-ff" "$SUPERVISOR_CANDIDATE" "True"

SUPERVISOR_TIMEOUT=$(PYTHONPATH="$SCRIPTS" python3 - << 'EOF'
import subprocess
from pathlib import Path
from unittest.mock import patch
import supervisor

class Args:
    no_worktree = True
    prepare_command = ""
    task_timeout = 1
    retries = 0
    model = ""
    fallback_model = ""
    retry_watchdog = ""
    max_budget_usd = 0.0
    claude_bin = "claude"
    agent_cli = "claude"

plan = {"tasks": [{"id": "hung", "prompt": "long enough task prompt",
                   "verify": "true", "deps": []}]}
s = supervisor.Supervisor(plan, Path("/tmp"), Args())
completed = subprocess.CompletedProcess([], 0, "", "")
with patch.object(supervisor, "sh", return_value=completed), \
     patch.object(supervisor, "run_bounded_process", side_effect=[0, subprocess.TimeoutExpired("loop", 31)]):
    result = s.run_task("hung")
print(result["halt_reason"])
print("made no progress" in result["error"])
EOF
)
check "supervisor outer timeout is structured" "$(echo "$SUPERVISOR_TIMEOUT" | tail -2 | head -1)" "supervisor_timeout"
check "supervisor timeout is loud" "$(echo "$SUPERVISOR_TIMEOUT" | tail -1)" "True"

PROCESS_GROUP=$(PYTHONPATH="$SCRIPTS" python3 - << 'EOF'
import signal
import subprocess
import tempfile
from pathlib import Path
from unittest.mock import Mock, patch
import supervisor

proc = Mock(pid=123)
proc.wait.side_effect = [subprocess.TimeoutExpired("worker", 1), 0]
with tempfile.TemporaryDirectory() as td, \
     patch.object(supervisor.subprocess, "Popen", return_value=proc) as popen, \
     patch.object(supervisor.os, "killpg") as killpg:
    supervisor.CANCEL_EVENT.clear()
    try:
        supervisor.run_bounded_process(["worker"], Path(td), Path(td) / "worker.log", 1)
    except subprocess.TimeoutExpired:
        pass
    print(popen.call_args.kwargs.get("start_new_session") is True)
    print(killpg.call_args_list[0].args == (123, signal.SIGTERM))
EOF
)
check "worker starts in isolated process group" "$(echo "$PROCESS_GROUP" | head -1)" "True"
check "timeout terminates worker process group" "$(echo "$PROCESS_GROUP" | tail -1)" "True"

CANCEL_START=$(PYTHONPATH="$SCRIPTS" python3 - << 'EOF'
import tempfile
from pathlib import Path
from unittest.mock import patch
import supervisor

with tempfile.TemporaryDirectory() as td, \
     patch.object(supervisor.subprocess, "Popen") as popen:
    supervisor.CANCEL_EVENT.set()
    try:
        supervisor.run_bounded_process(["worker"], Path(td), Path(td) / "worker.log", 1)
    except supervisor.FleetCancelled:
        pass
    print(not popen.called)
EOF
)
check "cancelled fleet starts no late worker" "$(echo "$CANCEL_START" | tail -1)" "True"

SUPERVISOR_CRASH=$(PYTHONPATH="$SCRIPTS" python3 - << 'EOF'
import json
import tempfile
from pathlib import Path
from unittest.mock import patch
import supervisor

class Args:
    plan = "plan.json"

with tempfile.TemporaryDirectory() as td:
    s = supervisor.Supervisor({"tasks": []}, Path(td), Args())
    s.done_merged.add("done")
    s.results["done"] = {"task_id": "done", "status": "complete"}
    try:
        with patch.object(s, "_run", side_effect=RuntimeError("boom")):
            s.run()
    except RuntimeError:
        pass
    result = json.load(open(Path(td) / ".loop" / "fleet-result.json"))
    print(result["status"])
    print(result["tasks"]["__supervisor__"]["halt_reason"])
    print(result["completed"] == ["done"])
EOF
)
check "supervisor crash terminalizes fleet" "$(echo "$SUPERVISOR_CRASH" | tail -3 | head -1)" "incomplete"
check "supervisor crash records halt reason" "$(echo "$SUPERVISOR_CRASH" | tail -2 | head -1)" "supervisor_error"
check "supervisor crash preserves merged progress" "$(echo "$SUPERVISOR_CRASH" | tail -1)" "True"

FATAL_CANCEL=$(PYTHONPATH="$SCRIPTS" python3 - << 'EOF'
import tempfile
from pathlib import Path
from unittest.mock import patch
import supervisor

class Args:
    plan = "plan.json"
    parallel = 2
    no_worktree = True
    cleanup_worktrees = False

plan = {"tasks": [
    {"id": "fatal", "prompt": "fatal task long enough", "verify": "true", "deps": []},
    {"id": "peer", "prompt": "peer task long enough", "verify": "true", "deps": []},
]}

with tempfile.TemporaryDirectory() as td:
    s = supervisor.Supervisor(plan, Path(td), Args())
    def result(tid):
        if tid == "fatal":
            s.fleet_fatal = True
            return {"task_id": tid, "status": "halted", "halt_reason": "verifier_integrity"}
        return {"task_id": tid, "status": "complete", "halt_reason": "complete", "iterations": 1}
    with patch.object(s, "run_task", side_effect=result), \
         patch.object(supervisor, "terminate_active_workers") as terminate:
        rc = s.run()
    fleet = __import__("json").load(open(Path(td) / ".loop" / "fleet-result.json"))
    print(rc)
    print("peer" not in fleet["completed"])
    print(terminate.called)
EOF
)
check "integrity fatal returns incomplete" "$(echo "$FATAL_CANCEL" | tail -3 | head -1)" "1"
check "integrity fatal merges no concurrent peer" "$(echo "$FATAL_CANCEL" | tail -2 | head -1)" "True"
check "integrity fatal terminates active workers" "$(echo "$FATAL_CANCEL" | tail -1)" "True"

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

echo "== 11b. startup failure cannot reuse a stale terminal fleet result =="
newrepo
mkdir -p .loop
printf '{"status":"complete","completed":[],"failed":[],"skipped":[]}\n' > .loop/fleet-result.json
printf '{"tasks":[]}\n' > invalid-plan.json
python3 "$SCRIPTS/supervisor.py" --plan invalid-plan.json >/dev/null 2>&1
check "invalid plan exits 2" "$?" "2"
check "stale fleet result cleared" "$(test ! -f .loop/fleet-result.json && echo yes)" "yes"

echo "== 11c. CLI and JSON limits reject values outside the documented bounds =="
python3 "$SCRIPTS/loop.py" "bad bounds" --max-iterations 0 >/dev/null 2>&1
rc=$?
check "loop rejects zero max-iterations" "$rc" "2"

printf '{"task":"bad config","timeout_s":-1}\n' > bad-bounds.json
python3 "$SCRIPTS/loop.py" --config bad-bounds.json >/dev/null 2>&1
rc=$?
check "loop rejects negative JSON timeout" "$rc" "2"

python3 "$SCRIPTS/supervisor.py" --plan invalid-plan.json --parallel 0 --dry-run >/dev/null 2>&1
rc=$?
check "supervisor rejects zero parallelism" "$rc" "2"

python3 "$SCRIPTS/supervisor.py" --plan invalid-plan.json --max-budget-usd -1 --dry-run >/dev/null 2>&1
rc=$?
check "supervisor rejects negative budget" "$rc" "2"

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
  --max-turns 12 --effort medium --max-iterations 1 --verify 'true' >/dev/null 2>&1
check "fallback-model flag passed" "$(grep -c -- '--fallback-model claude-haiku-4-5-20251001' "$REC")" "1"
check "retry-watchdog env set"      "$(grep -c 'WATCHDOG: 5' "$REC")" "1"
check "max-turns flag passed"       "$(grep -c -- '--max-turns 12' "$REC")" "1"
check "effort flag passed"          "$(grep -c -- '--effort medium' "$REC")" "1"

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

echo "== 16. adk backend: --agent-cli adk speaks the JSONL event protocol =="
FAKEADK="$HERE/fakeadk"; chmod +x "$FAKEADK"
# ADK dispatches at a mounted agent DIRECTORY; the read-only sibling is what
# plan-mode ticks select, so both must exist for the backend to run.
mkadkagent() { mkdir -p "$R/loop_spec" "$R/loop_spec_readonly"; }

# 16a. complete run: same result contract as the claude backend
newrepo; mkadkagent
python3 "$SCRIPTS/loop.py" "make work.txt have two lines" --task-id adkdone \
  --agent-cli adk --claude-bin "$FAKEADK" --adk-agent-dir "$R/loop_spec" \
  --verify 'test "$(wc -l < work.txt)" -ge 2' --max-iterations 99 >/dev/null 2>&1
check "adk exit 0"          "$?" "0"
check "adk halt_reason"     "$(reason .loop/adkdone/result.json)" "complete"
check "adk raw log kept"    "$(test -f .loop/adkdone/iter-001.raw.json && echo yes)" "yes"
# ADK reports tokens, not money: cost stays unknown rather than being invented.
check "adk cost unknown"    "$(python3 -c "import json;print(json.load(open('.loop/adkdone/result.json'))['total_cost_usd'])")" "None"

# 16b. flag shape: adk gets adk flags, never claude-only ones
newrepo; mkadkagent
ADKLOG="$R/adkargv.txt"
FAKE_ARGV_LOG="$ADKLOG" python3 "$SCRIPTS/loop.py" "noop" --task-id adkflags \
  --agent-cli adk --claude-bin "$FAKEADK" --adk-agent-dir "$R/loop_spec" \
  --model gemini-2.5-flash --fallback-model some-model --retry-watchdog 5 \
  --max-iterations 1 --verify 'true' >/dev/null 2>&1
check "adk: --jsonl"                "$(grep -c -- '--jsonl' "$ADKLOG")" "1"
check "adk: agent dir positional"   "$(grep -c -- "run $R/loop_spec " "$ADKLOG")" "1"
check "adk: gemini model passed"    "$(grep -c -- '--default_llm_model gemini-2.5-flash' "$ADKLOG")" "1"
check "adk: claude-only flags dropped" "$(grep -cE -- '--fallback-model|--permission-mode|--output-format|--allowedTools' "$ADKLOG")" "0"

# 16b-1. One-shot ADK runs are explicitly non-interactive and continue mode
# restores the session emitted by the first tick.
newrepo; mkadkagent
ADKLOG_RESUME="$R/adkargv-resume.txt"
ADKENV="$R/adkenv.txt"
FAKE_ARGV_LOG="$ADKLOG_RESUME" FAKE_ENV_LOG="$ADKENV" \
  python3 "$SCRIPTS/loop.py" "make work.txt have two lines" --task-id adkresume \
  --agent-cli adk --claude-bin "$FAKEADK" --adk-agent-dir "$R/loop_spec" \
  --mode continue --verify 'test "$(wc -l < work.txt)" -ge 2' \
  --max-iterations 3 >/dev/null 2>&1
check "adk: continue resumes session" "$(grep -c -- '--session_id adksess-abc' "$ADKLOG_RESUME")" "1"
check "adk: one-shot marker reaches child" "$(grep -cv '^1$' "$ADKENV")" "0"

# 16b-2. A Claude alias is not an ADK model id; it must be dropped, not forwarded.
newrepo; mkadkagent
ADKLOG_ALIAS="$R/adkargv-alias.txt"
FAKE_ARGV_LOG="$ADKLOG_ALIAS" python3 "$SCRIPTS/loop.py" "noop" --task-id adkalias \
  --agent-cli adk --claude-bin "$FAKEADK" --adk-agent-dir "$R/loop_spec" \
  --model claude-sonnet-4-5 --max-iterations 1 --verify 'true' >/dev/null 2>&1
check "adk: claude alias dropped"   "$(grep -c -- '--default_llm_model' "$ADKLOG_ALIAS")" "0"

# 16b-3. The portable selector inherits the mounted agent's model.
newrepo; mkadkagent
ADKLOG_INHERIT="$R/adkargv-inherit.txt"
FAKE_ARGV_LOG="$ADKLOG_INHERIT" python3 "$SCRIPTS/loop.py" "noop" --task-id adkinherit \
  --agent-cli adk --claude-bin "$FAKEADK" --adk-agent-dir "$R/loop_spec" \
  --model inherit --max-iterations 1 --verify 'true' >/dev/null 2>&1
check "adk: inherit model omitted"  "$(grep -c -- '--default_llm_model' "$ADKLOG_INHERIT")" "0"

# 16b-4. LOOP_SPEC_ADK_AGENT_DIR is the installer's channel for the same value.
newrepo; mkadkagent
ADKLOG_ENV="$R/adkargv-env.txt"
LOOP_SPEC_ADK_AGENT_DIR="$R/loop_spec" FAKE_ARGV_LOG="$ADKLOG_ENV" \
  python3 "$SCRIPTS/loop.py" "noop" --task-id adkenv \
  --agent-cli adk --claude-bin "$FAKEADK" \
  --max-iterations 1 --verify 'true' >/dev/null 2>&1
check "adk: agent dir from env"     "$(grep -c -- "run $R/loop_spec " "$ADKLOG_ENV")" "1"

# 16b-5. No agent directory at all names the missing prerequisite. A bad tick is
# retried rather than halted (see run_loop), so the proof is the reported reason,
# not the halt_reason — what must never happen is a bare crash or a silent dispatch.
newrepo
python3 "$SCRIPTS/loop.py" "noop" --task-id adknodir \
  --agent-cli adk --claude-bin "$FAKEADK" \
  --max-iterations 1 --verify 'false' >"$R/nodir.txt" 2>&1
check "adk: missing dir named"  "$(grep -c 'LOOP_SPEC_ADK_AGENT_DIR' "$R/nodir.txt")" "1"
check "adk: missing dir points at installer" "$(grep -c 'adk-install.sh' "$R/nodir.txt")" "1"

# 16c. compiler via adk backend: read-only pass selects the _readonly agent
newrepo; mkadkagent
write_compiler_fixture
ADKLOG2="$R/adkargv2.txt"
FAKE_PLAN="$R/goodplan.json" FAKE_ARGV_LOG="$ADKLOG2" \
  python3 "$SCRIPTS/compile_spec.py" SPEC.md \
  --agent-cli adk --claude-bin "$FAKEADK" --adk-agent-dir "$R/loop_spec" \
  --out plan/tasks.json >/dev/null 2>&1
check "adk compile exit 0"      "$?" "0"
check "adk plan written"        "$(test -f plan/tasks.json && echo yes)" "yes"
check "adk read-only agent"     "$(grep -c -- "run ${R}/loop_spec_readonly " "$ADKLOG2")" "1"

# 16c-2. A missing read-only agent fails loudly instead of silently handing a
# judge the writable agent's edit tools.
newrepo; mkdir -p "$R/loop_spec"
ADKLOG3="$R/adkargv3.txt"
FAKE_PLAN="$R/goodplan.json" FAKE_ARGV_LOG="$ADKLOG3" LOOP_SPEC_ADK_AGENT_DIR="$R/loop_spec" \
  python3 "$SCRIPTS/compile_spec.py" SPEC.md \
  --agent-cli adk --claude-bin "$FAKEADK" --out plan/tasks.json >/dev/null 2>&1
check "adk missing readonly fails closed"   "$?" "1"
check "adk missing readonly writes no plan" "$(test -f plan/tasks.json && echo yes || echo no)" "no"
check "adk missing readonly dispatched none" "$(test -f "$ADKLOG3" && echo yes || echo no)" "no"

# 16d. auto-detection: a binary named `adk` selects the adk protocol on its own
newrepo; mkadkagent
cp "$FAKEADK" "$R/adk"; chmod +x "$R/adk"
LOOP_SPEC_ADK_AGENT_DIR="$R/loop_spec" python3 "$SCRIPTS/loop.py" \
  "make work.txt have two lines" --task-id adkauto --claude-bin "$R/adk" \
  --verify 'test "$(wc -l < work.txt)" -ge 2' --max-iterations 99 >/dev/null 2>&1
check "adk auto exit 0"      "$?" "0"
check "adk auto halt_reason" "$(reason .loop/adkauto/result.json)" "complete"

# 16e. supervisor passes --agent-cli through to every loop tick
newrepo; mkadkagent
cat > plan.json << 'EOF'
{"tasks":[
 {"id":"solo","prompt":"make the file. TOUCH:s.txt",
  "verify":"test -f s.txt","max_iterations":3,"deps":[]}]}
EOF
git add -A; git commit -qm plan
python3 "$SCRIPTS/supervisor.py" \
  --plan plan.json --agent-cli adk --claude-bin "$FAKEADK" \
  --adk-agent-dir "$R/loop_spec" >/dev/null 2>&1
check "adk fleet exit 0"     "$?" "0"
check "adk fleet completed"  "$(python3 -c "import json;print(json.load(open('.loop/fleet-result.json'))['completed'])")" "['solo']"

# 16e-2. An ADK judge inherits the explicit mount and selects its read-only sibling.
newrepo; mkadkagent
ADKLOG_JUDGE="$R/adkargv-judge.txt"
FAKE_ARGV_LOG="$ADKLOG_JUDGE" python3 "$SCRIPTS/loop.py" "noop" --task-id adkjudge \
  --agent-cli adk --claude-bin "$FAKEADK" --adk-agent-dir "$R/loop_spec" \
  --verify 'true' --judge --max-iterations 1 >/dev/null 2>&1
check "adk judge completes" "$?" "0"
check "adk judge uses read-only mount" \
  "$(grep -c -- "run $R/loop_spec_readonly " "$ADKLOG_JUDGE")" "1"

# ADK exposes token counts but no money. Reject a requested hard cap rather
# than accepting a safety promise the backend cannot enforce.
newrepo; mkadkagent
python3 "$SCRIPTS/loop.py" "noop" --task-id adkbudget --agent-cli adk \
  --claude-bin "$FAKEADK" --adk-agent-dir "$R/loop_spec" \
  --max-budget-usd 1 >/dev/null 2>"$R/adkbudget.txt"
check "adk budget exits 2" "$?" "2"
check "adk budget explains unsupported cap" \
  "$(grep -c 'cannot be enforced by the adk backend' "$R/adkbudget.txt")" "1"

# 16f. transport conflict fails fast: --agent-cli adk pointed at a claude binary
newrepo
cp "$FAKE" "$R/claude"; chmod +x "$R/claude"
python3 "$SCRIPTS/loop.py" "noop" --task-id conflict --agent-cli adk --claude-bin "$R/claude" \
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
check "oc: work tick does not auto-approve asks" "$(grep -c -- '--auto' "$OCLOG")" "0"
check "oc: --model passed"         "$(grep -c -- '--model anthropic/claude-sonnet-4-5' "$OCLOG")" "1"
check "oc: claude-only flags dropped" "$(grep -cE -- '--fallback-model|--permission-mode|--output-format|--allowedTools' "$OCLOG")" "0"

# 17c. compiler via opencode backend: dedicated read-only agent, no --auto
newrepo
write_compiler_fixture
OCLOG2="$R/ocargv2.txt"
FAKE_PLAN="$R/goodplan.json" FAKE_ARGV_LOG="$OCLOG2" python3 "$SCRIPTS/compile_spec.py" SPEC.md \
  --agent-cli opencode --claude-bin "$FAKEOC" --out plan/tasks.json >/dev/null 2>&1
check "oc compile exit 0"      "$?" "0"
check "oc plan written"        "$(test -f plan/tasks.json && echo yes)" "yes"
check "oc read-only compile"   "$(grep -c -- '--agent loop-spec-readonly' "$OCLOG2")" "1"
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

# 17h. Claude aliases are not valid OpenCode IDs; omit them and inherit the
# current/default provider+model instead of sending a broken --model value.
newrepo
OCLOG4="$R/ocargv4.txt"
FAKE_ARGV_LOG="$OCLOG4" python3 "$SCRIPTS/loop.py" "noop" --task-id ocalias \
  --agent-cli opencode --claude-bin "$FAKEOC" --model sonnet \
  --max-iterations 1 --verify 'true' >/dev/null 2>&1
check "oc alias model omitted" "$(grep -c -- '--model' "$OCLOG4")" "0"

# 17i. OpenCode falls back to build when --agent is unknown. Preflight the
# dedicated read-only agent so compiler/judge passes fail closed instead.
newrepo
echo "Build a greeter." > SPEC.md
FAKE_READONLY_MISSING=1 python3 "$SCRIPTS/compile_spec.py" SPEC.md \
  --agent-cli opencode --claude-bin "$FAKEOC" --out plan/tasks.json \
  >/dev/null 2>&1
check "oc missing readonly agent fails closed" "$?" "1"
check "oc missing readonly agent writes no plan" "$(test -f plan/tasks.json && echo yes || echo no)" "no"

echo "== 18. permission-mode is validated against the real claude CLI choice set =="
# Current Claude Code accepts `default`; older releases did not.
newrepo
python3 "$SCRIPTS/loop.py" "noop" --task-id permdefault --claude-bin "$FAKE" \
  --permission-mode default --max-iterations 1 >/dev/null 2>"$R/permerr.txt"
check "default mode reaches the runner" "$?" "1"
check "default mode writes a result" \
  "$(test -f .loop/permdefault/result.json && echo yes || echo no)" "yes"

newrepo
python3 "$SCRIPTS/loop.py" "noop" --task-id permtypo --claude-bin "$FAKE" \
  --permission-mode acceptEdit --max-iterations 1 >/dev/null 2>"$R/permerr2.txt"
check "typo mode exit 2"          "$?" "2"
check "typo mode lists valid modes" "$(grep -c 'bypassPermissions' "$R/permerr2.txt")" "1"

# Every mode the CLI documents is accepted.
# The state directory is the RESOLVED task id, which loop.py slugifies to lowercase
# (LoopState.resolved_task_id). Probing the raw camelCase id passed here found the
# directory only on a case-insensitive filesystem, so this check silently passed on
# macOS and failed on Linux for the three camelCase modes.
newrepo
PERMOK=0
for m in default acceptEdits auto bypassPermissions manual dontAsk plan; do
  python3 "$SCRIPTS/loop.py" "noop" --task-id "perm-$m" --claude-bin "$FAKE" \
    --permission-mode "$m" --max-iterations 1 >/dev/null 2>&1
  resolved="$(printf 'perm-%s' "$m" | tr '[:upper:]' '[:lower:]')"
  [[ -f ".loop/$resolved/result.json" ]] && PERMOK=$((PERMOK+1))
done
check "all CLI modes accepted"    "$PERMOK" "7"

# opencode/adk keep their own permission vocabulary — the claude set must not gate them.
newrepo; mkdir -p "$R/loop_spec" "$R/loop_spec_readonly"
python3 "$SCRIPTS/loop.py" "noop" --task-id permadk --agent-cli adk --claude-bin "$FAKEADK" \
  --adk-agent-dir "$R/loop_spec" \
  --permission-mode default --max-iterations 1 >/dev/null 2>&1
check "adk backend not gated by claude modes" "$(test -f .loop/permadk/result.json && echo yes || echo no)" "yes"

echo "== 19. spend is a hard stop: --max-budget-usd =="
# Iteration and wall-clock caps do not bound cost. A cumulative cap does.
newrepo
FAKE_COST=0.75 python3 "$SCRIPTS/loop.py" "spend forever" --task-id budget \
  --claude-bin "$FAKE" --max-budget-usd 2 --max-iterations 99 --no-progress 99 \
  >/dev/null 2>&1
check "budget exit 1"             "$?" "1"
check "halt_reason"               "$(reason .loop/budget/result.json)" "budget_exhausted"
check "stopped at the cap"        "$(python3 -c "import json;r=json.load(open('.loop/budget/result.json'));print(r['total_cost_usd']>=2.0)")" "True"
check "cap echoed in result"      "$(python3 -c "import json;print(json.load(open('.loop/budget/result.json'))['max_budget_usd'])")" "2.0"
check "cap bounds the overshoot"  "$(python3 -c "import json;r=json.load(open('.loop/budget/result.json'));print(r['iterations']==3)")" "True"

# Each tick is additionally capped at the REMAINING budget, so one runaway turn
# cannot blow past the cumulative cap between checks.
newrepo
BUDLOG="$R/budgetargv.txt"
FAKE_COST=0.75 FAKE_ARGV_LOG="$BUDLOG" python3 "$SCRIPTS/loop.py" "spend" \
  --task-id budgetflag --claude-bin "$FAKE" --max-budget-usd 2 --max-iterations 2 \
  --no-progress 99 >/dev/null 2>&1
check "first tick gets full budget"  "$(grep -c -- '--max-budget-usd 2.000000' "$BUDLOG")" "1"
check "second tick gets remainder"   "$(grep -c -- '--max-budget-usd 1.250000' "$BUDLOG")" "1"

# Unbounded by default: no flag, no budget plumbing.
newrepo
NOBUDLOG="$R/nobudgetargv.txt"
FAKE_ARGV_LOG="$NOBUDLOG" python3 "$SCRIPTS/loop.py" "noop" --task-id nobudget \
  --claude-bin "$FAKE" --max-iterations 1 >/dev/null 2>&1
check "no budget flag by default" "$(grep -c -- '--max-budget-usd' "$NOBUDLOG")" "0"
check "null cap in result"        "$(python3 -c "import json;print(json.load(open('.loop/nobudget/result.json'))['max_budget_usd'])")" "None"

echo "== 20. judge spend is billed to the loop total =="
# A judge call is a real priced invocation. Billing it to total_cost_usd is what
# makes the reported total honest and the cumulative cap enforceable.
newrepo
FAKE_COST=0.5 python3 "$SCRIPTS/loop.py" "make work.txt have two lines" --task-id judgecost \
  --claude-bin "$FAKE" --verify 'test "$(wc -l < work.txt)" -ge 2' \
  --judge --max-iterations 99 >/dev/null 2>&1
check "judge DONE completes"      "$?" "0"
check "halt_reason"               "$(reason .loop/judgecost/result.json)" "complete"
# 2 work ticks to reach two lines, then 1 judge call = 3 * 0.5
check "judge cost included"       "$(python3 -c "import json;print(json.load(open('.loop/judgecost/result.json'))['total_cost_usd'])")" "1.5"

# NOT_DONE keeps the loop going, and each judge call is still billed.
newrepo
FAKE_COST=0.5 FAKE_JUDGE=NOT_DONE python3 "$SCRIPTS/loop.py" "spin" --task-id judgeno \
  --claude-bin "$FAKE" --verify 'true' --judge --max-iterations 2 --no-progress 99 \
  >/dev/null 2>&1
check "judge NOT_DONE keeps going" "$(reason .loop/judgeno/result.json)" "max_iterations"
check "every judge call billed"    "$(python3 -c "import json;print(json.load(open('.loop/judgeno/result.json'))['total_cost_usd'])")" "2.0"

# The judge is capped at what the loop has left, not run unbounded.
newrepo
JUDGELOG="$R/judgeargv.txt"
FAKE_COST=0.5 FAKE_ARGV_LOG="$JUDGELOG" python3 "$SCRIPTS/loop.py" "noop" \
  --task-id judgebudget --claude-bin "$FAKE" --verify 'true' --judge \
  --max-budget-usd 3 --max-iterations 1 >/dev/null 2>&1
check "judge tick gets the remainder" "$(grep -c -- '--max-budget-usd 2.500000' "$JUDGELOG")" "1"

# With --judge on, "verified" means verifier AND judge. If the judge is
# unaffordable, completion is unproven — halt on budget, never claim complete.
newrepo
FAKE_COST=1.0 python3 "$SCRIPTS/loop.py" "noop" --task-id judgebroke \
  --claude-bin "$FAKE" --verify 'true' --judge --max-budget-usd 1 --max-iterations 5 \
  >/dev/null 2>&1
check "unaffordable judge exit 1"   "$?" "1"
check "unaffordable judge halts on budget" "$(reason .loop/judgebroke/result.json)" "budget_exhausted"
check "verifier verdict still recorded"    "$(python3 -c "import json;print(json.load(open('.loop/judgebroke/result.json'))['verifier']['passed'])")" "True"

# model_args is the ONE definition of "is this selector explicit?" for every
# backend. `inherit` must produce no flag anywhere -- forwarding it as --model
# hands the CLI a model no catalog contains.
MODEL_ARGS=$(PYTHONPATH="$SCRIPTS" python3 -c "
import sys; sys.path.insert(0, '$SCRIPTS')
from loop import model_args
oc = lambda m: '/' in m
print('|'.join([
  repr(model_args('inherit')),
  repr(model_args('')),
  repr(model_args('sonnet')),
  repr(model_args('inherit', consumable=oc)),
  repr(model_args('sonnet', consumable=oc)),
  repr(model_args('anthropic/claude-sonnet-4-5', consumable=oc)),
]))
")
check "model_args: inherit emits no flag"            "$(cut -d'|' -f1 <<<"$MODEL_ARGS")" "[]"
check "model_args: empty emits no flag"              "$(cut -d'|' -f2 <<<"$MODEL_ARGS")" "[]"
check "model_args: explicit alias is forwarded"      "$(cut -d'|' -f3 <<<"$MODEL_ARGS")" "['--model', 'sonnet']"
check "model_args: inherit ignores backend filter"   "$(cut -d'|' -f4 <<<"$MODEL_ARGS")" "[]"
check "model_args: opencode drops a Claude alias"    "$(cut -d'|' -f5 <<<"$MODEL_ARGS")" "[]"
check "model_args: opencode forwards provider/model" "$(cut -d'|' -f6 <<<"$MODEL_ARGS")" "['--model', 'anthropic/claude-sonnet-4-5']"

echo
echo "================= $PASS passed, $FAIL failed ================="
exit $([[ $FAIL -eq 0 ]] && echo 0 || echo 1)
