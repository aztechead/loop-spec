#!/usr/bin/env bash
# Tests for lib/stuck_hint.py: repeated driver calls on unchanged state name the next command.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
python3 - "$root" <<'PY'
import json, os, subprocess, sys, tempfile
sys.path.insert(0, os.path.join(sys.argv[1], "lib"))
import stuck_hint

with tempfile.TemporaryDirectory() as temp:
    env = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t", GIT_COMMITTER_EMAIL="t@t")
    git = lambda *a: subprocess.check_output(["git", "-C", temp] + list(a), env=env, text=True)
    git("init", "-q")
    git("commit", "-q", "--allow-empty", "-m", "base")
    fd = os.path.join(temp, "feature")
    os.mkdir(fd)
    with open(os.path.join(temp, ".git", "info", "exclude"), "a") as fh:
        fh.write("feature/\n")
    feat = {"currentPhase": "verify", "driverNext": {"phase": "verify", "at": "t1"},
            "pendingRemediationTasks": [{"id": "task-verify-suite-1"}],
            "gateHistory": [{"phase": "verify", "gate": "acceptance", "result": "fail"}]}
    call = lambda command, f=feat, **kw: stuck_hint.observe(fd, f, [temp], command, "/x/cycle-driver.sh", **kw)

    assert call("next") is None and call("phase-begin") is None
    note = call("next")
    assert note and note.startswith("NOTE [stuck] 3 driver calls"), note
    assert "bash /x/cycle-driver.sh next --feature-dir %s --returned-from verify" % fd in note, note
    print("PASS: alternating next and phase-begin on unchanged state names the remediate return")

    moved = dict(feat, driverNext={"phase": "verify", "at": "t2"}, driverRedo={"phase": "verify", "count": 4})
    assert call("next", moved).startswith("NOTE [stuck] 4"), "timestamps and driverRedo are not progress"
    with open(os.path.join(temp, "VERIFICATION.md"), "w") as fh:
        fh.write("draft\n")
    assert call("next") is None, "an uncommitted artifact edit is progress"
    print("PASS: a worktree edit resets the count; timestamps and driverRedo do not")

    plain = {"currentPhase": "plan", "driverNext": {"phase": "plan"}}
    for command in ("phase-begin", "phase-begin"):
        call(command, plain)
    assert "phase-begin plan already answered" in call("phase-begin", plain)
    for _ in range(2):
        call("next", plain, paused_node="human.after-spec")
    assert "paused at human.after-spec" in call("next", plain, paused_node="human.after-spec")
    for _ in range(2):
        call("next", plain, error="no session id")
    assert "failed the same way" in call("next", plain, error="no session id")
    print("PASS: phase-begin repeats, a paused node, and a repeated refusal each get their own next step")
PY
