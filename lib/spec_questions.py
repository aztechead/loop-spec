#!/usr/bin/env python3
"""Read the full spec's concrete unresolved questions without a YAML dependency.

The field uses a JSON array (valid YAML) so commas and punctuation in questions
cannot accidentally change the gate. Missing or malformed fields cannot satisfy the gate.
"""
import json
import re


def read_questions(text):
    text = text.replace("\r\n", "\n")
    if not text.startswith("---\n"):
        raise ValueError("SPEC.md needs unresolved_questions frontmatter")
    closing = re.search(r"^---$", text[4:], re.M)
    if closing is None:
        raise ValueError("SPEC.md frontmatter is not closed")
    end = 4 + closing.start()
    fields = re.findall(r"^unresolved_questions:[ \t]*([^\n]*)$", text[4:end], re.M)
    if not fields:
        raise ValueError("SPEC.md needs unresolved_questions frontmatter")
    if len(fields) != 1:
        raise ValueError("SPEC.md repeats unresolved_questions")
    try:
        questions = json.loads(fields[0])
    except ValueError:
        raise ValueError("unresolved_questions must be a JSON array on one line")
    if not isinstance(questions, list) or any(
            not isinstance(q, str) or not q.strip() for q in questions):
        raise ValueError("unresolved_questions must contain non-empty question strings")
    return questions
