#!/usr/bin/env bash
# comment-tells.sh - Deterministic lint: comments that were written for the
# generator, not for the next reader.
#
# Why: "do not over-comment" is unenforceable as prose -- every run judges its
# own output generous. These three tells mark machine-written code and cost a
# reader time no matter whose codebase they land in, and each is decidable from
# the text alone:
#
#   changelog       the diff narrated in the source ("previously", "renamed from")
#   diff-narration  a comment announcing the edit ("Added ...", "Updated ...")
#   echoes-code     a one-line comment whose next line of code says the same thing
#
# Comments are judged as BLOCKS, not lines: a tell is a comment that exists to
# announce or restate, and a sentence inside a longer explanation is neither.
#
# Section banners and "Step N:" narration are NOT here, though both read as tells.
# Run against this repo they fired 178 times and every hit was deliberate: the
# test suites use `--- Case A ---` dividers, and lib/workspace.sh numbers the
# steps of an ordered resolution algorithm. Both are convention-relative, so they
# stay judgments for the reviewer against the file's own neighbors -- a lint that
# fires on correct code teaches people to ignore it.
#
# Carve-outs, because a blunt "comment less" rule would fight the disciplines
# this repo already requires: the leading file-header block is exempt (loop-spec
# writes purpose headers on every script and they earn their place), as are
# marker comments (simplicity:, TODO, FIXME, NOTE, HACK, XXX, SAFETY, WHY),
# usage/signature docs above a definition, linter and type directives, shebangs,
# and license headers.
#
# Usage:
#   comment-tells.sh scan <file> [file ...]     # whole files
#   comment-tells.sh diff <base_ref> [head_ref] # added lines only (review path)
#
# Output: one finding per line, then a count.
#   lib/foo.sh:42: tell=echoes-code: # increment the counter
#   comment-tells: 1 finding(s)
#
# Exit codes (lint polarity, matching lib/deferral-lint.sh):
#   0  clean
#   1  findings reported
#   2  usage error / unreadable input
set -euo pipefail

