#!/usr/bin/env bash
# house-style.sh - Deterministic probe: what conventions does the code around
# this change actually follow?
#
# Why: "honor the existing conventions" is the kind of prose criterion that rots.
# Two runs read the same repo and reach different conclusions about whether it
# comments heavily, uses tabs, or writes snake_case, and nothing catches the drift.
# This probe measures the neighbors instead and hands the implementer facts, so
# the house style is observed rather than recalled. Canonical directive:
# skills/shared/human-code.md.
#
# Targets are the files a task will touch. A target that does not exist yet is
# answered by its future neighbors: sibling files in the same directory sharing
# its extension, which is exactly the code a new file has to look like.
#
# Usage:
#   house-style.sh probe <path> [path ...]
#
# Output: one fact per line, ANSWER first, then the evidence that produced it.
#   comment_density=sparse reason=12/430 comment lines (2.8%)
#   sample=4 files: lib/a.sh, lib/b.sh, ...
#
# Exit codes:
#   0  facts emitted
#   1  no readable sample (answer unknown; the caller must ask, not guess)
#   2  usage error
set -euo pipefail

[[ "${1:-}" == "probe" && $# -ge 2 ]] || {
  echo "usage: house-style.sh probe <path> [path ...]" >&2
  exit 2
}
shift

python3 - "$@" <<'PY'
from __future__ import print_function

import os
import re
import sys

MAX_FILES = 12       # a sample, not a survey: keep the probe fast and bounded
MAX_LINES = 6000

# Comment syntax per extension. Only languages we can read confidently appear
# here; an unknown extension contributes to nothing but the file count, because
# a wrong comment prefix would manufacture a wrong density.
LINE_COMMENT = {
    ".py": ["#"], ".sh": ["#"], ".bash": ["#"], ".rb": ["#"], ".pl": ["#"],
    ".yml": ["#"], ".yaml": ["#"], ".toml": ["#"], ".tf": ["#"], ".r": ["#"],
    ".js": ["//"], ".jsx": ["//"], ".ts": ["//"], ".tsx": ["//"], ".mjs": ["//"],
    ".cjs": ["//"], ".go": ["//"], ".java": ["//"], ".c": ["//"], ".h": ["//"],
    ".cc": ["//"], ".cpp": ["//"], ".hpp": ["//"], ".cs": ["//"], ".rs": ["//"],
    ".swift": ["//"], ".kt": ["//"], ".scala": ["//"], ".php": ["//", "#"],
    ".sql": ["--"], ".lua": ["--"], ".hs": ["--"], ".ex": ["#"], ".exs": ["#"],
}
BLOCK_COMMENT = {".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs", ".go", ".java",
                 ".c", ".h", ".cc", ".cpp", ".hpp", ".cs", ".rs", ".swift",
                 ".kt", ".scala", ".php", ".css", ".scss"}
QUOTED = {".py", ".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs", ".rb"}

DEF_RE = re.compile(
    r"^\s*(?:export\s+)?(?:async\s+)?(?:public\s+|private\s+|protected\s+|static\s+)*"
    r"(?:def|func|function|fn|class|interface|type)\s+([A-Za-z_][A-Za-z0-9_]*)"
    r"|^\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*"
    r"(?:async\s+)?(?:function\b|\([^)]*\)\s*=>)"
    r"|^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{"          # bash: name() {
)


def sample_paths(targets):
    """Resolve targets to real files. A missing target is answered by its
    future neighbors -- same directory, same extension -- because that is the
    code it will have to sit beside."""
    picked = []
    seen = set()

    def add(path):
        if path not in seen and os.path.isfile(path):
            seen.add(path)
            picked.append(path)

    for target in targets:
        if os.path.isfile(target):
            add(target)
            continue
        directory = target if os.path.isdir(target) else (os.path.dirname(target) or ".")
        want_ext = "" if os.path.isdir(target) else os.path.splitext(target)[1]
        try:
            entries = sorted(os.listdir(directory))
        except OSError:
            continue
        for name in entries:
            if name.startswith("."):
                continue
            if want_ext and not name.endswith(want_ext):
                continue
            add(os.path.join(directory, name))
    return picked[:MAX_FILES]


class Tally(object):
    def __init__(self):
        self.code = 0
        self.comment = 0
        self.tabs = 0
        self.spaces = 0
        self.indent_widths = {}
        self.defs = []
        self.documented = 0
        self.single = 0
        self.double = 0
        self.lengths = []
        self.readable = []


def scan(path, tally):
    ext = os.path.splitext(path)[1].lower()
    prefixes = LINE_COMMENT.get(ext)
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            lines = handle.readlines()
    except OSError:
        return
    if not lines:
        return
    tally.readable.append(path)

    in_block = False
    previous_was_comment = False
    for raw in lines[:MAX_LINES]:
        line = raw.rstrip("\n")
        stripped = line.strip()
        if not stripped:
            previous_was_comment = False
            continue
        tally.lengths.append(len(line))

        is_comment = False
        if ext in BLOCK_COMMENT:
            if in_block:
                is_comment = True
                if "*/" in stripped:
                    in_block = False
            elif stripped.startswith("/*"):
                is_comment = True
                in_block = "*/" not in stripped
        if not is_comment and prefixes:
            is_comment = any(stripped.startswith(p) for p in prefixes)
        if not is_comment and ext == ".py" and (stripped.startswith('"""') or stripped.startswith("'''")):
            is_comment = True

        if is_comment:
            tally.comment += 1
            previous_was_comment = True
            continue
        tally.code += 1

        if line.startswith("\t"):
            tally.tabs += 1
        elif line.startswith(" "):
            tally.spaces += 1
            width = len(line) - len(line.lstrip(" "))
            tally.indent_widths[width] = tally.indent_widths.get(width, 0) + 1

        match = DEF_RE.match(line)
        if match:
            name = next(g for g in match.groups() if g)
            tally.defs.append(name)
            if previous_was_comment:
                tally.documented += 1

        if ext in QUOTED:
            tally.single += len(re.findall(r"'[^'\n]*'", line))
            tally.double += len(re.findall(r'"[^"\n]*"', line))
        previous_was_comment = False


def classify_name(name):
    if "_" in name:
        return "snake_case"
    if name[:1].isupper():
        return "PascalCase"
    if any(c.isupper() for c in name):
        return "camelCase"
    return "lowercase"


def majority(counts, floor=3):
    """Winner and its share, or (None, ...) when the evidence is too thin.
    Fail safe: a convention nobody demonstrated is not a convention."""
    total = sum(counts.values())
    if total < floor:
        return None, 0, total
    winner = max(counts, key=lambda k: counts[k])
    return winner, counts[winner], total


targets = sys.argv[1:]
paths = sample_paths(targets)
tally = Tally()
for path in paths:
    scan(path, tally)

if not tally.readable:
    print("sample=none reason=no readable file or neighbor for: {}".format(", ".join(targets)))
    sys.exit(1)

facts = []

total_lines = tally.code + tally.comment
if total_lines >= 20:
    pct = 100.0 * tally.comment / total_lines
    density = "sparse" if pct < 5 else ("moderate" if pct <= 15 else "heavy")
    facts.append("comment_density={} reason={}/{} comment lines ({:.1f}%)".format(
        density, tally.comment, total_lines, pct))
else:
    facts.append("comment_density=unknown reason=only {} code+comment lines sampled".format(total_lines))

if len(tally.defs) >= 3:
    share = 100.0 * tally.documented / len(tally.defs)
    answer = "yes" if share >= 70 else ("no" if share <= 30 else "mixed")
    facts.append("doc_comments={} reason={}/{} definitions carry a preceding comment ({:.0f}%)".format(
        answer, tally.documented, len(tally.defs), share))
else:
    facts.append("doc_comments=unknown reason=only {} definitions sampled".format(len(tally.defs)))

if tally.tabs > tally.spaces and tally.tabs >= 3:
    facts.append("indent=tabs reason={} tab-indented vs {} space-indented lines".format(
        tally.tabs, tally.spaces))
elif tally.spaces >= 3:
    steps = [w for w in tally.indent_widths if w > 0]
    width = min(steps) if steps else 0
    facts.append("indent=spaces:{} reason=smallest indent step across {} indented lines".format(
        width, tally.spaces))
else:
    facts.append("indent=unknown reason=too few indented lines sampled")

if tally.defs:
    styles = {}
    for name in tally.defs:
        style = classify_name(name)
        styles[style] = styles.get(style, 0) + 1
    winner, hits, total = majority(styles)
    if winner and hits * 2 > total:
        facts.append("naming={} reason={}/{} sampled definition names".format(winner, hits, total))
    else:
        facts.append("naming=mixed reason=no majority across {} definition names".format(total))
else:
    facts.append("naming=unknown reason=no definitions sampled")

if tally.lengths:
    ordered = sorted(tally.lengths)
    p90 = ordered[min(len(ordered) - 1, int(0.9 * len(ordered)))]
    facts.append("line_length=p90:{} max:{} reason={} sampled lines".format(
        p90, ordered[-1], len(ordered)))

if tally.single + tally.double >= 10:
    answer = "single" if tally.single > 2 * tally.double else (
        "double" if tally.double > 2 * tally.single else "mixed")
    facts.append("quotes={} reason={} single vs {} double quoted spans".format(
        answer, tally.single, tally.double))

for fact in facts:
    print(fact)
print("sample={} files: {}".format(len(tally.readable), ", ".join(tally.readable)))
PY
