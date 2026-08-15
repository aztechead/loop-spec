#!/usr/bin/env bash
# indirection-scan.sh - Deterministic probe: did this change add a layer nobody
# needed?
#
# Why: the ladder's rung 1 (YAGNI) and the reviewer's `yagni:` tag are the only
# parts of the simplicity discipline with no measurement behind them. "No
# abstraction with one caller" has been in the directive from the start, and the
# one-caller wrapper is still the most common thing a model adds to a diff --
# it reads as good decomposition while it is being written, and the cost only
# shows up later, when a reader has to follow three hops to find four lines.
#
# What counts: a definition the change added that is private to its file, small,
# and referenced exactly once. All four conditions matter, because each one on
# its own is ordinary good code:
#
#   private     an exported symbol has callers this probe cannot see, so it is
#               never reported -- that is the difference between a helper and an
#               API with one internal user
#   small       a long function with one caller is decomposition, which is what
#               you WANT; a four-line pass-through is the smell
#   called once zero callers is dead code (a different finding, and one the
#               language's own tooling reports), two or more is reuse working
#   added       a wrapper that predates the change is the repository's, not this
#               author's -- diff mode reports only what the diff introduced
#
# This is the rung the ladder cannot check by asking harder: at the moment of
# writing, the wrapper always looks justified. It is only countable afterwards.
#
# Calibration, over the last 12 non-merge commits of this repo: 9 clean, with
# every finding in the other 3 a genuine single-use helper.
#
# Usage:
#   indirection-scan.sh scan <file> [file ...]     # definitions in these files
#   indirection-scan.sh diff <base_ref> [head_ref] # only definitions the diff added
#
# Env:
#   LOOP_SPEC_INDIRECTION_MAX_BODY  body lines below which a one-caller
#                                   definition is a wrapper (default 5, min 1)
#
# Output: one finding per line, then the count.
#   src/checkout.js:3: single-caller=buildCartQueryKey: 2 body lines, called once at line 12
#   indirection-scan: 1 finding(s) defs=4 window<=5
#
# Exit codes (lint polarity, matching lib/duplication-scan.sh):
#   0  clean
#   1  indirection reported
#   2  usage error / unreadable input
set -euo pipefail

