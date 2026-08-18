#!/usr/bin/env python3
"""Derive the bundled-surface index from the tree.

lib/surface.sh owns argument and path setup. This module owns the derivation so a
reader can see the parsing rules as ordinary Python: which directories are the
surface, where a file's purpose line lives, and what `find`/`show` match against.
"""

from __future__ import print_function

import os
import re
import signal
import sys

# Output is meant to be piped (`| head`, `| cut`); a closed reader is a normal end, not
# a traceback.
signal.signal(signal.SIGPIPE, signal.SIG_DFL)

root, cmd = sys.argv[1], sys.argv[2]
args = sys.argv[3:]

# A shell script's purpose is its header comment; a contract's is the paragraph under its
# title. Both are prose a human already wrote for a human -- this only locates it.
DIRS = {
    "lib": [("lib", ".sh"), (os.path.join("lib", "graph"), ".sh")],
    "shared": [(os.path.join("skills", "shared"), ".md")],
    "agent": [("agents", ".md")],
}
KINDS = ("lib", "shared", "agent")
# A test lives beside its subject in lib/ but is not part of the surface an agent calls,
# and agents/README.md is the directory's own prose, not a role charter.
SKIP = re.compile(r"\.test\.sh$|^README\.md$")


def entries(kind):
    dirs = DIRS[kind]
    found = []
    for rel_dir, ext in dirs:
        abs_dir = os.path.join(root, rel_dir)
        if not os.path.isdir(abs_dir):
            continue
        for name in sorted(os.listdir(abs_dir)):
            if not name.endswith(ext) or SKIP.search(name):
                continue
            path = os.path.join(rel_dir, name)
            found.append((kind, path, purpose(os.path.join(root, path), ext)))
    return found


def header_lines(path, ext):
    """The leading prose block: a shell script's `#` comments after the shebang, or a
    markdown file's title plus the paragraph under it."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return []
    if ext == ".sh":
        block = []
        for line in lines[1:]:
            if line.startswith("#"):
                block.append(line.lstrip("#").strip())
            elif not block:
                continue  # a blank line before the header block starts
            else:
                break
        return block
    # A contract's header is its title AND the paragraph under it. The title alone is
    # the filename restated -- "Dispatch telemetry contract" for dispatch-events.md
    # tells a searching agent nothing it did not already have.
    block = []
    paragraphs = 0
    for line in lines:
        if not line.strip():
            if block:
                paragraphs += 1
                if paragraphs >= 2:
                    break
            continue
        block.append(re.sub(r"^#+\s*", "", line).strip())
    return block


USAGE_SHAPED = re.compile(r"^(?:usage\b|[<\[-]\S*(?:\s+\S+)*$)", re.I)


FRONTMATTER_DESCRIPTION = re.compile(r'^description:\s*"?(.*?)"?\s*$')


def frontmatter_description(path):
    """An agent charter states its role in `description:`, which is also what the harness
    shows when routing to it. Returns "" for a file with no frontmatter."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            lines = fh.read().splitlines()
    except OSError:
        return []
    if not lines or lines[0].strip() != "---":
        return []
    block = []
    for line in lines[1:]:
        if line.strip() == "---":
            break
        block.append(line.rstrip())
    return block


def purpose(path, ext):
    """One line: the first sentence of the first header paragraph that actually says
    something. Skipped on the way there: a markdown title (a label, not a purpose), a
    self-referential prefix ("status.sh - ") that says the filename twice, and a
    usage-shaped line ("<feature-dir>", "[-C <path>] <base_ref>") that describes
    arguments rather than what the file is for."""
    if path.replace(os.sep, "/").rsplit("/", 2)[-2:-1] == ["agents"]:
        for line in frontmatter_description(path):
            match = FRONTMATTER_DESCRIPTION.match(line)
            if match:
                return match.group(1)[:200].rstrip()
    block = header_lines(path, ext)
    if not block:
        return ""
    base = os.path.basename(path)
    self_ref = re.compile(r"^(?:lib/|skills/shared/)?" + re.escape(base) + r"\b[\s\-:]*")
    paragraph = []
    # A markdown title is a label; the paragraph under it is the purpose.
    for line in (block[1:] if ext == ".md" else block) + [""]:
        if line:
            paragraph.append(line)
            continue
        if paragraph:
            text = self_ref.sub("", " ".join(paragraph)).strip()
            if text and not USAGE_SHAPED.match(text):
                # Sentence end only: a colon here is a label ("Deterministic probe: ..."),
                # and cutting there throws away the half that names the subject.
                return re.split(r"(?<=\.)\s", text, 1)[0][:200].rstrip()
            paragraph = []
    return block[0][:200]


