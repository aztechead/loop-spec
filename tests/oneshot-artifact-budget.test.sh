#!/usr/bin/env bash
# Measure filled artifacts from the shipped driver, including real test output.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path.cwd()
module = importlib.util.spec_from_file_location('driver', root / 'lib/graph/driver.py')
driver = importlib.util.module_from_spec(module)
module.loader.exec_module(driver)
observations = []
observe_command = driver.observe_command
def counted_observe_command(feature_dir, root, requirement, command, binding=None, contract=None):
    observations.append(command)
    return observe_command(feature_dir, root, requirement, command, binding=binding, contract=contract)
driver.observe_command = counted_observe_command
for task, source, count in [('slugify-bug', 'slugify.py', 1), ('wc-json', 'wc_tool.py', 3)]:
    observations.clear()
    with tempfile.TemporaryDirectory() as directory:
        project = Path(directory) / 'project'
        shutil.copytree(root / 'evals/tasks' / task / 'fixture', project)
        footprint = [source]
        readonly = [str(p.relative_to(project)) for p in (project / 'tests').glob('test_*.py')]
        if task == 'wc-json':
            code = (project / source).read_text().replace('import sys', 'import sys\nimport json')
            code = code.replace('    args = parser.parse_args(argv)', '    parser.add_argument("--json", action="store_true")\n    args = parser.parse_args(argv)')
            code = code.replace('print(f"', 'print(json.dumps(c) if args.json else f"')
            (project / source).write_text(code)
            (project / 'tests/test_json.py').write_text('''import contextlib
import io
import json
import os
import tempfile
import unittest
from wc_tool import main

class JsonTests(unittest.TestCase):
    def test_output_modes(self):
        with tempfile.TemporaryDirectory() as directory:
            paths = [os.path.join(directory, name) for name in ("one", "two")]
            for path in paths:
                with open(path, "w") as stream:
                    stream.write("one two\\n")
            for selected in (paths[:1], paths):
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    main(["--json"] + selected)
                self.assertEqual([json.loads(line) for line in output.getvalue().splitlines()],
                    [dict(path=path, lines=1, words=2, chars=8) for path in selected])
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                main(paths)
            self.assertEqual(output.getvalue(), "".join("       1       2       8 " + path + "\\n" for path in paths))
''')
            footprint.append('tests/test_json.py')
        subprocess.run(['git', 'init', '-q', str(project)], check=True)
        fd = project / '.loop-spec/features' / task
        fd.mkdir(parents=True)
        docs = project / 'docs/loop-spec/features' / task
        docs.mkdir(parents=True)
        (fd / 'feature.json').write_text(json.dumps({'slug': task}))
        spec, verification = docs / 'SPEC.md', docs / 'VERIFICATION.md'
        command = 'python3 -m unittest discover -s tests'
        requirements = ['all existing regression cases pass'] if task == 'slugify-bug' else [
            'JSON output has path, lines, words, and chars', 'multiple files produce one JSON object each',
            'default text output and existing tests remain unchanged']
        feat = {'slug': task, 'feature_title': task, 'commands': {'test': command}}
        spec.write_text(driver.render_skeleton(str(driver.TEMPLATES / 'SPEC-oneshot.md.template'), feat,
                        footprint=footprint, read_only=readonly))
        with contextlib.redirect_stdout(io.StringIO()):
            task_data = json.loads((root / 'evals/tasks' / task / 'task.json').read_text())
            driver.spec_fill(str(spec), {'intent': task_data['prompt']})
            for path in footprint:
                driver.spec_fill(str(spec), {'file': path, 'note': 'Implement and test the requested output behavior.'})
            for i in range(count):
                driver.spec_fill(str(spec), {'command': command, 'expect': requirements[i]})
        verification.write_text(driver.render_skeleton(str(driver.TEMPLATES / 'VERIFICATION-oneshot.md.template'), feat, spec_path=str(spec)))
        integration = 'tests/test_slugify.py' if task == 'slugify-bug' else 'tests/test_json.py'
        text = verification.read_text().replace('implementation: {path}:{line} - {what it proves}',
            'implementation: ' + source + ':1 - module implements the requested output')
        text = text.replace('integration: {path}:{line} - {what it proves}',
            'integration: ' + integration + ':1 - tests exercise the requested behavior')
        verification.write_text(text)
        if task == 'slugify-bug':
            rows = driver.verification_run(str(fd), feat, str(docs), str(verification), str(spec), None, True)
            assert all(row['status'] == 'FAIL' for row in rows), rows
            code = (project / source).read_text().replace('r"[^a-z0-9]"', 'r"[^a-z0-9]+"').replace('return slug', 'return slug.strip("-")')
            (project / source).write_text(code)
        rows = driver.verification_run(str(fd), feat, str(docs), str(verification), str(spec), None, True)
        assert all(row['status'] == 'PASS' for row in rows), rows
        assert len(rows) == count + 1
        assert len(observations) == (2 if task == 'slugify-bug' else 1)
        assert verification.read_text().count('Ran ') == 1
        assert verification.read_text().count('Same command and result as Criterion 1 (exit 0).') == count
        report = fd / 'review.md'
        report.write_text('Verdict: PASS\nNo findings.\n')
        driver.verification_review(str(verification), str(report), 'offline-fixture')
        for name, args in [('artifact-lint', ['spec', str(spec)]), ('oneshot-spec-lint', [str(spec)])]:
            subprocess.run(['bash', str(root / 'lib' / (name + '.sh'))] + args, check=True)
        assert not driver.verification_lint_flags(str(fd), str(project), str(verification), str(spec))
        total = sum(len(p.read_text().splitlines()) for p in docs.iterdir())
        limit = json.loads((root / 'evals/tasks' / task / 'task.json').read_text())['bar']['artifact_lines']
        print('%s: %d artifact lines (limit %d)' % (task, total, limit))
        assert total <= limit, (spec.read_text(), verification.read_text())
PY
