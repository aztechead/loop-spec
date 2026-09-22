"""Unit tests for loop_spec.baseline: parsers, normalization, capture, comparison."""
import subprocess
import tempfile
import unittest
from pathlib import Path

from loop_spec.baseline import (
    BaselineEntry,
    CommandRun,
    _count_tests_ran,
    capture_baseline,
    compare_to_baseline,
    detect_runner,
    evidence_matches,
    fingerprints,
    normalize_output,
    parse_cargo_test,
    parse_go_test,
    parse_pytest,
    parse_vitest_jest,
    run_command,
)


def _git(cwd, *args):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True)


def _init_repo(cwd):
    _git(cwd, "init", "-q", "-b", "main")
    _git(cwd, "config", "user.name", "Test")
    _git(cwd, "config", "user.email", "test@example.com")
    Path(cwd, "README.md").write_text("hi\n")
    _git(cwd, "add", "README.md")
    _git(cwd, "commit", "-q", "-m", "init")


def _run(command: str, cwd: str, sha: str = "deadbeef", **kwargs) -> CommandRun:
    return run_command(command, Path(cwd), sha, **kwargs)


class ParserTests(unittest.TestCase):
    def test_parse_pytest(self):
        text = (
            "============================= FAILURES ==============================\n"
            "_______________________ test_foo[x] __________________________\n"
            "FAILED tests/test_foo.py::test_foo[x] - AssertionError: nope\n"
            "ERROR tests/test_bar.py::test_bar\n"
            "collected 5 items\n"
            "========================= 2 failed, 3 passed ==========================\n"
        )
        self.assertEqual(
            parse_pytest(text),
            ["tests/test_bar.py::test_bar", "tests/test_foo.py::test_foo[x]"],
        )

    def test_parse_vitest_jest(self):
        text = (
            " FAIL  src/foo.test.ts\n"
            "  ✕ adds numbers (5 ms)\n"
            "  ● Suite name › does the thing\n"
            "  × another one\n"
            "  ✓ works fine (2 ms)\n"
            "Tests:       3 failed, 1 passed, 4 total\n"
        )
        self.assertEqual(
            parse_vitest_jest(text),
            ["adds numbers", "another one", "src/foo.test.ts > Suite name > does the thing"],
        )

    def test_parse_go_test(self):
        text = (
            "=== RUN   TestAdd\n"
            "--- FAIL: TestAdd (0.00s)\n"
            "    add_test.go:10: expected 4 got 5\n"
            "FAIL\tpkg/math\t0.003s\n"
            "=== RUN   TestSub\n"
            "--- FAIL: TestSub (0.00s)\n"
        )
        self.assertEqual(parse_go_test(text), ["TestAdd", "pkg/math.TestSub"])

    def test_parse_cargo_test(self):
        text = (
            "running 3 tests\n"
            "test module::tests::add ... FAILED\n"
            "test module::tests::sub ... ok\n"
            "test module::tests::mul ... FAILED\n"
            "\n"
            "failures:\n"
        )
        self.assertEqual(parse_cargo_test(text), ["module::tests::add", "module::tests::mul"])


class DetectRunnerTests(unittest.TestCase):
    def test_matches(self):
        self.assertEqual(detect_runner("pytest -k foo"), "pytest")
        self.assertEqual(detect_runner("python3 -m pytest tests/"), "pytest")
        self.assertEqual(detect_runner("vitest run"), "vitest")
        self.assertEqual(detect_runner("jest --ci"), "jest")
        self.assertEqual(detect_runner("go test ./..."), "go")
        self.assertEqual(detect_runner("cargo test"), "cargo")

    def test_no_match(self):
        self.assertIsNone(detect_runner("make check"))


class NormalizeTests(unittest.TestCase):
    def test_strips_and_preserves(self):
        root = "/repo/checkout"
        text = (
            "\x1b[31mFAILED\x1b[0m /repo/checkout/tests/test_x.py\n"
            "at 0x1A2B3C ok\n"
            "tests/test_x.py:42: assertion\n"
            "done in 245ms and 1.5s\n"
            "pid=98765 port: 8080\n"
            "big number 123456 here\n"
            "3 failed, 1 passed\n"
            "Error 404 not found\n"
        )
        normalized = normalize_output(text, Path(root)).splitlines()
        self.assertEqual(normalized[0], "FAILED <ROOT>/tests/test_x.py")
        self.assertEqual(normalized[1], "at <HEX> ok")
        self.assertEqual(normalized[2], "tests/test_x.py:<LINE>: assertion")
        self.assertEqual(normalized[3], "done in <TIME> and <TIME>")
        self.assertEqual(normalized[4], "pid=<N> port: <N>")
        self.assertEqual(normalized[5], "big number <N> here")
        self.assertEqual(normalized[6], "3 failed, 1 passed")
        self.assertEqual(normalized[7], "Error 404 not found")


