#!/usr/bin/env python3
"""Extract and verify the full spec sections frozen at approval.

Only Goal and Boundary belong in the digest: refining implementation details must
not invalidate approval. The approved digest lives in the driver's feature state.
"""
import hashlib
import json
import re


def intent_digest(text):
    sections = {}
    current = None
    fenced = False
    for line in text.splitlines(keepends=True):
        if line.lstrip().startswith("```"):
            fenced = not fenced
        heading = re.match(r"^## (.+?)\s*$", line) if not fenced else None
        if heading:
            name = heading.group(1)
            current = {"Goal": "goal", "Goals": "goal", "Boundary": "boundary",
                       "Boundaries (what NOT to do)": "boundary"}.get(name)
            if current:
                if current in sections:
                    raise ValueError("SPEC.md repeats the frozen " + current + " section")
                sections[current] = []
        if current:
            sections[current].append(line)
    for key in ("goal", "boundary"):
        if key not in sections or not "".join(sections[key][1:]).strip():
            raise ValueError("SPEC.md needs a non-empty " + key + " section before approval")
    content = json.dumps(sections, sort_keys=True, ensure_ascii=False).encode("utf-8")
    return hashlib.sha256(content).hexdigest()


def verify_intent(text, approval):
    if (not isinstance(approval, dict) or not isinstance(approval.get("sha256"), str)
            or not re.fullmatch(r"[a-f0-9]{64}", approval["sha256"])):
        raise ValueError("SPEC.md Goal and Boundary have no recorded approval")
    if intent_digest(text) != approval["sha256"]:
        raise ValueError("SPEC.md Goal or Boundary changed after approval; restore the approved intent and route the intent gap to the human")
