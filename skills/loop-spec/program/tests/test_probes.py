"""Unit tests for loop_spec.probes: one or two inline-fixture assertions per probe."""
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

from loop_spec.probes import (
    comment_tells,
    diff_probes,
    doc_deps,
    doc_tells,
    duplication_scan,
    failure_tells,
    house_style_compare,
    house_style_probe,
    indirection_scan,
    named_files,
    plan_probes,
    security_signal,
)


def _write(root: Path, name: str, content: str) -> Path:
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    return path


def _git(cwd, *args):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True)


class HouseStyleTests(unittest.TestCase):
    def test_probe_reports_axes_for_a_sample(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write(root, "a.py", "def alpha_one():\n    return 1\n")
            result = house_style_probe(root, ["a.py"])
            self.assertIn("a.py", str(result["sample"]))
            self.assertIn("naming", result["axes"])

    def test_compare_flags_naming_deviation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write(root, "neighbor1.py", "def alpha_one():\n    return 1\n\n\ndef alpha_two():\n    return 2\n")
            _write(root, "neighbor2.py", "def alpha_three():\n    return 3\n")
            _write(root, "target.py", "def camelCase():\n    return 4\n")
            findings = house_style_compare(root, ["target.py"])
            axes = {f["axis"] for f in findings}
            self.assertIn("naming", axes)


class DuplicationScanTests(unittest.TestCase):
    def test_finds_verbatim_clone_between_two_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            body = "    x = 1\n    y = 2\n    z = x + y\n    print(z)\n    extra = 0\n    return z\n"
            _write(root, "a.py", "def one():\n" + body)
            _write(root, "b.py", "def two():\n" + body)
            findings = duplication_scan(root, ["a.py", "b.py"])
            self.assertTrue(any(f["kind"] == "duplicate" for f in findings))


class IndirectionScanTests(unittest.TestCase):
    def test_single_caller_wrapper_reported(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write(root, "target.py", "def _helper(x):\n    return x + 1\n\n\ndef main():\n    return _helper(5)\n")
            result = indirection_scan(root, ["target.py"])
            self.assertEqual(result["layers"], 1)
            self.assertEqual(result["findings"][0]["name"], "_helper")


class SecuritySignalTests(unittest.TestCase):
    def test_strong_term_fires_alone(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write(root, "auth.md", "Use auth middleware.\n")
            findings = security_signal(root, ["auth.md"])
            self.assertEqual(findings[0]["signal"], "auth")
            self.assertEqual(findings[0]["file"], "auth.md")

    def test_single_weak_term_does_not_fire(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write(root, "token.md", "Rotate the installation token before delivery.\n")
            self.assertEqual(security_signal(root, ["token.md"]), [])

    def test_two_distinct_weak_terms_corroborate(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write(root, "both.md", "Rotate the token before the migration runs.\n")
            findings = security_signal(root, ["both.md"])
            self.assertEqual(len(findings), 1)
            self.assertIn("corroborated by", findings[0]["reason"])


class DocDepsTests(unittest.TestCase):
    def test_intersects_imports_with_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write(root, "requirements.txt", "requests==2.31\nunused-dep\n")
            _write(root, "src/a.py", "import requests\nimport os\n")
            result = doc_deps(root, ["src/a.py"])
            self.assertEqual(len(result), 1)
            self.assertEqual(result[0]["package"], "requests")
            self.assertTrue(result[0]["manifest"].endswith("requirements.txt"))
            self.assertTrue(result[0]["importedBy"][0].endswith("src/a.py"))


class CommentTellsTests(unittest.TestCase):
    def test_diff_narration(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write(root, "a.py", "x = 1\n# Added the new counter\ncounter = 0\n")
            findings = comment_tells(root, ["a.py"])
            self.assertEqual(findings[0]["tell"], "diff-narration")

    def test_echoes_code(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write(root, "b.py", "x = 1\n# increment the counter\nincrement_counter()\n")
            findings = comment_tells(root, ["b.py"])
            self.assertEqual(findings[0]["tell"], "echoes-code")


class FailureTellsTests(unittest.TestCase):
    def test_swallowed_and_silent_exit(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write(root, "swallowed.py", "try:\n    risky()\nexcept Exception:\n    pass\n")
            _write(root, "silent.sh", "#!/usr/bin/env bash\nfoo_command\nexit 1\n")
            findings = failure_tells(root, ["swallowed.py", "silent.sh"])
            tells = {(f["file"].endswith("swallowed.py"), f["tell"]) for f in findings}
            self.assertIn((True, "swallowed"), tells)
            self.assertTrue(any(f["tell"] == "silent-exit" for f in findings))


class DocTellsTests(unittest.TestCase):
    def test_dead_link_and_undefined_placeholder(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write(root, "doc.md", (
                "See [guide](./missing.md) for details.\n\n"
                "Run this:\n\n"
                "```bash\necho <user-name>\n```\n"
            ))
            findings = doc_tells(root, ["doc.md"])
            tells = {f["tell"] for f in findings}
            self.assertIn("dead-link", tells)
            self.assertIn("undefined-placeholder", tells)


class PlanProbesTests(unittest.TestCase):
    def test_returns_all_keys(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _write(root, "a.py", "def alpha():\n    return 1\n")
            result = plan_probes(root, ["a.py"])
            self.assertEqual(
                set(result), {"houseStyle", "duplication", "indirection", "securitySignals", "deps"}
            )


class NamedFilesTests(unittest.TestCase):
    def test_full_path_and_unique_basename_named_ambiguous_and_untracked_not(self):
        with tempfile.TemporaryDirectory() as tmp:
            _git(tmp, "init", "-q", "-b", "main")
            for name in ("src/app/cli.py", "src/app/util.py", "lib/util.py", "docs/guide.md"):
                _write(Path(tmp), name, "x = 1\n")
            _git(tmp, "add", ".")
            _git(tmp, "-c", "user.name=T", "-c", "user.email=t@e", "commit", "-q", "-m", "base")
            _write(Path(tmp), "notes.txt", "untracked\n")
            sha = subprocess.run(["git", "-C", tmp, "rev-parse", "HEAD"], check=True, capture_output=True, text=True).stdout.strip()
            texts = ["Fix cli.py and docs/guide.md, not util.py; see notes.txt or xdocs/guide.mdx."]
            self.assertEqual(named_files(Path(tmp), sha, texts), ["docs/guide.md", "src/app/cli.py"])


class DiffProbesTests(unittest.TestCase):
    def test_indirection_delta_over_a_git_range(self):
        with tempfile.TemporaryDirectory() as tmp:
            _git(tmp, "init", "-q", "-b", "main")
            _git(tmp, "config", "user.name", "Test")
            _git(tmp, "config", "user.email", "test@example.com")
            _write(Path(tmp), "a.py", "x = 1\n")
            _git(tmp, "add", "a.py")
            _git(tmp, "commit", "-q", "-m", "base")
            base_sha = subprocess.run(
                ["git", "-C", tmp, "rev-parse", "HEAD"], check=True, capture_output=True, text=True
            ).stdout.strip()

            _write(Path(tmp), "a.py", "def _helper(x):\n    return x + 1\n\n\ndef main():\n    return _helper(1)\n")
            _write(Path(tmp), "auth.md", "Use auth middleware.\n")
            _git(tmp, "add", "a.py", "auth.md")
            _git(tmp, "commit", "-q", "-m", "head")
            head_sha = subprocess.run(
                ["git", "-C", tmp, "rev-parse", "HEAD"], check=True, capture_output=True, text=True
            ).stdout.strip()

            result = diff_probes(Path(tmp), base_sha, head_sha, base_layers=0)
            self.assertEqual(
                set(result),
                {"commentTells", "failureTells", "indirection", "duplication", "houseStyleCompare", "docTells",
                 "securitySignals"},
            )
            self.assertEqual([s["file"] for s in result["securitySignals"]], ["auth.md"])
            self.assertEqual(result["indirection"]["delta"], result["indirection"]["layers"])


if __name__ == "__main__":
    unittest.main()


class ChangeSecuritySignalTests(unittest.TestCase):
    """7.3.0 (EA-runs item 6): review-time security signals read the change, not the
    whole file, so an old term in a changelog does not flag every edit to it."""

    def _repo(self, tmp: str, content: str) -> str:
        _git(tmp, "init", "-q", "-b", "main")
        _git(tmp, "config", "user.name", "Test")
        _git(tmp, "config", "user.email", "test@example.com")
        _write(Path(tmp), "CHANGELOG.md", content)
        _git(tmp, "add", "CHANGELOG.md")
        _git(tmp, "commit", "-q", "-m", "base")
        return subprocess.run(["git", "-C", tmp, "rev-parse", "HEAD"], check=True, capture_output=True, text=True).stdout.strip()

    def _commit(self, tmp: str, content: str) -> str:
        _write(Path(tmp), "CHANGELOG.md", content)
        _git(tmp, "commit", "-q", "-am", "head")
        return subprocess.run(["git", "-C", tmp, "rev-parse", "HEAD"], check=True, capture_output=True, text=True).stdout.strip()

    def test_an_old_term_is_ignored_and_an_added_one_is_flagged_at_its_line(self):
        with tempfile.TemporaryDirectory() as tmp:
            old = "# Changelog\n\n## 1.0\n- rotate credentials nightly\n"
            base = self._repo(tmp, old)
            head = self._commit(tmp, "# Changelog\n\n## 1.1\n- faster startup\n\n## 1.0\n- rotate credentials nightly\n")
            self.assertEqual(diff_probes(Path(tmp), base, head, base_layers=0)["securitySignals"], [])
            head2 = self._commit(tmp, "# Changelog\n\n## 1.1\n- store the api secret in the vault\n\n## 1.0\n- rotate credentials nightly\n")
            signals = diff_probes(Path(tmp), head, head2, base_layers=0)["securitySignals"]
            self.assertEqual(signals, [{"file": "CHANGELOG.md", "signal": "secret", "reason": "term=secret at line 4"}])

    def test_a_removed_permission_line_is_flagged(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = self._repo(tmp, "def handler(user):\n    check(user, permission='admin')\n    return 1\n")
            head = self._commit(tmp, "def handler(user):\n    return 1\n")
            signals = diff_probes(Path(tmp), base, head, base_layers=0)["securitySignals"]
            self.assertEqual(signals[0]["reason"], "term=permission at removed line 2")

    def test_hunk_headers_with_omitted_and_zero_counts(self):
        from loop_spec.probes import _HUNK
        self.assertEqual(_HUNK.match("@@ -4,0 +4 @@").groups(), ("4", "0", "4", None))
        self.assertEqual(_HUNK.match("@@ -2 +1,0 @@").groups(), ("2", None, "1", "0"))


class RepoChecksProbeTests(unittest.TestCase):
    """7.1.0: configured check tools, read from git objects at a commit."""

    def test_reads_manifests_at_the_commit_not_the_working_tree(self):
        import json as _json
        import subprocess as _sp
        import tempfile as _tf
        from loop_spec.probes import repo_checks_probe
        with _tf.TemporaryDirectory() as t:
            repo = Path(t)
            run = lambda *a: _sp.run(["git", *a], cwd=repo, check=True, capture_output=True)  # noqa: E731
            run("init", "-q", "-b", "main")
            run("config", "user.email", "t@example.com")
            run("config", "user.name", "T")
            (repo / "pyproject.toml").write_text("[tool.ruff]\nline-length = 100\n[tool.pytest.ini_options]\n")
            (repo / "package.json").write_text(_json.dumps({"scripts": {"lint": "eslint .", "test": "vitest"}}))
            run("add", ".")
            run("commit", "-qm", "seed")
            sha = _sp.run(["git", "rev-parse", "HEAD"], cwd=repo, capture_output=True, text=True).stdout.strip()
            (repo / "mypy.ini").write_text("[mypy]\n")  # untracked: not at the commit
            facts = repo_checks_probe(repo, sha)
        self.assertEqual([f["tool"] for f in facts], ["ruff", "npm run lint"])
        self.assertTrue(all(f["sha"] == sha for f in facts))
