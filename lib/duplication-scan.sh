#!/usr/bin/env bash
# duplication-scan.sh - Deterministic probe: does this change repeat code the
# codebase already has?
#
# Why: rung 2 of the laziness ladder ("already in this codebase? reuse it") is
# the one rung a fresh context cannot climb by trying harder. The helper it
# should have reused is in a file it never opened, so the run writes a second
# copy, passes its tests, and ships. Prose cannot fix that -- "search the tree
# first" is already in the directive and the second copy still lands. This probe
# answers the rung with a measurement: the target files against each other and
# against the rest of the tree, so a reimplementation is visible before DONE and
# demonstrable at review.
#
# Two tiers, because copy-paste arrives in two shapes and only one of them is
# visible to a verbatim match:
#
#   duplicate=  MIN_LINES consecutive significant lines, character-identical
#               after whitespace is collapsed
#   similar=    SHAPE_LINES consecutive lines identical once identifiers and
#               literals are replaced by placeholders -- the same code with
#               every name changed
#
# The second tier is the one that matters for generated code. An agent writing
# `orders.ts` next to `users.ts` produces the same twelve lines with `user`
# swapped for `order` throughout, and a verbatim matcher reports it clean. That
# is not an edge case; it is the default output shape, and a DRY probe blind to
# it would pass exactly the diffs it exists to catch.
#
# The shape tier is also the noisy one, so it is fenced three ways: a wider
# window (six lines of any language's boilerplate share a shape), a rejection of
# windows whose own lines are mostly identical to each other (a table of uniform
# rows otherwise matches a shifted copy of itself at every offset -- left in,
# tests/run-all.sh reports as a 151-line clone of itself), and suppression of any
# shape finding overlapping a verbatim one, since `duplicate=` is strictly more
# actionable. A lint that fires on correct code teaches people to ignore it.
#
# Comments, blank lines, and structural punctuation (a lone `}`, `fi`, `done`)
# are dropped before matching at both tiers -- they pad any two blocks toward
# each other and are the fastest way to manufacture a finding out of nothing.
#
# Carve-outs:
#   - only code is read; prose and data (.md, .json, anything whose comment
#     syntax we do not know) repeat by nature and are skipped
#   - generated files and marked generated regions (this repo's `@inject:`
#     snippet blocks): the generator is the single source, so its copies are
#     the mechanism working, not a rung skipped
#   - a block appearing in more than UBIQUITY_MAX files is the house pattern,
#     not a copy-paste (a shared preamble, a standard fixture header)
#   - overlapping windows inside one file report once, at their full extent
#   - each pair reports once, from whichever target names it first
#   - diff mode reports only clones the change actually touched: duplication
#     already sitting in a file the diff happened to open is the repository's
#     debt, and reporting it buries the one finding the author can act on
#
# Calibration, over the last 14 non-merge commits of this repo: 9 report clean,
# and every finding in the other 5 is real -- `conf_get` verbatim in three files,
# harness coverage suites sharing substantial test scaffolding and more by
# shape, the two near-identical assertion helpers inside plain-language-lint's
# test. Scanning whole files instead -- every tracked source file as a target at
# once -- surfaces 216, which is the repository's standing duplication rather
# than any one author's, and is why diff mode filters to what a change touched.
#
# Usage:
#   duplication-scan.sh scan <file> [file ...]     # targets vs each other and the tree
#   duplication-scan.sh diff <base_ref> [head_ref] # changed files, same comparison
#
# Env:
#   LOOP_SPEC_DUP_MIN_LINES  verbatim window in significant lines (default 6,
#                            min 3); the shape window is always this plus two
#
# Output: one finding per line, then the count and what was compared.
#   lib/foo.sh:42-58: duplicate=12 lines: also at lib/bar.sh:11-27
#   src/orders.ts:1-10: similar=8 lines: also at src/users.ts:1-10
#   duplication-scan: 2 finding(s) targets=3 corpus=182 window=6/8
#
# Exit codes (lint polarity, matching lib/comment-tells.sh):
#   0  clean
#   1  duplication reported
#   2  usage error / unreadable input
set -euo pipefail

