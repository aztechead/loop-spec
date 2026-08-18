#!/usr/bin/env python3
"""Decide the three failure-path defects a person only meets when the code breaks.

lib/failure-tells.sh owns argument and path setup; this module owns the rules. Each
one asks the same question from the operator's chair: when this line runs at 03:00,
does the person on the other end learn what happened, or does the software go quiet?
The rules stay silent whenever the answer needs a judgment rather than a match.
"""

from __future__ import print_function

import os
import re
import sys

# Comment syntax per extension, so a commented-out `exit 1` is not read as code.
LANGUAGE = {
    ".py": "python", ".sh": "shell", ".bash": "shell",
    ".js": "js", ".jsx": "js", ".mjs": "js", ".cjs": "js",
    ".ts": "js", ".tsx": "js",
}
COMMENT = {"python": "#", "shell": "#", "js": "//"}
# A heredoc in a shell script is data -- a python program, a prompt, a test fixture --
# and reading it as shell reports findings against code that is not this file's.
HEREDOC_OPEN = re.compile(r"<<-?\s*[\"']?([A-Za-z_][A-Za-z0-9_]*)[\"']?")

EXCEPT_INLINE = re.compile(r"^(\s*)except\b(?P<clause>[^:]*):\s*(pass|\.\.\.|continue)\s*$")
EXCEPT_OPEN = re.compile(r"^(\s*)except\b(?P<clause>[^:]*):\s*$")
# A named exception type IS the explanation: `except ProcessLookupError: pass` says the
# process was already gone. Only the catch-alls swallow without saying anything.
BROAD = re.compile(r"^\s*(?:\(?\s*(?:Exception|BaseException)\s*\)?)?(?:\s+as\s+\w+)?\s*$")
EMPTY_BODY = re.compile(r"^\s*(pass|\.\.\.|continue)\s*$")
CATCH_INLINE = re.compile(r"\bcatch\s*(?:\([^)]*\))?\s*\{\s*\}")
CATCH_OPEN = re.compile(r"\bcatch\s*(?:\([^)]*\))?\s*\{\s*$")

SHELL_EXIT = re.compile(r"(?:^|;|\|\||&&|\{)\s*exit\s+([1-9][0-9]*)\b")
PY_EXIT = re.compile(r"\bsys\.exit\(\s*([1-9][0-9]*)\s*\)")
JS_EXIT = re.compile(r"\bprocess\.exit\(\s*([1-9][0-9]*)\s*\)")
# Anything that puts words in front of a person: a stream write, a logger, or a
# helper whose whole job is to say why (`die`, `usage`, `fail`).
# Substrings on purpose, not word boundaries: `grounding_contract_error "..."` speaks, and
# a probe that misses the helper because of an underscore reports a silence that is not
# there. Over-matching here costs a missed finding; under-matching costs a false alarm.
SPEAKS = re.compile(
    r"echo|printf|\bcat\b|>&2|print\(|log|console\.|die|usage|(?<!pipe)fail|error|warn|"
    r"raise|throw|message|msg|\bjq\b",
    re.I,
)
# An exit driven by a command's own failure (`add_root "$x" || exit 2`) is reported by
# that command. The silent case is the exit that stands alone.
GUARDED_EXIT = re.compile(r"(?:\|\||&&).*(?:exit|sys\.exit|process\.exit)\b")

PY_RAISE = re.compile(r"\braise\s+\w*(?:Error|Exception)\s*\(\s*(?P<prefix>[a-z]*)(?P<quote>[\"'])(?P<body>[^\"']*)(?P=quote)\s*\)")
JS_THROW = re.compile(r"\bthrow\s+new\s+\w*Error\s*\(\s*(?P<quote>[\"'`])(?P<body>[^\"'`]*)(?P=quote)\s*\)")
SH_SAY = re.compile(r"\becho\s+(?P<quote>[\"'])(?P<body>[^\"']*)(?P=quote)\s*>&2")

# A message built only from these words tells the reader nothing they did not
# already know from the crash itself. Anything outside this set -- a file name, a
# field, a limit, a next step -- makes the message specific, so the check passes.
GENERIC = frozenset(
    """
    a an and argument arguments bad broke broken data err error errors exception
    failed failing failure fault incorrect input internal invalid issue occurred
    oops param params parameter parameters problem request something sorry the
    this to unexpected unknown unsupported value values went wrong
    """.split()
)
INTERPOLATION = re.compile(r"[{}$%]|\\\(")
WORD = re.compile(r"[A-Za-z]+")
MAX_GENERIC_WORDS = 6


def code_lines(lines, language):
    """(index, text) for every line this file actually runs: no whole-line comments (a
    commented-out `exit 1` is not a failure path) and, in shell, no heredoc bodies."""
    marker = COMMENT[language]
    terminator = None
    for index, text in enumerate(lines):
        if terminator is not None:
            if text.strip() == terminator:
                terminator = None
            continue
        if language == "shell" and "<<<" not in text:
            opener = HEREDOC_OPEN.search(text)
            if opener:
                terminator = opener.group(1)
        if not text.strip().startswith(marker):
            yield index, text