MODE="${1:-}"
case "$MODE" in
  scan) [[ $# -ge 2 ]] || { echo "usage: indirection-scan.sh scan <file> [file ...]" >&2; exit 2; } ;;
  diff) [[ $# -ge 2 && $# -le 3 ]] || { echo "usage: indirection-scan.sh diff <base_ref> [head_ref]" >&2; exit 2; } ;;
  *) echo "usage: indirection-scan.sh <scan|diff> ..." >&2; exit 2 ;;
esac
shift

# Same shape from both modes: a target path per line, and in diff mode the line
# numbers the change added, so a wrapper that was already there stays the
# repository's finding rather than this author's.
TARGETS="${TMPDIR:-/tmp}/indirection-scan-$$.tsv"
trap 'rm -f "$TARGETS"' EXIT
if [[ "$MODE" == "diff" ]]; then
  git diff --unified=0 --no-color "$1" ${2:+"$2"} \
    | python3 "$(dirname "${BASH_SOURCE[0]}")/diff-added-lines.py" > "$TARGETS"
else
  printf '%s\n' "$@" > "$TARGETS"
fi

python3 - "$MODE" "$TARGETS" <<'PY'
from __future__ import print_function

import os
import re
import subprocess
import sys

MAX_CORPUS = 600
MAX_LINES = 5000
DEFAULT_MAX_BODY = 5


def max_body():
    """Operator override outranks the default; anything unreadable falls back
    rather than reporting every function in the tree as a wrapper."""
    raw = os.environ.get("LOOP_SPEC_INDIRECTION_MAX_BODY", "")
    try:
        return max(1, int(raw))
    except ValueError:
        return DEFAULT_MAX_BODY


MAX_BODY = max_body()

# Only languages whose definitions and exports we can read confidently. An
# unknown extension contributes nothing: guessing what a definition looks like
# is how a probe invents findings.
DEF_PATTERNS = {
    ".py": re.compile(r"^(?P<indent>\s*)def\s+(?P<name>[A-Za-z_]\w*)\s*\("),
    ".js": re.compile(
        r"^(?P<indent>\s*)(?:(?P<export>export\s+)?(?:async\s+)?function\s+(?P<name>[A-Za-z_]\w*)\s*\("
        r"|(?P<export2>export\s+)?const\s+(?P<name2>[A-Za-z_]\w*)\s*=\s*(?:async\s*)?(?:\([^)]*\)|[A-Za-z_$][\w$]*)\s*=>)"),
    ".sh": re.compile(r"^(?P<indent>)(?P<name>[A-Za-z_]\w*)\s*\(\)\s*\{"),
    ".go": re.compile(r"^(?P<indent>)func\s+(?:\([^)]*\)\s*)?(?P<name>[A-Za-z_]\w*)\s*\("),
}
for alias, base in ((".jsx", ".js"), (".ts", ".js"), (".tsx", ".js"),
                    (".mjs", ".js"), (".cjs", ".js"), (".bash", ".sh")):
    DEF_PATTERNS[alias] = DEF_PATTERNS[base]

COMMENT_PREFIX = {".py": "#", ".sh": "#", ".bash": "#"}
HEREDOC_OPEN = re.compile(r"<<-?\s*[\"']?([A-Za-z_]\w*)[\"']?")

# A symbol reachable from outside the file has callers this probe cannot count.
EXPORTED = {
    ".py": lambda name, text: (
        "__all__" in text
        and ('"{}"'.format(name) in text or "'{}'".format(name) in text)),
    ".js": lambda name, text: bool(
        re.search(r"\bexport\b[^\n]*\b{}\b".format(re.escape(name)), text)
        or re.search(r"\bmodule\.exports\b[\s\S]{{0,200}}\b{}\b".format(re.escape(name)), text)
        or re.search(r"\bexports\.{}\b".format(re.escape(name)), text)),
    ".sh": lambda name, text: bool(
        re.search(r"\bexport\s+-f\s+{}\b".format(re.escape(name)), text)),
    ".go": lambda name, text: name[:1].isupper(),
}
for alias, base in ((".jsx", ".js"), (".ts", ".js"), (".tsx", ".js"),
                    (".mjs", ".js"), (".cjs", ".js"), (".bash", ".sh")):
    EXPORTED[alias] = EXPORTED[base]


def read(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return handle.read().splitlines()[:MAX_LINES]
    except OSError:
        return None


def body_length(lines, start, indent, ext):
    """Significant lines belonging to the definition that opens at `start`, or
    None when the shape is one this probe cannot size.

    Brace languages close on the matching brace; indentation languages close
    when the indent returns. Either way blank lines and comments are not body:
    a wrapper padded with a docstring is still a wrapper.

    An expression-bodied arrow (`const f = (x) => a + b`, continued over lines)
    has no brace to close on. Sizing it by the opening line reports a twenty-line
    string builder as a nought-line wrapper, so it is measured as unknown and
    skipped instead -- the same fail-safe every other probe here takes."""
    comment = COMMENT_PREFIX.get(ext)
    count = 0
    depth = lines[start].count("{") - lines[start].count("}")
    if ext not in (".py",) and depth <= 0:
        return None
    for line in lines[start + 1:]:
        stripped = line.strip()
        if ext in (".py",):
            if stripped and not line.startswith(indent + " ") and not line.startswith(indent + "\t"):
                break
        else:
            if depth <= 0:
                break
            depth += line.count("{") - line.count("}")
            if depth <= 0:
                break
        if not stripped:
            continue
        if comment and stripped.startswith(comment):
            continue
        if ext not in (".py", ".sh", ".bash") and stripped.startswith(("//", "/*", "*")):
            continue
        count += 1
    return count


def definitions(path):
    """(name, lineno, body_lines) for every definition the file opens."""
    ext = os.path.splitext(path)[1].lower()
    pattern = DEF_PATTERNS.get(ext)
    lines = read(path) if pattern else None
    if not lines:
        return [], ""

    found = []
    heredoc = None
    for index, line in enumerate(lines):
        # A shell heredoc holds another language -- this repo's scripts carry
        # whole Python programs and test fixtures in them. Its `def`s belong to
        # that program, not to the shell file wrapping it.
        stripped = line.strip()
        if heredoc is not None:
            if stripped == heredoc:
                heredoc = None
            continue
        if ext in (".sh", ".bash"):
            opener = HEREDOC_OPEN.search(line)
            if opener:
                heredoc = opener.group(1)
                continue

        match = pattern.match(line)
        if not match:
            continue
        groups = match.groupdict()
        name = groups.get("name") or groups.get("name2")
        if not name:
            continue
        body = body_length(lines, index, groups.get("indent") or "", ext)
        if body is None:
            continue
        found.append((name, index + 1, body))
    return found, "\n".join(lines)


def corpus_text(targets):
    """Every place a name could be called from, bounded. A reference anywhere
    counts: the question is whether the definition has one user, not where."""
    wanted = set(os.path.splitext(t)[1].lower() for t in targets)
    wanted.discard("")
    try:
        out = subprocess.check_output(
            ["git", "ls-files", "-z"], stderr=open(os.devnull, "wb"))
        listing = [p for p in out.decode("utf-8", "replace").split("\0") if p]
    except (OSError, subprocess.CalledProcessError):
        listing = []
        for root, dirs, names in os.walk("."):
            dirs[:] = [d for d in dirs if not d.startswith(".")
                       and d not in ("node_modules", "vendor", "dist", "build")]
            listing.extend(os.path.join(root, n)[2:] for n in names)

    chunks = {}
    target_by_identity = {os.path.realpath(path): path for path in targets}
    for path in listing:
        if os.path.splitext(path)[1].lower() not in wanted:
            continue
        lines = read(path)
        if lines is None:
            continue
        # git spells tracked files relative to the repository, but dispatched
        # agents commonly supply absolute target paths. Keep one identity under
        # the caller's spelling so the definition itself is not counted as an
        # extra reference from a second alias of the same file.
        key = target_by_identity.get(os.path.realpath(path), path)
        chunks[key] = lines
        if len(chunks) >= MAX_CORPUS:
            break
    return chunks


mode, target_list = sys.argv[1], sys.argv[2]
added = {} if mode == "diff" else None
targets = []
with open(target_list, "r", encoding="utf-8", errors="replace") as handle:
    for row in handle:
        row = row.rstrip("\n")
        if not row.strip():
            continue
        if added is None:
            targets.append(row.strip())
            continue
        path, lineno = row.split("\t")[:2]
        added.setdefault(path, set()).add(int(lineno))
if added is not None:
    targets = sorted(added)

missing = [t for t in targets if not os.path.isfile(t)]
if missing and mode == "scan":
    for path in missing:
        print("indirection-scan: cannot read {}".format(path), file=sys.stderr)
    sys.exit(2)
picked = []
seen_targets = set()
for target in targets:
    if not os.path.isfile(target):
        continue
    identity = os.path.realpath(target)
    if identity in seen_targets:
        continue
    seen_targets.add(identity)
    picked.append(target)
targets = picked

corpus = corpus_text(targets)
for path in targets:
    if path not in corpus:
        lines = read(path)
        if lines is not None:
            corpus[path] = lines

findings = []
total_defs = 0
for path in sorted(targets):
    defs, text = definitions(path)
    total_defs += len(defs)
    ext = os.path.splitext(path)[1].lower()
    is_exported = EXPORTED.get(ext, lambda name, text: True)

    for name, lineno, body in defs:
        if added is not None and lineno not in added.get(path, ()):
            continue        # the wrapper predates this diff
        if body > MAX_BODY:
            continue        # decomposition, which is the point of functions
        if is_exported(name, text):
            continue        # callers exist that this probe cannot see
        word = re.compile(r"\b{}\b".format(re.escape(name)))
        sites = []
        for other, lines in corpus.items():
            for index, line in enumerate(lines):
                if other == path and index + 1 == lineno:
                    continue        # the definition itself is not a call
                if word.search(line):
                    sites.append((other, index + 1))
        if len(sites) != 1:
            continue        # 0 is dead code, 2+ is reuse working
        where, at = sites[0]
        findings.append((path, lineno, name, body, where, at))

for path, lineno, name, body, where, at in findings:
    site = "line {}".format(at) if where == path else "{}:{}".format(where, at)
    print("{}:{}: single-caller={}: {} body lines, called once at {}".format(
        path, lineno, name, body, site))

scope = "defs={} body<={}".format(total_defs, MAX_BODY)
if findings:
    print("indirection-scan: {} finding(s) {}".format(len(findings), scope))
    sys.exit(1)
print("indirection-scan: clean {}".format(scope))
PY