def emit(rows):
    for kind, path, text in rows:
        print("%s\t%s\t%s" % (kind, path, text))
    return 0 if rows else 1


def every_entry():
    rows = []
    for kind in KINDS:
        rows.extend(entries(kind))
    return rows


if cmd == "list":
    kinds = args or ["all"]
    if len(kinds) != 1 or kinds[0] not in KINDS + ("all",):
        print("surface.sh: list takes %s, or all" % ", ".join(KINDS), file=sys.stderr)
        sys.exit(2)
    sys.exit(emit(every_entry() if kinds[0] == "all" else entries(kinds[0])))

if cmd == "find":
    if not args:
        print("surface.sh: find needs at least one term", file=sys.stderr)
        sys.exit(2)
    terms = [a.lower() for a in args]
    rows = [r for r in every_entry()
            if all(t in (r[1] + " " + r[2]).lower() for t in terms)]
    if not rows:
        print("surface.sh: no bundled script or contract matches: %s" % " ".join(args),
              file=sys.stderr)
    sys.exit(emit(rows))

def resolve_target(name):
    """A bare name resolves through the index, so `covers ralph-remediation` and
    `covers lib/ralph-remediation.sh` ask the same question."""
    name = name.lstrip("./")
    if "/" in name:
        return name
    for _kind, path, _text in every_entry():
        base = os.path.basename(path)
        if name in (base, os.path.splitext(base)[0]):
            return path
    return name


def names_path(text, target):
    """A suite names a path when it writes the repo-relative path (possibly under a root
    variable, `"$ROOT/lib/x.sh"`), or the bare basename with no directory in front of it.
    A basename under SOME OTHER directory is a different file -- a fixture called
    `core/engine.py` is not coverage of `lib/graph/engine.py`."""
    if target in text:
        return True
    base = os.path.basename(target)
    return re.search(r"(?<![\w/.-])" + re.escape(base), text) is not None


if cmd == "covers":
    # "I changed this file -- what must I run?" is asked on every change and answered
    # today by grepping the whole tests tree. A suite that names the path is a suite
    # that pins it, so the answer is the set of suites naming it -- including the
    # coupling pins, which are exactly the suites that name a file they do not own.
    if not args:
        print("surface.sh: covers needs at least one path", file=sys.stderr)
        sys.exit(2)
    suites = []
    for dirpath, _dirnames, filenames in os.walk(os.path.join(root, "tests")):
        for name in filenames:
            if name.endswith(".test.sh") or name in ("run-all.sh", "validate-agents.sh"):
                suites.append(os.path.relpath(os.path.join(dirpath, name), root))
    suites = sorted(set(suites))
    rows = []
    for raw in args:
        target = resolve_target(raw)
        for suite in suites:
            if suite == target:
                continue  # a suite never "covers" itself
            try:
                with open(os.path.join(root, suite), "r", encoding="utf-8",
                          errors="replace") as fh:
                    text = fh.read()
            except OSError:
                continue
            if names_path(text, target):
                rows.append(("covers", target, suite))
    if not rows:
        print("surface.sh: no registered suite names: %s" % " ".join(args), file=sys.stderr)
    sys.exit(emit(rows))

if cmd == "show":
    if len(args) != 1:
        print("surface.sh: show takes exactly one path or name", file=sys.stderr)
        sys.exit(2)
    wanted = args[0]
    for kind, path, _text in every_entry():
        base = os.path.basename(path)
        if wanted in (path, base, os.path.splitext(base)[0]):
            abs_path = os.path.join(root, path)
            print(path)
            block = (frontmatter_description(abs_path) if kind == "agent"
                     else header_lines(abs_path, os.path.splitext(path)[1]))
            for line in block:
                print("  " + line if line else "")
            sys.exit(0)
    print("surface.sh: no bundled script or contract named %r" % wanted, file=sys.stderr)
    sys.exit(1)

print("surface.sh: unknown command %r" % cmd, file=sys.stderr)
sys.exit(2)
