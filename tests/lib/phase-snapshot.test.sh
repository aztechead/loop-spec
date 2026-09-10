#!/usr/bin/env bash
# The captured body and referenced text cannot change without failing verification.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
python3 - "$root" <<'PY'
import pathlib
import shutil
import sys
import tempfile
sys.path.insert(0, str(pathlib.Path(sys.argv[1]) / "lib"))
from phase_snapshot import render, verify

with tempfile.TemporaryDirectory() as temp:
    plugin = pathlib.Path(temp) / "plugin"
    feature = pathlib.Path(temp) / "feature"
    (plugin / "skills/spec").mkdir(parents=True)
    (plugin / "skills/shared").mkdir()
    body = plugin / "skills/spec/SKILL.md"
    (plugin / "skills/spec/references").mkdir()
    (plugin / "skills/spec/references/questions.md").write_text("Interview questions.\n")
    body.write_text('# SPEC\nRead `skills/shared/decision.md`.\nRun "${LOOP_SPEC_SKILL_DIR}/../../lib/check.sh".\nLegacy "${CLAUDE_SKILL_DIR}/../../lib/check.sh".\nRead `${LOOP_SPEC_SKILL_DIR}/references/questions.md`.\n')
    shared = plugin / "skills/shared/decision.md"
    shared.write_text("Original decision contract.\n")
    (plugin / "skills/shared/codex-harness.md").write_text("Codex contract.\n")
    record = render(plugin, feature, "spec", "spec", "codex", {"prepend": "Project rule.", "append": "Final rule."})
    manifest = verify(record, plugin)
    prompt = pathlib.Path(record["prompt"]).read_text()
    assert "Codex contract." in prompt and "Project rule." in prompt and "Final rule." in prompt
    assert str(plugin / "skills/spec") + "/../../lib/check.sh" in prompt
    assert prompt.count(str(plugin / "skills/spec") + "/../../lib/check.sh") == 2
    assert "${LOOP_SPEC_SKILL_DIR}" not in prompt and "${CLAUDE_SKILL_DIR}" not in prompt
    assert str(pathlib.Path(record["manifest"]).parent / "skills/spec/references/questions.md") in prompt
    captured = pathlib.Path(record["manifest"]).parent / "skills/shared/decision.md"
    assert str(captured) in prompt
    restored = pathlib.Path(temp) / "restored"
    shutil.copytree(feature, restored)
    assert verify(record, plugin, restored) == manifest
    shared.write_text("Changed decision contract.\n")
    assert captured.read_text() == "Original decision contract.\n"
    verify(record)
    try:
        verify(record, plugin)
    except ValueError as exc:
        assert "source hash mismatch" in str(exc)
    else:
        raise AssertionError("changed source accepted")
    captured.chmod(0o644)
    captured.write_text("Changed snapshot.\n")
    try:
        verify(record)
    except ValueError as exc:
        assert "instruction hash mismatch" in str(exc)
    else:
        raise AssertionError("changed snapshot accepted")
print("PASS: rendered customization, captured references, runtime paths, restored snapshot, source drift, snapshot tampering")
PY
