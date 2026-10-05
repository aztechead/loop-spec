"""What hosts built for 7.x read outside the repository: the schema-1 result, field for
field, and the state-home copies of events.jsonl and result.json, keyed by 7.x's repo id."""
import hashlib
import json
import os
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import test_loop
from loop_spec import legacy
from test_flow import commit, marker, sh

# The top-level fields of 7.x's result record (loop_spec/result.py on the 7.x branch).
FIELDS_8X = ["assumptions", "decisions", "criteria", "criteriaSha", "caveats"]  # 8.x adds these to 7.x's record
FIELDS_7X = [
    "schema", "loopSpecVersion", "cycleType", "slug", "status", "outcome", "reason", "summary", "noChangeReason",
    "phaseReached", "branch", "baseBranch", "prUrl", "checkpointPrUrl", "delivery", "converged", "workDelivered",
    "iterations", "warnings", "autonomous", "feature_title", "createdAt", "finishedAt", "verification",
    "implementationConverged", "eligibleTargets", "retryable", "retryPhase", "verifiedSha", "result", "rewinds",
    "prs", "after", "reviewed", "unreviewed", "outstanding", "blocked", "partiallyDelivered", "weakenedAssurance",
    "cleanupBacklog", "implementations", "policyAnsweredQuestions", "hostVersions",
]


class LegacyTests(unittest.TestCase):
    base = test_loop.LoopTests
    checks, ready_run, deliver, review = base.checks, base.ready_run, base.deliver, base.review

    def setUp(self):
        self.base.setUp(self)
        self.home = Path(tempfile.mkdtemp(prefix="loop-spec-home-"))
        self.addCleanup(shutil.rmtree, self.home)
        self._home = mock.patch.dict(os.environ, {"LOOP_SPEC_HOME": str(self.home)})
        self._home.start()

    def tearDown(self):
        self._home.stop()
        self.base.tearDown(self)

    def legacy_dir(self, slug: str) -> Path:
        root = sh(self.repo.path, "git", "rev-list", "--max-parents=0", "HEAD")
        return self.home / hashlib.sha256(root.encode()).hexdigest()[:16] / slug

    def test_a_delivered_run_ends_with_7x_result_written_where_7x_wrote_it(self):
        run = self.ready_run()
        self.deliver(run)
        self.checks("pass")
        code, out, _ = self.repo.ls("feedback")
        self.assertEqual(code, 0)
        result = marker(out, "LOOP_SPEC_RESULT")
        self.assertEqual(sorted(set(result) - set(FIELDS_8X)), sorted(FIELDS_7X))
        self.assertEqual((result["schema"], result["cycleType"], result["status"], result["outcome"], result["result"]),
                         (1, "full", "completed", "delivered", "converged"))
        self.assertEqual(result["verification"], {"status": "passed", "command": None})
        self.assertEqual(result["prs"], [{"repo": "repo", "number": 7, "url": "https://github.com/acme/kv/pull/7"}])
        self.assertEqual(result["delivery"]["targets"][0]["deliveredSha"], result["verifiedSha"])
        self.assertTrue(result["converged"] and result["workDelivered"] and result["createdAt"])

        legacy = self.legacy_dir(run["slug"])
        nxt = marker(out, "LOOP_SPEC_NEXT")
        self.assertEqual((nxt["kind"], nxt["path"], nxt["slug"], nxt["stateHome"]),
                         ("result", str(legacy / "result.json"), run["slug"], str(self.home)))
        for path in (legacy / "result.json", legacy.parent / "last-result.json", Path(run["runDir"], "result.json")):
            self.assertEqual(json.loads(path.read_text()), result)
        events = Path(run["runDir"], "events.jsonl").read_text()
        self.assertEqual((legacy / "events.jsonl").read_text(), events)
        self.assertEqual(json.loads(events.splitlines()[-1])["event"], "result")

    def test_an_unverified_delivery_is_a_draft_with_weakened_assurance(self):
        run = self.ready_run()
        commit(Path(run["work"]), "late.py", "x = 3\n")  # after verify: the head is unverified
        self.assertEqual(self.repo.ls("deliver", "--unverified", "--no-feedback")[0], 0)
        result = json.loads(Path(run["runDir"], "result.json").read_text())
        self.assertEqual((result["result"], result["outcome"], result["verifiedSha"]),
                         ("converged-with-caveats", "delivered-draft", None))
        self.assertEqual(result["weakenedAssurance"], ["delivered without a passing verify"])

    def test_rewinds_are_counted_and_an_escalation_says_why(self):
        run = self.ready_run()
        self.repo.ls("verify")
        commit(Path(run["work"]), "fix.py", "x = 2\n")
        self.repo.ls("status")  # iterate -> verify: one rewind
        code, out, _ = self.repo.ls("finish", "--status", "escalated", "--summary", "needs a schema decision")
        result = marker(out, "LOOP_SPEC_RESULT")
        self.assertEqual((result["rewinds"], result["iterations"]), (1, {"used": 1, "max": None}))
        self.assertEqual((result["status"], result["reason"], result["phaseReached"]),
                         ("escalated", "needs a schema decision", "verify"))

    def test_a_shallow_clone_pins_its_repo_id(self):
        clone = self.repo.path.parent / "shallow"
        sh(self.repo.path, "git", "commit", "-q", "--allow-empty", "-m", "second")
        sh(self.repo.path.parent, "git", "clone", "-q", "--depth", "1", f"file://{self.repo.path}", str(clone))
        rid = legacy.repo_id(clone)
        self.assertEqual(sh(clone, "git", "config", "--local", "--get", "loop-spec.repoId"), rid)


if __name__ == "__main__":
    unittest.main()