class FingerprintTests(unittest.TestCase):
    def test_fallback_to_last_nonempty_line(self):
        result = fingerprints("just some\nnoise here\n", Path("/root"))
        self.assertEqual(len(result), 1)

    def test_no_output_placeholder(self):
        result = fingerprints("", Path("/root"))
        self.assertEqual(len(result), 1)


class RunCommandTests(unittest.TestCase):
    def test_nonzero_exit_recorded(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = _run("python3 -c \"import sys; print('x'); sys.exit(3)\"", tmp)
            self.assertEqual(run.exit_status, 3)
            self.assertIsNone(run.error_class)

    def test_missing_binary(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = _run("definitely-not-a-real-binary-xyz", tmp)
            self.assertEqual(run.exit_status, 127)
            self.assertEqual(run.error_class, "command-not-found")

    def test_tests_ran_counts_pass_markers(self):
        # detect_runner keys off the command's own tokens ("pytest", "python -m
        # pytest", ...), not the output, so a fake-output command like this one is
        # never classified as the pytest runner by run_command itself; this exercises
        # the counting rule directly against a realistic pytest pass line instead.
        self.assertEqual(_count_tests_ran("1 passed in 0.01s\n", "pytest"), 1)

    def test_log_path_writes_raw_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            log_path = Path(tmp, "run.log")
            run = _run("python3 -c \"print('hello')\"", tmp, log_path=log_path)
            self.assertEqual(run.log_path, str(log_path))
            self.assertEqual(log_path.read_text(), "hello\n")

    def test_timeout_decodes_partial_output_instead_of_raising(self):
        # R11: a command that prints, then outlives its timeout, hands
        # TimeoutExpired.stdout back as bytes even though text=True was
        # requested; before the fix this TypeError'd in the string regexes below
        # instead of producing a normal exit-124 record.
        with tempfile.TemporaryDirectory() as tmp:
            command = (
                'python3 -c "import sys, time; print(\'partial\'); sys.stdout.flush(); time.sleep(1)"'
            )
            run = _run(command, tmp, timeout=0.1)
            self.assertEqual(run.exit_status, 124)
            self.assertEqual(run.error_class, "timeout")


class CompareToBaselineTests(unittest.TestCase):
    def _cr(self, exit_status=0, runner=None, failure_identities=None, fingerprints_=None, error_class=None, tests_ran=1):
        return CommandRun(
            command="cmd", cwd="/x", sha="a" * 40, exit_status=exit_status, runner=runner,
            failure_identities=failure_identities or [], fingerprints=fingerprints_ or ["fp1"],
            output_digest="sha256:" + "0" * 64, normalized_digest="sha256:" + "0" * 64,
            normalization_version=1, started_at="2026-01-01T00:00:00+00:00", elapsed_seconds=0.1,
            error_class=error_class, tests_ran=tests_ran, log_path=None,
        )

    def test_no_regression(self):
        base_run = self._cr(exit_status=1, fingerprints_=["fp1"])
        entry = BaselineEntry(command="cmd", task="T-1", status="ran", run=base_run)
        candidate = self._cr(exit_status=1, fingerprints_=["fp1"])
        self.assertEqual(compare_to_baseline(entry, candidate).verdict, "no-regression")

    def test_regression(self):
        base_run = self._cr(exit_status=0, fingerprints_=["fp1"])
        entry = BaselineEntry(command="cmd", task="T-1", status="ran", run=base_run)
        candidate = self._cr(exit_status=1, fingerprints_=["fp1", "fp2"])
        result = compare_to_baseline(entry, candidate)
        self.assertEqual(result.verdict, "regression")
        self.assertEqual(result.new_identities, ["fp2"])

    def test_collection_failure_with_no_parsed_ids_is_a_regression(self):
        # R4: a passing pytest baseline (no failed IDs) versus a candidate that
        # never got past collection (exit 2, no parsed test IDs, a different
        # import-error fingerprint) is not "empty set minus empty set" no-
        # regression -- nothing about the baseline excuses a runner that never
        # collected any tests.
        base_run = self._cr(exit_status=0, runner="pytest", failure_identities=[], fingerprints_=["fp-base"])
        entry = BaselineEntry(command="pytest", task="T-1", status="ran", run=base_run)
        candidate = self._cr(exit_status=2, runner="pytest", failure_identities=[], fingerprints_=["fp-import-error"])
        result = compare_to_baseline(entry, candidate)
        self.assertEqual(result.verdict, "regression")

    def test_same_collection_failure_as_baseline_is_no_regression(self):
        # The baseline was ALREADY in this exact broken state -- same error
        # class, same fingerprints -- so nothing new failed.
        base_run = self._cr(exit_status=2, runner="pytest", failure_identities=[], fingerprints_=["fp-import-error"])
        entry = BaselineEntry(command="pytest", task="T-1", status="ran", run=base_run)
        candidate = self._cr(exit_status=2, runner="pytest", failure_identities=[], fingerprints_=["fp-import-error"])
        result = compare_to_baseline(entry, candidate)
        self.assertEqual(result.verdict, "no-regression")

    def test_candidate_timeout_with_a_matching_id_is_still_a_regression(self):
        # R4 round 2: the candidate never finished (timeout), even though the
        # one failure id its partial output DID parse happens to equal the
        # baseline's -- set subtraction alone would read that as no-regression,
        # but a run that timed out may have found more had it actually finished.
        base_run = self._cr(exit_status=1, runner="pytest", failure_identities=["test_a.py::test_known"])
        entry = BaselineEntry(command="pytest", task="T-1", status="ran", run=base_run)
        candidate = self._cr(exit_status=124, runner="pytest", failure_identities=["test_a.py::test_known"], error_class="timeout")
        result = compare_to_baseline(entry, candidate)
        self.assertEqual(result.verdict, "regression")
        self.assertIn("timeout", result.detail)

    def test_baseline_and_candidate_both_timeout_identically_is_no_regression(self):
        # Both stuck in the exact same broken state (same error class, same
        # fingerprints) -- nothing NEW failed, so it is not held against the
        # candidate the way an unmatched timeout is.
        base_run = self._cr(exit_status=124, fingerprints_=["fp-timeout"], error_class="timeout")
        entry = BaselineEntry(command="cmd", task="T-1", status="ran", run=base_run)
        candidate = self._cr(exit_status=124, fingerprints_=["fp-timeout"], error_class="timeout")
        result = compare_to_baseline(entry, candidate)
        self.assertEqual(result.verdict, "no-regression")

    def test_complete_candidate_with_the_same_known_failure_is_no_regression(self):
        # Guards the accepted case this whole classification sits in front of:
        # a candidate that actually FINISHED, with the same pre-existing
        # failure plus more passing tests, is still no-regression.
        base_run = self._cr(exit_status=1, runner="pytest", failure_identities=["test_a.py::test_known"])
        entry = BaselineEntry(command="pytest", task="T-1", status="ran", run=base_run)
        candidate = self._cr(exit_status=1, runner="pytest", failure_identities=["test_a.py::test_known"])
        result = compare_to_baseline(entry, candidate)
        self.assertEqual(result.verdict, "no-regression")

    def test_feature_added_ok(self):
        entry = BaselineEntry(command="cmd", task="T-1", status="no-baseline", run=None)
        candidate = self._cr(exit_status=0, runner="pytest", failure_identities=[])
        self.assertEqual(compare_to_baseline(entry, candidate, feature_added=True).verdict, "featureAdded-ok")

    def test_feature_added_failed(self):
        entry = BaselineEntry(command="cmd", task="T-1", status="no-baseline", run=None)
        candidate = self._cr(exit_status=1, runner="pytest", failure_identities=["t::x"])
        self.assertEqual(compare_to_baseline(entry, candidate, feature_added=True).verdict, "featureAdded-failed")

    def test_feature_added_failed_when_no_test_ran(self):
        entry = BaselineEntry(command="cmd", task="T-1", status="no-baseline", run=None)
        candidate = self._cr(exit_status=0, runner="pytest", failure_identities=[], tests_ran=0)
        result = compare_to_baseline(entry, candidate, feature_added=True)
        self.assertEqual(result.verdict, "featureAdded-failed")
        self.assertEqual(result.detail, "no test ran")

    def test_must_flip_ok(self):
        base_run = self._cr(exit_status=1)
        entry = BaselineEntry(command="cmd", task="T-1", status="ran", run=base_run)
        candidate = self._cr(exit_status=0)
        self.assertEqual(compare_to_baseline(entry, candidate, must_flip=True).verdict, "mustFlip-ok")

    def test_must_flip_failed_base_did_not_fail(self):
        base_run = self._cr(exit_status=0)
        entry = BaselineEntry(command="cmd", task="T-1", status="ran", run=base_run)
        candidate = self._cr(exit_status=0)
        self.assertEqual(compare_to_baseline(entry, candidate, must_flip=True).verdict, "mustFlip-failed")

    def test_baseline_error(self):
        base_run = self._cr(exit_status=1, error_class="timeout")
        entry = BaselineEntry(command="cmd", task="T-1", status="ran", run=base_run)
        candidate = self._cr(exit_status=0)
        self.assertEqual(compare_to_baseline(entry, candidate).verdict, "baseline-error")


class EvidenceMatchesTests(unittest.TestCase):
    def test_matches_ignoring_output_digest(self):
        rerun = CommandRun(
            command="pytest  -k   foo", cwd="/x", sha="deadbeef", exit_status=0, runner="pytest",
            failure_identities=[], fingerprints=["fp"], output_digest="sha256:" + "1" * 64,
            normalized_digest="sha256:" + "2" * 64, normalization_version=1,
            started_at="2026-01-01T00:00:00+00:00", elapsed_seconds=0.1, error_class=None,
            tests_ran=1, log_path=None,
        )
        claimed = {
            "command": "pytest -k foo", "sha": "deadbeef", "exitStatus": 0,
            "failureIdentities": [], "outputDigest": "sha256:" + "9" * 64,
        }
        ok, reason = evidence_matches(claimed, rerun)
        self.assertTrue(ok)
        self.assertEqual(reason, "")

    def test_mismatch_reports_reason(self):
        rerun = CommandRun(
            command="pytest", cwd="/x", sha="deadbeef", exit_status=1, runner="pytest",
            failure_identities=[], fingerprints=["fp"], output_digest="sha256:" + "1" * 64,
            normalized_digest="sha256:" + "2" * 64, normalization_version=1,
            started_at="2026-01-01T00:00:00+00:00", elapsed_seconds=0.1, error_class=None,
            tests_ran=1, log_path=None,
        )
        claimed = {"command": "pytest", "sha": "deadbeef", "exitStatus": 0, "failureIdentities": []}
        ok, reason = evidence_matches(claimed, rerun)
        self.assertFalse(ok)
        self.assertEqual(reason, "exitStatus differs")


class CaptureBaselineTests(unittest.TestCase):
    def test_capture_and_cleanup(self):
        with tempfile.TemporaryDirectory() as repo_dir, tempfile.TemporaryDirectory() as checkouts_dir:
            _init_repo(repo_dir)
            sha = subprocess.run(
                ["git", "-C", repo_dir, "rev-parse", "HEAD"], check=True, capture_output=True, text=True
            ).stdout.strip()

            commands = [
                ("true", "T-1", None),
                ("python3 -c \"import sys; sys.exit(1)\"", "T-2", None),
                ("echo unused", "T-3", "feature_output.txt"),
            ]
            baseline = capture_baseline(
                Path(repo_dir), sha, commands, "touch prepared.marker", Path(checkouts_dir), "myrepo"
            )

            self.assertEqual(baseline.entries["true"].status, "ran")
            self.assertEqual(baseline.entries["true"].run.exit_status, 0)
            self.assertEqual(baseline.entries["python3 -c \"import sys; sys.exit(1)\""].run.exit_status, 1)
            self.assertEqual(baseline.entries["echo unused"].status, "no-baseline")
            self.assertIsNone(baseline.entries["echo unused"].run)
            self.assertEqual(baseline.prepare_run.exit_status, 0)

            checkout_dest = Path(checkouts_dir) / f"baseline-{sha[:12]}"
            self.assertFalse(checkout_dest.exists())


if __name__ == "__main__":
    unittest.main()
