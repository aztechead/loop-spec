#!/usr/bin/env python3
# Exercise state publication through the public writer, including competing processes.
import fcntl
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

WRITER = sys.argv.pop(1)


class FeatureWriteTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.directory = Path(self.work.name)
        self.state = self.directory / "feature.json"
        self.state.write_text('{"warnings":[],"slug":"original"}\n')

    def write(self, *args):
        return subprocess.run(["bash", WRITER, *map(str, args)],
                              capture_output=True, text=True)

    def test_rejects_non_object_and_multiple_json_documents(self):
        for value in ('[]', '1', '{} {}', ''):
            with self.subTest(value=value):
                self.state.write_text('{"slug":"original"}\n')
                result = self.write(self.directory, value)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertEqual(json.loads(self.state.read_text())["slug"], "original")

    def test_concurrent_appends_preserve_every_update(self):
        processes = [subprocess.Popen(
            ["bash", WRITER, "append", str(self.directory), "warnings", str(i)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE) for i in range(16)]
        results = [(process, process.communicate(timeout=30)[1]) for process in processes]
        for process, error in results:
            self.assertEqual(process.returncode, 0, error.decode())
        self.assertEqual(sorted(json.loads(self.state.read_text())["warnings"]), list(range(16)))

    def test_writer_waits_for_lock_and_killed_waiter_leaves_state(self):
        with (self.directory / ".feature-write.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            process = subprocess.Popen(
                ["bash", WRITER, "set", str(self.directory), "slug", '"changed"'],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                with self.assertRaises(subprocess.TimeoutExpired):
                    process.communicate(timeout=0.3)
            finally:
                process.kill()
                process.communicate(timeout=5)
            self.assertEqual(json.loads(self.state.read_text())["slug"], "original")
        result = self.write("set", self.directory, "slug", '"after-kill"')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_failed_replacement_keeps_current_state_and_backup(self):
        spec = importlib.util.spec_from_file_location("feature_write", Path(WRITER).with_name("feature_write.py"))
        writer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(writer)
        replace = writer.os.replace

        def fail_publication(source, destination):
            if destination == self.state:
                raise OSError("injected replacement failure")
            return replace(source, destination)

        previous = self.state.read_bytes()
        with mock.patch.object(writer.os, "replace", side_effect=fail_publication):
            with self.assertRaisesRegex(OSError, "injected replacement failure"):
                writer.main(["set", str(self.directory), "slug", '"changed"'])
        self.assertEqual(self.state.read_bytes(), previous)
        self.assertEqual((self.directory / "feature.json.bak").read_bytes(), previous)
        self.assertEqual(list(self.directory.glob(".feature.json.*")), [])


if __name__ == "__main__":
    unittest.main()
