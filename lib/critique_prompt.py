#!/usr/bin/env python3
"""Render a critique dispatch packet from the immutable phase contract."""
from __future__ import annotations

import argparse
import json
import re
import shlex
from pathlib import Path
from typing import Optional


def render(template: Path, kind: str, slug: str, phase: str, artifact: Path,
           spec: Path, evidence: Path, diff: Optional[Path], fix_list: str,
           transport: str) -> str:
    source = template.read_text(encoding="utf-8")
    source = source.replace("docs/loop-spec/features/{slug}/{artifact}", "{artifact_path}")
    source = source.replace("docs/loop-spec/features/{slug}/SPEC.md", "{spec_path}")
    source = source.replace("docs/loop-spec/features/{slug}/EVIDENCE.md", "{evidence_path}")
    required = ("Role", "Findings pass", "Delta re-verify pass", "Rules")
    headings = [(name, re.search(r"^## " + re.escape(name) + r"(?:\s|$)", source, re.MULTILINE))
                for name in required]
    if any(match is None for _, match in headings) or any(headings[i][1].start() >= headings[i + 1][1].start()
                                                         for i in range(len(headings) - 1)):
        raise ValueError(f"critic contract is missing a required section: {template}")
    delta_at, rules_at = headings[2][1].start(), headings[3][1].start()
    if kind == "delta":
        source = source[delta_at:rules_at] + source[rules_at:]
    else:
        source = source[:delta_at] + source[rules_at:]
    replacements = {"{slug}": slug, "{N}": "1", "{phase}": phase,
                    "{artifact}": artifact.name, "{artifact_path}": str(artifact),
                    "{spec_path}": str(spec), "{evidence_path}": str(evidence)}
    for old, new in replacements.items():
        source = source.replace(old, new)
    source = source.replace("the feature's SPEC.md", f"`{spec}`")
    source = source.replace("from EVIDENCE.md", f"from `{evidence}`")
    source = source.replace(
        f"grep -E '^- EVID-(001|007) ' {evidence}",
        f"grep -E '^- EVID-(001|007) ' {shlex.quote(str(evidence))}")
    source = source.replace('SendMessage({to: "team-lead", message:',
                            "Report to the phase lead using the caller's active harness transport:")
    source = source.replace('"})', '"')
    metadata = ["", "## Dispatch metadata", "", f"Dispatch transport: {transport}."]
    if kind == "delta":
        if diff is None:
            raise ValueError("delta packet requires a revision diff")
        metadata.extend([
            f"Read the revision diff at `{diff}` and verify only the changed sections.",
            "Do not reread unchanged sections or rely on prior author explanations.",
            "", "### Fix-list", "", fix_list.rstrip(),
        ])
    else:
        metadata.extend([
            f"Read the artifact at `{artifact}`. This path is authoritative for this attempt.",
            f"Authoritative SPEC path: `{spec}`. Authoritative EVIDENCE path: `{evidence}`.",
            "This is the first findings pass; keep it independent of author explanations.",
        ])
    return source.rstrip() + "\n" + "\n".join(metadata) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--template", type=Path)
    parser.add_argument("--kind", choices=("findings", "delta"))
    parser.add_argument("--slug")
    parser.add_argument("--phase")
    parser.add_argument("--artifact", type=Path)
    parser.add_argument("--spec", type=Path)
    parser.add_argument("--evidence", type=Path)
    parser.add_argument("--diff", type=Path)
    parser.add_argument("--fix-list", default="")
    parser.add_argument("--transport", default="caller's active harness transport")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--verify-manifest", type=Path)
    parser.add_argument("--record-json")
    parser.add_argument("--feature-dir", type=Path)
    args = parser.parse_args()
    try:
        if args.verify_manifest:
            if not args.feature_dir:
                raise ValueError("--feature-dir is required with --verify-manifest")
            if not args.record_json:
                raise ValueError("--record-json is required with --verify-manifest")
            from phase_snapshot import verify
            verify(json.loads(args.record_json), None, str(args.feature_dir))
            return
        required = (args.template, args.kind, args.slug, args.phase, args.artifact,
                    args.spec, args.evidence, args.output)
        if any(value is None for value in required):
            raise ValueError("render mode requires template, kind, slug, phase, artifact, spec, evidence, and output")
        packet = render(args.template, args.kind, args.slug, args.phase,
                        args.artifact, args.spec, args.evidence, args.diff,
                        args.fix_list, args.transport)
        args.output.write_text(packet, encoding="utf-8")
    except (OSError, ValueError) as exc:
        raise SystemExit(f"critique prompt: could not render {args.output}: {exc}") from exc


if __name__ == "__main__":
    main()
