#!/usr/bin/env python3
"""Read concrete unresolved questions through the shared OKF YAML parser."""
from okf import split_document


def read_questions(text):
    try:
        metadata, _ = split_document(text)
    except ValueError as exc:
        raise ValueError("SPEC.md needs valid OKF frontmatter: %s" % exc) from exc
    if "unresolved_questions" not in metadata:
        raise ValueError("SPEC.md needs unresolved_questions frontmatter")
    questions = metadata["unresolved_questions"]
    if not isinstance(questions, list) or any(
            not isinstance(q, str) or not q.strip() for q in questions):
        raise ValueError("unresolved_questions must contain non-empty question strings")
    return questions
