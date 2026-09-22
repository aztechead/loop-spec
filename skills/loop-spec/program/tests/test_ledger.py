"""Unit tests for loop_spec.ledger: reviewed ranges, findings, dispositions."""
import subprocess
import tempfile
import unittest
from pathlib import Path

from loop_spec.errors import LoopSpecError
from loop_spec.ledger import cleared_files, disposition, open_findings, record_findings, record_range
from loop_spec.paths import FeaturePaths
from loop_spec.state import StateStore


# simplicity: _git/_init_repo repeat test_repo.py's, test_baseline.py's, and
# test_execute.py's own copies verbatim; there is no shared test-fixture module
# in this tree yet, and adding one is a cross-file change outside this file's
# own scope.
def _git(cwd, *args):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True)


def _commit(cwd, filename, message):
    Path(cwd, filename).write_text(f"{filename}\n")
    _git(cwd, "add", filename)
    _git(cwd, "commit", "-q", "-m", message)


def _finding(finding_id, disposition_value="open"):
    return {"id": finding_id, "location": "a.py:1", "cause": "x", "severity": "Minor",
            "disposition": disposition_value, "reason": None, "supersedes": None}


class LedgerTests(unittest.TestCase):
    # simplicity: setUp/tearDown are unittest's fixed method names, not a
    # naming choice; house-style.sh's camelCase deviation here is the same
    # pre-existing false positive test_execute.py, test_result.py, and
    # test_postconditions.py already hit.
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.repo = self.tmp / "repo"
        self.repo.mkdir()
        _git(self.repo, "init", "-q", "-b", "main")
        _git(self.repo, "config", "user.name", "Test")
        _git(self.repo, "config", "user.email", "test@example.com")
        _commit(self.repo, "base.txt", "init")
        self.base_sha = subprocess.run(["git", "rev-parse", "HEAD"], cwd=self.repo, capture_output=True, text=True).stdout.strip()
        _commit(self.repo, "changed.txt", "feature")
        self.head_sha = subprocess.run(["git", "rev-parse", "HEAD"], cwd=self.repo, capture_output=True, text=True).stdout.strip()

        self.paths = FeaturePaths(root=self.tmp / "run")
        self.store = StateStore.create(self.paths, {"id": "run-1"}, "add a widget")

    def tearDown(self):
        self._tmp.cleanup()

    def test_record_range_appends_with_an_id(self):
        range_id = record_range(self.store, repo="repo", from_sha=self.base_sha, to_sha=self.head_sha, full=True,
                                 sha=self.head_sha, by_step="step-1")
        ranges = self.store.state["ledger"]["reviewedRanges"]
        self.assertEqual(len(ranges), 1)
        self.assertEqual(ranges[0]["id"], range_id)
        self.assertEqual(ranges[0]["repo"], "repo")
        self.assertEqual(ranges[0]["from"], self.base_sha)
        self.assertEqual(ranges[0]["to"], self.head_sha)
        self.assertTrue(ranges[0]["full"])

    def test_record_findings_adds_sha_and_range_id(self):
        record_findings(self.store, [_finding("F-1")], sha=self.head_sha, range_id="range-1")
        stored = self.store.state["ledger"]["findings"][0]
        self.assertEqual(stored["sha"], self.head_sha)
        self.assertEqual(stored["rangeId"], "range-1")
        self.assertEqual(stored["id"], "F-1")

    def test_open_findings_filters_by_disposition(self):
        record_findings(self.store, [_finding("F-1", "open"), _finding("F-2", "fixed")], sha=self.head_sha, range_id="range-1")
        self.assertEqual([f["id"] for f in open_findings(self.store)], ["F-1"])

    def test_cleared_files_from_real_commits(self):
        record_range(self.store, repo="repo", from_sha=self.base_sha, to_sha=self.head_sha, full=True,
                     sha=self.head_sha, by_step="step-1")
        self.assertEqual(cleared_files(self.store, self.repo), {"changed.txt"})

    def test_disposition_updates_the_finding(self):
        record_findings(self.store, [_finding("F-1")], sha=self.head_sha, range_id="range-1")
        disposition(self.store, "F-1", "rejected", "not applicable")
        stored = self.store.state["ledger"]["findings"][0]
        self.assertEqual(stored["disposition"], "rejected")
        self.assertEqual(stored["reason"], "not applicable")

    def test_disposition_unknown_id_raises(self):
        with self.assertRaises(LoopSpecError):
            disposition(self.store, "F-missing", "fixed", "done")


if __name__ == "__main__":
    unittest.main()
