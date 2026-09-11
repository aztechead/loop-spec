#!/usr/bin/env bash
# Route evidence produces distinct recovery actions against a real local repository.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
python3 - "$root" <<'PY'
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

os.environ["LOOP_SPEC_CHECKPOINT_PR"] = "0"
os.environ["LOOP_SPEC_HARNESS"] = "codex"
plugin = Path(sys.argv[1])
sys.path.insert(0, str(plugin / "lib"))
module = importlib.util.spec_from_file_location("driver", plugin / "lib/graph/driver.py")
driver = importlib.util.module_from_spec(module)
module.loader.exec_module(driver)
from review_routes import findings, validate
from spec_intent import intent_digest

for route, phase in (("bad-spec", "verify"), ("intent-gap", "verify"),
                     ("patch", "verify"), ("defer", "verify"), ("bad-spec", "oneshot")):
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        env = dict(os.environ, GIT_AUTHOR_NAME="Test", GIT_AUTHOR_EMAIL="test@example.com",
                   GIT_COMMITTER_NAME="Test", GIT_COMMITTER_EMAIL="test@example.com")
        os.environ.update({k: v for k, v in env.items() if k.startswith("GIT_")})
        def git(*args):
            return subprocess.check_output(["git"] + list(args), cwd=temp, env=env, text=True).strip()
        git("init", "-q")
        app = root / "app.py"
        app.write_text("value = 1\n")
        git("add", "app.py")
        git("commit", "-qm", "base")
        base = git("rev-parse", "HEAD")
        feature = root / ".loop-spec/features/demo"
        docs = root / "docs/loop-spec/features/demo"
        feature.mkdir(parents=True)
        docs.mkdir(parents=True)
        spec = docs / "SPEC.md"
        text = "---\nroute: full\nunresolved_questions: []\n---\n# Demo\n## Goals\nReturn values.\n## Boundaries (what NOT to do)\nOnly this command.\n## Constraints\nUse helper A.\n"
        if phase == "oneshot":
            text = "---\nunresolved_questions: []\nfootprint:\n  - app.py\n---\n# Demo\n<!-- intent: frozen -->\n## Intent\nReturn values.\n<!-- /intent -->\n\n## Constraints\nUse helper A.\n"
        spec.write_text(text)
        git("add", "docs")
        git("commit", "-qm", "spec")
        app.write_text("value = 2\n")
        git("add", "app.py")
        git("commit", "-qm", "implementation")
        fix = git("rev-parse", "HEAD")
        state = {"slug":"demo", "feature_title":"Demo", "schemaVersion":7,
                 "branch":git("branch", "--show-current"), "baseBranch":"main", "baseSha":base,
                 "currentPhase":phase, "execStyle":"auto", "autonomous":True, "artifacts":{}, "commands":{},
                 "specApproval":{"sha256":intent_digest(text), "source":"autonomous"} if phase == "verify" else None,
                 "completedPhases":["spec", "discuss", "plan", "execute"], "warnings":[],
                 "iterate":{"used":0,"maxIterations":10}}
        (feature / "feature.json").write_text(json.dumps(state))
        code, entered = driver.graph_step(str(feature), "")
        assert code == 0 and entered["node"] == phase, entered
        details = {"route":route,"cause":"wrong helper"}
        details.update({"bad-spec":{"section":"Constraints","replacement":"Use helper B."},
                        "intent-gap":{"section":"Goal","question":"Which value should be returned?"},
                        "patch":{"surface":"none","fixCommit":fix},
                        "defer":{"reason":"Independent cleanup; current acceptance behavior is satisfied."}}[route])
        report = docs / "VERIFICATION.md"
        report.write_text("# Review\n## Code review\n- app.py:1 — wrong helper | verdict: true — observed in the range test | routing: " + json.dumps(details) + "\n")
        if route == "bad-spec":
            app.write_text("user tracked changes\n")
            try:
                driver.review_recovery(str(feature), phase)
            except driver.Die as exc:
                assert "dirty implementation" in exc.message
            else:
                raise AssertionError("dirty tracked implementation overwritten")
            assert app.read_text() == "user tracked changes\n"
            app.write_text("value = 2\n")
            git("rm", "-q", "app.py")
            git("commit", "-qm", "delete implementation file")
            deleted = git("rev-parse", "HEAD")
            app.write_text("user untracked changes\n")
            try:
                driver.review_recovery(str(feature), phase)
            except driver.Die as exc:
                assert "untracked files overlap" in exc.message
            else:
                raise AssertionError("untracked file overwritten during recovery")
            assert app.read_text() == "user untracked changes\n"
            app.unlink()
            git("revert", "--no-edit", deleted)
        if phase == "oneshot":
            driver.lib("events", "emit", str(feature), "dispatch", "--phase", phase,
                       "--data", json.dumps({"role":"code-reviewer"}))
        # cmd_next captures its ingress token fresh at entry, seeing every artifact this
        # test just wrote directly (report/app.py); review_recovery is called here on its
        # own, so re-begin the same way to hand it a token that matches what is on disk,
        # rather than the one graph_step captured before those direct writes (task-004).
        driver.pub.begin(str(feature))
        result = driver.review_recovery(str(feature), phase)
        if route in ("bad-spec", "intent-gap"):
            assert app.read_text() == "value = 1\n"
            assert git("rev-parse", "HEAD") != fix
            updated = json.loads((feature / "feature.json").read_text())
            assert updated["reviewRouting"]["used"] == 1
            if phase == "verify":
                assert intent_digest(spec.read_text()) == state["specApproval"]["sha256"]
            else:
                assert "## Intent\nReturn values.\n<!-- /intent -->" in spec.read_text()
        if route == "bad-spec":
            assert result == "rewind" and "Use helper B." in spec.read_text()
            assert "Spec change log" in spec.read_text()
            assert not report.exists() and list((feature / "review-attempts").rglob("VERIFICATION.md"))
            assert driver.review_recovery(str(feature), phase) == "rewind"
            assert json.loads((feature / "feature.json").read_text())["reviewRouting"]["used"] == 1
            if phase == "oneshot":
                assert not driver.reviewer_dispatched(str(feature), phase)
                driver.instruction_record(str(feature), phase)
                answer = driver.capture(driver.cmd_next, ["--feature-dir", str(feature), "--returned-from", phase])
                assert answer.startswith("REDO phase=oneshot"), answer
                driver.fset(str(feature), "driverNext", {"phase":phase})
                answer = driver.capture(driver.cmd_next, ["--feature-dir", str(feature), "--returned-from", phase])
                assert "instruction-hash-mismatch" in answer, answer
            else:
                code, step = driver.graph_step(str(feature), phase)
                assert code == 0 and step["node"] == "discuss", step
        elif route == "intent-gap":
            assert result == "intent-gap" and spec.read_text() == text
            terminal = json.loads((feature / "result.json").read_text())
            assert terminal["status"] == "escalated" and "Which value" in terminal["reason"]
        elif route == "defer":
            assert result is None and app.read_text() == "value = 2\n"
            assert "wrong helper" in (root / ".loop-spec/BACKLOG.md").read_text()
        else:
            assert result is None and git("rev-parse", "HEAD") == fix
        # Each iteration is its own temporary repository standing in for a fresh driver
        # process; finish() releases this one's ingress the way a real process's exit
        # path does, so the next iteration's graph_step captures its own rather than
        # reusing this iteration's now-foreign token (task-004).
        driver.pub.finish()
        print("PASS: review route " + route + " from " + phase)

for invalid in ({"route":"bad-spec","cause":"x","section":"Goals","replacement":"different"},
                {"route":"patch","cause":"x","surface":"public","fixCommit":"1234567"},
                {"route":"defer","cause":"x"}):
    try:
        validate(invalid)
    except ValueError:
        pass
    else:
        raise AssertionError("unevidenced route accepted")
print("PASS: frozen intent cannot use bad-spec; surface changes cannot use patch; defer needs evidence")
for verdict in ("| verdict: true", "|verdict:true", "| verdict:  true"):
    report = "  ## Code review\n- app.py:1 — defect " + verdict + " — reproduced by a test"
    try:
        findings(report)
    except ValueError:
        pass
    else:
        raise AssertionError("verdict whitespace bypassed routing")
    routed = findings(report + ' | routing: {"route":"defer","cause":"separate defect","reason":"unrelated behavior"}')
    assert len(routed) == 1 and routed[0]["route"] == "defer"
print("PASS: accepted verdict whitespace cannot bypass review routing")
PY
