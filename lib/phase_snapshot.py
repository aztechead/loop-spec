#!/usr/bin/env python3
"""Render a phase's instructions once and verify the text and source hashes later.

Snapshots include referenced instruction files so a mid-session plugin update cannot
silently change a shared contract. Executable helpers still resolve to the plugin.
"""
import hashlib
import json
from pathlib import Path
import re
import tempfile


def digest(content):
    return hashlib.sha256(content).hexdigest()


def render(plugin, feature_dir, phase, skill, harness, customization):
    plugin = Path(plugin).resolve()
    parent = Path(feature_dir) / "instruction-snapshots"
    parent.mkdir(parents=True, exist_ok=True)
    destination = Path(tempfile.mkdtemp(prefix=phase + "-", dir=str(parent)))
    sources, outputs = {}, {}
    paths = sorted(set(plugin.glob("skills/**/*.md")) | set(plugin.glob("skills/**/*.template"))
                   | set(plugin.glob("agents/*.md")))
    if harness not in ("claude", "codex", "opencode", "adk"):
        raise ValueError("cannot render phase instructions for harness " + harness)
    entry = "skills/%s/SKILL.md" % skill
    if not (plugin / entry).is_file():
        raise ValueError("phase instruction body is missing: " + entry)
    for source in paths:
        relative = source.relative_to(plugin).as_posix()
        raw = source.read_bytes()
        sources[relative] = digest(raw)
        text = raw.decode("utf-8")
        # Runtime scripts remain executable from the plugin, while Markdown references
        # point to this attempt's captured text, including the full SPEC fallback.
        for variable in ("LOOP_SPEC_SKILL_DIR", "CLAUDE_SKILL_DIR"):
            text = text.replace("${" + variable + "}/references/", str(destination / source.parent.relative_to(plugin) / "references") + "/")
            text = text.replace("${" + variable + "}", str(source.parent))
        text = re.sub(r"(?<![\w/])((?:skills|agents)/[\w./-]+\.md(?:\.template)?)",
                      lambda m: str(destination / m.group(1)), text)
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
        outputs[relative] = digest(target.read_bytes())
        target.chmod(0o444)
    harness_file = destination / ("skills/shared/%s-harness.md" % harness)
    prompt = (harness_file.read_text(encoding="utf-8") + "\n\n"
              + customization.get("prepend", "") + "\n\n"
              + (destination / entry).read_text(encoding="utf-8") + "\n\n"
              + customization.get("append", ""))
    prompt_bytes = prompt.encode("utf-8")
    prompt_hash = digest(prompt_bytes)
    prompt_name = prompt_hash + ".md"
    (destination / prompt_name).write_bytes(prompt_bytes)
    (destination / prompt_name).chmod(0o444)
    outputs[prompt_name] = prompt_hash
    manifest = {"phase": phase, "skill": skill, "harness": harness,
                "customization": customization, "sources": sources, "outputs": outputs,
                "prompt": prompt_name}
    content = (json.dumps(manifest, sort_keys=True, indent=2) + "\n").encode("utf-8")
    manifest_path = destination / "manifest.json"
    manifest_path.write_bytes(content)
    manifest_path.chmod(0o444)
    return {"manifest": str(manifest_path), "sha256": digest(content),
            "prompt": str(destination / prompt_name), "promptSha256": prompt_hash}


def verify(record, plugin=None, feature_dir=None):
    manifest_path = Path(record["manifest"])
    if feature_dir is not None:
        manifest_path = Path(feature_dir) / "instruction-snapshots" / manifest_path.parent.name / "manifest.json"
    content = manifest_path.read_bytes()
    if digest(content) != record["sha256"]:
        raise ValueError("phase instruction manifest hash mismatch: " + str(manifest_path))
    manifest = json.loads(content)
    for relative, expected in manifest["outputs"].items():
        path = manifest_path.parent / relative
        if path.resolve().parent != manifest_path.parent.resolve() and manifest_path.parent.resolve() not in path.resolve().parents:
            raise ValueError("phase instruction path escapes snapshot: " + relative)
        if digest(path.read_bytes()) != expected:
            raise ValueError("phase instruction hash mismatch: " + str(path))
    prompt = manifest_path.parent / manifest["prompt"]
    if (Path(record["prompt"]) != Path(record["manifest"]).parent / manifest["prompt"]
            or digest(prompt.read_bytes()) != record["promptSha256"]):
        raise ValueError("phase instruction prompt does not match its record")
    if plugin is not None:
        for relative, expected in manifest["sources"].items():
            if digest((Path(plugin) / relative).read_bytes()) != expected:
                raise ValueError("phase instruction source hash mismatch: " + relative)
    return manifest