MODE="${1:-}"
case "$MODE" in
  scan) [[ $# -ge 2 ]] || { echo "usage: comment-tells.sh scan <file> [file ...]" >&2; exit 2; } ;;
  diff) [[ $# -ge 2 && $# -le 3 ]] || { echo "usage: comment-tells.sh diff <base_ref> [head_ref]" >&2; exit 2; } ;;
  *) echo "usage: comment-tells.sh <scan|diff> ..." >&2; exit 2 ;;
esac
shift

# In diff mode the added lines are materialised into one tab-separated stream
# first, so the scanner below always receives the same shape -- path, line
# number, text -- whichever mode invoked it.
if [[ "$MODE" == "diff" ]]; then
  ADDED="${TMPDIR:-/tmp}/comment-tells-$$.tsv"
  trap 'rm -f "$ADDED"' EXIT
  git diff --unified=0 --no-color "$1" ${2:+"$2"} \
    | python3 -c '
import re, sys
path, lineno = None, 0
for line in sys.stdin:
    if line.startswith("+++ b/"):
        path = line[6:].rstrip("\n")
    elif line.startswith("@@"):
        m = re.search(r"\+(\d+)", line)
        lineno = int(m.group(1)) if m else 0
    elif line.startswith("+") and not line.startswith("+++") and path:
        sys.stdout.write("{}\t{}\t{}".format(path, lineno, line[1:]))
        lineno += 1
' > "$ADDED"
  set -- "--tsv" "$ADDED"
fi

python3 - "$@" <<'PY'
from __future__ import print_function

import os
import re
import sys

# Comment syntax per extension. Reading `--- section ---` inside a shell string
# as a SQL comment is how a scanner invents findings, so the prefix set is keyed
# on the file rather than assumed globally.
HASH = ("#",)
SLASH = ("//", "/*", "*")
COMMENT_PREFIX = {
    ".py": HASH, ".sh": HASH, ".bash": HASH, ".rb": HASH, ".pl": HASH,
    ".yml": HASH, ".yaml": HASH, ".toml": HASH, ".tf": HASH, ".ex": HASH,
    ".exs": HASH, ".r": HASH,
    ".js": SLASH, ".jsx": SLASH, ".ts": SLASH, ".tsx": SLASH, ".mjs": SLASH,
    ".cjs": SLASH, ".go": SLASH, ".java": SLASH, ".c": SLASH, ".h": SLASH,
    ".cc": SLASH, ".cpp": SLASH, ".hpp": SLASH, ".cs": SLASH, ".rs": SLASH,
    ".swift": SLASH, ".kt": SLASH, ".scala": SLASH, ".php": SLASH + HASH,
    ".css": ("/*", "*"), ".scss": SLASH,
    ".sql": ("--",), ".lua": ("--",), ".hs": ("--",),
}

# A comment carrying one of these is doing a job the codebase asked for.
EXEMPT = re.compile(
    r"\b(?:simplicity|TODO|FIXME|NOTE|HACK|XXX|SAFETY|WHY|WARNING|SECURITY)\b[:!]?"
    r"|\b(?:usage|example|args|arguments|params|parameters|returns|raises|"
    r"outputs?|exit codes?)\s*:"
    r"|\b(?:eslint|prettier|noqa|pylint|pyright|mypy|ruff|shellcheck|ts-ignore|"
    r"ts-expect-error)\b|\btype:\s*ignore\b|\bSPDX-|\bCopyright\b|\bLicensed under\b",
    re.I,
)

# Anchored at the block's first word: a comment that IS a changelog entry leads
# with the history. History quoted mid-sentence is explaining a decision -- "the
# contract is a script now; it used to be prose, which meant every run formatted
# it differently" -- and that comment is doing exactly the job comments are for.
CHANGELOG = re.compile(
    r"^(?:previously|used to (?:be|call|return|live)|renamed from|moved from|"
    r"changed from|replaces the old|no longer (?:used|needed|called)|"
    r"was:\s|formerly|deprecated in favou?r of)\b",
    re.I,
)

# Anchored at the block's first word and required to end on whitespace or a
# colon, so a hyphenated identifier ("new-mechanism:") stays prose. "Fixed" and
# "renamed" are absent on purpose: both read as ordinary adjectives in real
# comments ("fixed operating block", "renamed column"), and a tell that fires on
# prose is worse than one that misses.
DIFF_NARRATION = re.compile(
    r"^(?:(?:added|adding|updated|updating|removed|removing|refactored|"
    r"refactoring)(?=[\s:,])(?!\s+(?:in|to|entries?|files?)\b)|new(?=:))",
    re.I,
)

DEFINITION = re.compile(
    r"^\s*(?:export\s+|async\s+|public\s+|private\s+|protected\s+|static\s+)*"
    r"(?:def|func|function|fn|class|interface|type|struct|impl)\b"
    r"|^\s*[A-Za-z_][A-Za-z0-9_]*\s*\(\)\s*\{"
)
# A label the code deliberately restates -- a test name, a log message, an error
# string -- is not a comment echoing its code.
LITERAL = re.compile(r"""(['"])(?:(?!\1).){8,}\1""")

# A what-comment is terse by nature. Past this many words a comment is carrying
# context the code cannot, even when it reuses the code's nouns.
ECHO_MAX_WORDS = 10

STOPWORDS = frozenset("""
a an and are as at be by call calls called check do does for from get gets has have if in
into is it its let make makes new not of on or over return returns set sets so than that the
their then there these this to up us use used uses value values via was we when where which
while will with
""".split())

TOKEN = re.compile(r"[A-Za-z_][A-Za-z0-9_]*|\d+")
CASE_SPLIT = re.compile(r"[A-Z]?[a-z]+|[A-Z]{2,}(?![a-z])|\d+")


def strip_marker(text):
    """The comment's prose, without its opening syntax."""
    body = text.strip()
    for prefix in ("/**", "/*", "*/", "//", "#!", "#", "--", ";;"):
        if body.startswith(prefix):
            body = body[len(prefix):]
            break
    return body.strip(" *\t")


def atoms(text):
    """Words, with identifiers broken at their case and underscore seams, so
    `retry_count` and the prose "retry count" compare as the same two words.
    Only the parts survive: no prose ever writes the joined form back."""
    words = set()
    for token in TOKEN.findall(text):
        parts = CASE_SPLIT.findall(token)
        words.update(part.lower() for part in parts) if parts else words.add(token.lower())
    return words


def echoes(body, code_line):
    """True when the code line introduces no word the comment did not already
    say. That is the shape of a what-comment: `# increment the counter` above
    `counter += 1`. A why-comment names something the code cannot -- a
    constraint, a bug number, a reason -- so the subset never holds."""
    if len(body.split()) > ECHO_MAX_WORDS:
        return False
    if DEFINITION.match(code_line) or LITERAL.search(code_line):
        return False
    code = {t for t in atoms(code_line) if t not in STOPWORDS}
    if len(code) < 2:
        return False       # one-token lines are too easy to match by accident
    return code.issubset(atoms(body))


def blocks(numbered, is_comment):
    """Group the input into contiguous comment runs. Yields
    (start_index, [(lineno, text)], next_code_line_or_None).

    Contiguity is by LINE NUMBER, not array position. Diff mode hands over the
    added lines of every hunk in one stream, so neighbors in the list can be
    sixty lines apart in the file -- and a comment judged against code it does
    not actually sit above is a finding invented out of the gap."""
    index = 0
    total = len(numbered)
    while index < total:
        if not is_comment(numbered[index][1]):
            index += 1
            continue
        start = index
        run = [numbered[index]]
        index += 1
        while (index < total and is_comment(numbered[index][1])
               and numbered[index][0] == numbered[index - 1][0] + 1):
            run.append(numbered[index])
            index += 1
        following = None
        for lineno, text in numbered[index:index + 2]:
            if not text.strip():
                continue
            if lineno - run[-1][0] <= 2:
                following = text
            break
        yield start, run, following


def scan(path, numbered):
    prefixes = COMMENT_PREFIX.get(os.path.splitext(path)[1].lower())
    if not prefixes:
        return []

    def is_comment(text):
        body = text.strip()
        return bool(body) and body.startswith(prefixes)

    # The leading comment block is the file header: purpose, usage, exit codes.
    # loop-spec writes these deliberately, so nothing in it is a tell. Diff mode
    # hands over fragments rather than whole files, so the exemption applies only
    # when line 1 is actually present -- otherwise the first added comment in
    # every hunk would masquerade as a header and never be checked.
    header_end = 0
    if numbered and numbered[0][0] == 1:
        for index, (_, text) in enumerate(numbered):
            if not text.strip() or is_comment(text):
                header_end = index + 1
                continue
            break

    findings = []
    for start, run, following in blocks(numbered, is_comment):
        if start < header_end:
            continue
        if any(EXEMPT.search(text) for _, text in run):
            continue

        lineno, text = run[0]
        head = strip_marker(text)
        if not head:
            continue
        if CHANGELOG.search(head):
            findings.append((lineno, "changelog", head[:80]))
        elif DIFF_NARRATION.match(head):
            findings.append((lineno, "diff-narration", head[:80]))
        elif len(run) == 1 and following and echoes(head, following):
            findings.append((lineno, "echoes-code", head[:80]))

    return sorted(set(findings))


def group_tsv(path):
    """Diff mode: added lines, already tagged with their file and line."""
    grouped = {}
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for row in handle:
            parts = row.rstrip("\n").split("\t", 2)
            if len(parts) == 3:
                grouped.setdefault(parts[0], []).append((int(parts[1]), parts[2]))
    return grouped


args = sys.argv[1:]
if args[:1] == ["--tsv"]:
    sources = group_tsv(args[1])
else:
    sources = {}
    for path in args:
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as handle:
                sources[path] = list(enumerate(handle.read().splitlines(), 1))
        except OSError as exc:
            print("comment-tells: cannot read {}: {}".format(path, exc), file=sys.stderr)
            sys.exit(2)

total = 0
for path in sorted(sources):
    for lineno, tell, body in scan(path, sources[path]):
        print("{}:{}: tell={}: {}".format(path, lineno, tell, body))
        total += 1

if total:
    print("comment-tells: {} finding(s)".format(total))
    sys.exit(1)
print("comment-tells: clean")
PY