def swallowed(lines, language):
    """A caught error whose handler does nothing. The program continues as if the
    call succeeded, and the only record of what actually happened is gone."""
    if language == "python":
        for index, text in code_lines(lines, language):
            match = EXCEPT_INLINE.match(text)
            if match:
                if BROAD.match(match.group("clause")):
                    yield index + 1, "swallowed", text.strip()
                continue
            match = EXCEPT_OPEN.match(text)
            if (match and BROAD.match(match.group("clause"))
                    and _only_statement_is_empty(lines, index, len(match.group(1)))):
                yield index + 1, "swallowed", text.strip()
    elif language == "js":
        for index, text in code_lines(lines, language):
            if CATCH_INLINE.search(text):
                yield index + 1, "swallowed", text.strip()
            elif CATCH_OPEN.search(text) and _next_code_line_closes(lines, index):
                yield index + 1, "swallowed", text.strip()


def _only_statement_is_empty(lines, start, indent):
    """True when the block opened at `start` holds exactly one line and that line
    is `pass`, `...`, or `continue`."""
    body = []
    for text in lines[start + 1:]:
        if not text.strip():
            continue
        if text.strip().startswith("#"):
            return False        # the comment states the reason; that is a decision

        if len(text) - len(text.lstrip()) <= indent:
            break
        body.append(text)
        if len(body) > 1:
            return False
    return len(body) == 1 and bool(EMPTY_BODY.match(body[0]))


def _next_code_line_closes(lines, start):
    """True when the block opened at `start` closes with nothing but comments in it."""
    for text in lines[start + 1:]:
        stripped = text.strip()
        if not stripped:
            continue
        if stripped.startswith(("//", "/*", "*")):
            return False        # the comment states the reason; that is a decision
        return stripped.startswith("}")
    return False


def silent_exit(lines, language):
    """A non-zero exit with nothing said first. The caller gets a status code and no
    sentence, so the person reading the terminal has to go read the source to learn
    what failed."""
    patterns = {"shell": SHELL_EXIT, "python": PY_EXIT, "js": JS_EXIT}
    pattern = patterns[language]
    for index, text in code_lines(lines, language):
        match = pattern.search(text)
        if not match or GUARDED_EXIT.search(text):
            continue
        if _speaks_nearby(lines, index):
            continue
        yield index + 1, "silent-exit", text.strip()


def _speaks_nearby(lines, index):
    """True when this line, or one of the five code lines above it, says something to
    the operator. Five covers the shapes this repo actually writes: `echo ... >&2; exit
    2`, and a message printed above a multi-line `jq` call that renders the detail."""
    seen = 0
    for text in [lines[index]] + [lines[i] for i in range(index - 1, -1, -1)]:
        if not text.strip():
            continue
        if SPEAKS.search(text):
            return True
        seen += 1
        if seen > 5:
            break
    return False


def contextless(lines, language):
    """An error message a person cannot act on: every word in it is a synonym for
    "it broke". The failure that actually happened -- which file, which field,
    which limit -- is exactly what the message leaves out."""
    patterns = {"python": (PY_RAISE,), "js": (JS_THROW,), "shell": (SH_SAY,)}
    for index, text in code_lines(lines, language):
        for pattern in patterns[language]:
            for match in pattern.finditer(text):
                if match.groupdict().get("prefix") == "f":
                    continue
                body = match.group("body")
                if INTERPOLATION.search(body) or "," in text[match.end("body"):match.end()]:
                    continue
                words = [w.lower() for w in WORD.findall(body)]
                if not words or len(words) > MAX_GENERIC_WORDS:
                    continue
                if set(words) <= GENERIC:
                    yield index + 1, "contextless-error", body.strip()


def scan(path, text):
    """Every finding in one file, sorted and de-duplicated."""
    language = LANGUAGE.get(os.path.splitext(path)[1].lower())
    if not language:
        return []
    lines = text.splitlines()
    findings = list(swallowed(lines, language))
    findings += list(silent_exit(lines, language))
    findings += list(contextless(lines, language))
    return sorted(set(findings))


def read(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError:
        return None


def added_lines(tsv_path):
    """Diff mode: {path: {lineno, ...}}. A failure path the change did not touch is
    not this change's to answer for."""
    added = {}
    with open(tsv_path, "r", encoding="utf-8", errors="replace") as handle:
        for row in handle:
            parts = row.rstrip("\n").split("\t", 2)
            if len(parts) == 3:
                added.setdefault(parts[0], set()).add(int(parts[1]))
    return added


def main(argv):
    if argv[:1] == ["--tsv"]:
        keep = added_lines(argv[1])
        paths = sorted(keep)
    else:
        keep, paths = None, argv

    total, scanned, skipped = 0, 0, 0
    for path in paths:
        if os.path.splitext(path)[1].lower() not in LANGUAGE:
            skipped += 1
            continue
        text = read(path)
        if text is None:
            if keep is not None:
                continue        # deleted by the change; nothing to read
            print("failure-tells: cannot read {}".format(path), file=sys.stderr)
            return 2
        scanned += 1
        for lineno, tell, detail in scan(path, text):
            if keep is not None and lineno not in keep[path]:
                continue
            print("{}:{}: tell={}: {}".format(path, lineno, tell, detail[:90]))
            total += 1

    reason = "{} file(s)".format(scanned)
    if skipped:
        reason += ", {} skipped (no rules for that language)".format(skipped)
    if total:
        print("failure-tells: {} finding(s) ({})".format(total, reason))
        return 1
    print("failure-tells: clean ({})".format(reason))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