MODE="${1:-}"
case "$MODE" in
  scan) [[ $# -ge 2 ]] || { echo "usage: duplication-scan.sh scan <file> [file ...]" >&2; exit 2; } ;;
  diff) [[ $# -ge 2 && $# -le 3 ]] || { echo "usage: duplication-scan.sh diff <base_ref> [head_ref]" >&2; exit 2; } ;;
  *) echo "usage: duplication-scan.sh <scan|diff> ..." >&2; exit 2 ;;
esac
shift

# Both modes hand the scanner a target file per line; diff mode appends the line
# numbers it added, because a clone the change did not touch is the repository's
# existing debt and not this diff's finding.
TARGETS="${TMPDIR:-/tmp}/duplication-scan-$$.tsv"
trap 'rm -f "$TARGETS"' EXIT
if [[ "$MODE" == "diff" ]]; then
  git diff --unified=0 --no-color "$1" ${2:+"$2"} \
    | python3 "$(dirname "${BASH_SOURCE[0]}")/diff-added-lines.py" > "$TARGETS"
else
  printf '%s\n' "$@" > "$TARGETS"
fi

python3 - "$MODE" "$TARGETS" <<'PY'
from __future__ import print_function

import hashlib
import os
import re
import subprocess
import sys

MAX_CORPUS = 600     # a bounded comparison, not a repository census
MAX_LINES = 5000
UBIQUITY_MAX = 6     # past this many files a block is the convention, not a clone

DEFAULT_MIN_LINES = 6


def window_size():
    """Operator override outranks the default; anything unreadable falls back
    rather than scanning with a window of 1 and reporting the whole tree."""
    raw = os.environ.get("LOOP_SPEC_DUP_MIN_LINES", "")
    try:
        return max(3, int(raw))
    except ValueError:
        return DEFAULT_MIN_LINES


MIN_LINES = window_size()

# The shape tier matches with the names taken away, so it must clear a higher
# bar: six lines of any language's boilerplate share a shape, and reporting
# those would bury the copy-paste this probe exists to find. Measured on this
# repo, +2 is where the shape findings stop being idiom and start being clones.
SHAPE_LINES = MIN_LINES + 2

# Comment syntax per extension, keyed on the file: reading `--- section ---`
# inside a shell string as a SQL comment is how a scanner invents findings.
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

# Generated code has one source already, so its copies are the mechanism working
# rather than a rung skipped. A file that declares itself generated is skipped
# whole; a marked region inside a hand-written file is skipped in place, which is
# how this repo's `@inject:` snippet blocks stay quiet.
GENERATED_FILE = re.compile(
    r"@generated\b|\bdo not edit\b|\bcode generated by\b|\bauto-?generated\b", re.I)
REGION_OPEN = re.compile(r"@(?:inject|generated|codegen)\b(?!:end)", re.I)
REGION_CLOSE = re.compile(r"@(?:inject|generated|codegen):end\b", re.I)

# Punctuation and block terminators carry no logic. Left in, six of them in a
# row are a "clone" shared by every file in the language.
STRUCTURAL = re.compile(
    r"^(?:[)}\]{(;,]|\.\.\.)+$"
    r"|^(?:fi|done|esac|end|else|do|then|return|break|continue|pass|"
    r"</\w+>|};?|\)\s*;?|\]\s*,?|\{)$",
    re.I,
)
WHITESPACE = re.compile(r"\s+")

# The structural tier: what the block would look like with its names taken away.
# Keywords and punctuation survive so `const x = f()` and `let y = g()` stay
# different shapes; everything else the author chose becomes a placeholder.
KEYWORDS = frozenset("""
and as async await bool break by case catch class const continue declare def default
defer del delete do done elif else elsif end enum esac eval except export extends fi
final finally float for foreach from func function global go if impl implements import
in include input instanceof int interface is lambda let local match mod module mut new
nil none not null of or package pass print printf private protected public raise readonly
require rescue return select self set static string struct super switch then this throw
throws trait true false try type typedef typeof unset use using val var void when where
while with yield echo local source exit test then
""".split())
IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
NUMBER = re.compile(r"\b\d+(?:\.\d+)?\b")
STRING = re.compile(r"""'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*\"""")


def shape(text):
    """The line with its names removed. Literals go first so a digit inside a
    string cannot survive as one, and the placeholders are punctuation rather
    than words so the identifier pass cannot rewrite them again."""
    text = STRING.sub('""', text)
    text = NUMBER.sub("0", text)
    return IDENTIFIER.sub(
        lambda m: m.group(0) if m.group(0).lower() in KEYWORDS else "V", text)


def significant(path):
    """(lineno, collapsed_text, shape) for the lines that carry logic. Blank
    lines and comments are dropped rather than kept as separators: a clone stays
    a clone when the copy re-wrapped its comments."""
    prefixes = COMMENT_PREFIX.get(os.path.splitext(path)[1].lower())
    if not prefixes:
        return []       # prose and data repeat by nature; this probe reads code
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            raw = handle.read().splitlines()[:MAX_LINES]
    except OSError:
        return None

    if any(GENERATED_FILE.search(line) for line in raw[:20]):
        return []

    kept = []
    generated = False
    for lineno, line in enumerate(raw, 1):
        text = line.strip()
        if not text:
            continue
        if prefixes and text.startswith(prefixes):
            if REGION_CLOSE.search(text):
                generated = False
            elif REGION_OPEN.search(text):
                generated = True
            continue
        if generated or STRUCTURAL.match(text):
            continue
        collapsed = WHITESPACE.sub(" ", text)
        kept.append((lineno, collapsed, shape(collapsed)))
    return kept


def digest(window):
    return hashlib.sha1("\n".join(window).encode("utf-8")).digest()


def windows(lines, tier, size):
    """(index, digest) for every `size`-long run of significant lines, read at
    the given tier -- 1 for the verbatim text, 2 for its shape.

    A window whose lines are mostly the same as each other is skipped: it
    carries no structure to match on, and it matches a shifted copy of itself at
    every offset. That is how a table of `run_suite "name" "cmd"` rows reports as
    a 151-line clone of the same file eight lines further down."""
    texts = [row[tier] for row in lines]
    for start in range(0, len(texts) - size + 1):
        chunk = texts[start:start + size]
        if len(set(chunk)) * 2 < size:
            continue
        yield start, digest(chunk)


def corpus_paths(targets):
    """Tracked files sharing an extension with a target -- the code a reused
    helper would already be sitting in. Untracked trees fall back to a walk so
    the probe still answers outside git."""
    wanted = set(os.path.splitext(t)[1].lower() for t in targets)
    wanted.discard("")
    if not wanted:
        return []

    listing = []
    try:
        out = subprocess.check_output(
            ["git", "ls-files", "-z"], stderr=open(os.devnull, "wb"))
        listing = [p for p in out.decode("utf-8", "replace").split("\0") if p]
    except (OSError, subprocess.CalledProcessError):
        for root, dirs, names in os.walk("."):
            dirs[:] = [d for d in dirs if not d.startswith(".")
                       and d not in ("node_modules", "vendor", "dist", "build")]
            listing.extend(os.path.join(root, n)[2:] for n in names)

    # Callers are encouraged to pass absolute paths, while git ls-files emits
    # paths relative to the repository root. Compare identities rather than
    # spellings or the target is admitted to its own corpus and reported as a
    # full-file duplicate of itself.
    seen = set(os.path.realpath(t) for t in targets)
    candidates = [path for path in listing
                  if os.path.splitext(path)[1].lower() in wanted
                  and os.path.realpath(path) not in seen
                  and os.path.isfile(path)]

    # MAX_CORPUS truncates, so the order decides what a large repository gets
    # compared against. Nearest first: the helper a run should have reused is far
    # likelier to be a sibling of the file it is writing than a file picked by
    # where it happens to sort.
    cwd = os.path.realpath(".")
    dirs = set(os.path.dirname(os.path.realpath(t)) for t in targets)
    roots = set(os.path.relpath(os.path.realpath(t), cwd).split(os.sep)[0]
                for t in targets)

    def distance(path):
        absolute = os.path.realpath(path)
        directory = os.path.dirname(absolute)
        if directory in dirs:
            return 0
        if os.path.relpath(absolute, cwd).split(os.sep)[0] in roots:
            return 1
        return 2

    candidates.sort(key=lambda p: (distance(p), p))
    return candidates[:MAX_CORPUS]


def read_all(paths, lines_by_path, unreadable):
    for path in paths:
        lines = significant(path)
        if lines is None:
            unreadable.append(path)
        else:
            lines_by_path[path] = lines


def unique_paths(paths):
    """Preserve the caller's spelling while collapsing aliases of one file."""
    picked = []
    seen = set()
    for path in paths:
        identity = os.path.realpath(path)
        if identity not in seen:
            seen.add(identity)
            picked.append(path)
    return picked


def build_index(lines_by_path, tier, size):
    """digest -> [(path, window_index)] at one tier."""
    index = {}
    for path, lines in lines_by_path.items():
        for start, key in windows(lines, tier, size):
            index.setdefault(key, []).append((path, start))
    return index


def span(lines, start, length, size):
    """File line numbers covered by `length` windows starting at `start`."""
    return lines[start][0], lines[min(start + length + size - 2,
                                      len(lines) - 1)][0]


def find_clones(path, lines, index, tier, size):
    """Contiguous runs of matched windows, each extended as far as its partner
    follows along. Reporting per window would emit one finding per line of a
    forty-line copy; the run is the thing a reader wants to see."""
    findings = []
    run = None

    def close(run):
        if run:
            findings.append(run)
        return None

    for start, key in windows(lines, tier, size):
        matches = index.get(key, [])
        if len(set(other for other, _ in matches)) > UBIQUITY_MAX:
            run = close(run)
            continue
        elsewhere = [(other, index_of) for other, index_of in matches
                     if other != path or abs(index_of - start) >= size]
        if not elsewhere:
            run = close(run)
            continue
        if run and (run["partner"], run["partner_start"] + run["length"]) in elsewhere:
            run["length"] += 1
            continue
        run = close(run)
        partner, partner_start = sorted(elsewhere)[0]
        run = {"start": start, "length": 1,
               "partner": partner, "partner_start": partner_start}
    close(run)
    return findings


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

# `scan` names its files, so one that cannot be read is a caller error. `diff`
# derives them from git, where a deleted or renamed path is ordinary.
missing = [t for t in targets if not os.path.isfile(t)]
if missing and mode == "scan":
    for path in missing:
        print("duplication-scan: cannot read {}".format(path), file=sys.stderr)
    sys.exit(2)
targets = unique_paths([t for t in targets if os.path.isfile(t)])

unreadable = []
target_lines = {}
corpus_lines = {}
read_all(targets, target_lines, unreadable)
read_all(corpus_paths(targets), corpus_lines, unreadable)

everything = dict(target_lines)
everything.update(corpus_lines)


def touched(path, here, partner, there):
    """Diff mode reports only what the change put there. A clone whose every
    line predates the diff is the repository's existing debt -- real, but not
    this author's finding, and reporting it buries the one they can act on."""
    if added is None:
        return True
    spans = [(path, here)] + ([(partner, there)] if partner == path else [])
    return any(any(low <= n <= high for n in added.get(where, ()))
               for where, (low, high) in spans)


reported = set()
covered = {}        # path -> spans already reported verbatim, at any tier
findings = []

# Tier 1 first, so a block reported verbatim is never reported a second time as
# a shape. `duplicate=` is strictly more actionable than `similar=`: the reader
# does not have to work out what differs before deciding what to reuse.
for label, tier, size in (("duplicate", 1, MIN_LINES), ("similar", 2, SHAPE_LINES)):
    index = build_index(everything, tier, size)
    for path in sorted(target_lines):
        lines = target_lines[path]
        for clone in find_clones(path, lines, index, tier, size):
            partner = everything.get(clone["partner"])
            if not partner:
                continue
            here = span(lines, clone["start"], clone["length"], size)
            there = span(partner, clone["partner_start"], clone["length"], size)
            if not touched(path, here, clone["partner"], there):
                continue
            pair = tuple(sorted([(path,) + here, (clone["partner"],) + there]))
            if pair in reported:
                continue
            if any(low <= here[1] and here[0] <= high
                   for low, high in covered.get(path, ())):
                continue
            reported.add(pair)
            covered.setdefault(path, []).append(here)
            covered.setdefault(clone["partner"], []).append(there)
            findings.append((path, here, label, clone["length"] + size - 1,
                             clone["partner"], there))

for path, here, label, length, partner, there in sorted(findings):
    print("{}:{}-{}: {}={} lines: also at {}:{}-{}".format(
        path, here[0], here[1], label, length, partner, there[0], there[1]))

scope = "targets={} corpus={} window={}/{}".format(
    len(target_lines), len(corpus_lines), MIN_LINES, SHAPE_LINES)
if findings:
    print("duplication-scan: {} finding(s) {}".format(len(findings), scope))
    sys.exit(1)
print("duplication-scan: clean {}".format(scope))
PY
