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
# Two modes, because describing and judging are different questions:
#
#   probe    what conventions hold around here? Facts for an implementer, before
#            writing. The target is part of the sample -- that is correct here,
#            since the question is about the neighbourhood.
#   compare  does THIS file read like its neighbors? Findings for a reviewer,
#            after writing. The file under judgment is held out of its own
#            baseline, which `probe` cannot do and which changes the answer
#            completely: pooled in, a file that breaks every convention around it
#            reports AS the convention, because its deviation averages into the
#            baseline it is being measured against.
#
# `compare` is what makes the directive's severity rule real. "A deviation the
# probe measured is Important and blocks; taste is Minor" needs a probe that can
# actually name a deviation -- otherwise the reviewer is eyeballing it, which is
# the prose criterion this file exists to replace.
#
# Two rules keep compare honest. The baseline is per-target and same-extension:
# judging a .js file against the .sh files beside it reports camelCase as a
# deviation from snake_case, which is two languages rather than a violation. And
# embedded languages are skipped -- a shell heredoc or multi-line single-quoted
# string usually holds jq or Python, whose conventions are not the shell file's.
#
# Usage:
#   house-style.sh probe   <path> [path ...]   # facts about the neighbourhood
#   house-style.sh compare <file> [file ...]   # deviations of these files from it
#
# Output (probe): one fact per line, ANSWER first, then the evidence.
#   comment_density=sparse reason=12/430 comment lines (2.8%)
#   sample=4 files: lib/a.sh, lib/b.sh, ...
#
# Output (compare): one deviation per line, both sides measured.
#   src/orders.js: deviation=indent: file is spaces:4 (...); neighbors are spaces:2 (...)
#   house-style: 1 deviation(s) baseline=3 files
#
# Exit codes:
#   probe:   0 facts emitted | 1 no readable sample (answer unknown, do not guess)
#   compare: 0 clean | 1 deviations reported | 2 usage error / unreadable target
set -euo pipefail

case "${1:-}" in
  probe|compare) [[ $# -ge 2 ]] || { echo "usage: house-style.sh $1 <path> [path ...]" >&2; exit 2; } ;;
  *) echo "usage: house-style.sh <probe|compare> <path> [path ...]" >&2; exit 2 ;;
esac

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
SUPPORTED_EXTENSIONS = set(LINE_COMMENT).union(BLOCK_COMMENT)
QUOTED = {".py", ".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs", ".rb"}
SEMICOLON_LANGS = {".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs"}
MODULE_COMMONJS = re.compile(r"\brequire\s*\(|\bmodule\.exports\b|\bexports\.\w")
MODULE_ESM = re.compile(r"^(?:import\s|export\s|export\{|import\{)")

# A shell heredoc usually holds another language: this repo's scripts carry whole
# Python programs, jq programs, and test fixtures inside them. Measuring the
# shell file's conventions from that text answers about the wrong language --
# it is what reports jq's `def featsWithGap(g):` as camelCase creeping into a
# snake_case shell codebase.
SHELL_LANGS = {".sh", ".bash"}
HEREDOC_OPEN = re.compile(r"<<-?\s*[\"']?([A-Za-z_][A-Za-z0-9_]*)[\"']?")

# Definition syntax per language. Keyed on the extension because a single global
# regex reads another language's keyword as this file's definition -- jq's
# `def featsWithGap(g):` inside a shell heredoc-less `'...'` program matched the
# `def` branch and reported camelCase creeping into a snake_case shell codebase.
# Shell has no `def`; only `name()` and `function name` are definitions there.
SHELL_DEF = re.compile(r"^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{"
                       r"|^\s*function\s+([A-Za-z_][A-Za-z0-9_]*)\b")
JS_DEF = re.compile(
    r"^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s*\*?\s*([A-Za-z_][A-Za-z0-9_]*)\s*\("
    r"|^\s*(?:export\s+)?(?:public\s+|private\s+|protected\s+|static\s+|readonly\s+)*"
    r"(?:const|let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:async\s+)?(?:function\b|\([^)]*\)\s*=>|[A-Za-z_$][\w$]*\s*=>)"
    r"|^\s*(?:export\s+)?(?:abstract\s+)?(?:class|interface|type|enum)\s+([A-Za-z_][A-Za-z0-9_]*)")
PY_DEF = re.compile(r"^\s*(?:async\s+)?def\s+([A-Za-z_][A-Za-z0-9_]*)"
                    r"|^\s*class\s+([A-Za-z_][A-Za-z0-9_]*)")
GO_DEF = re.compile(r"^\s*func\s+(?:\([^)]*\)\s*)?([A-Za-z_][A-Za-z0-9_]*)\s*\("
                    r"|^\s*type\s+([A-Za-z_][A-Za-z0-9_]*)\b")
# The fallback for a language without its own entry -- Ruby, Rust, Java, Perl,
# and so on. It keeps `def` (Ruby/Perl methods): the jq-def-in-shell hazard that
# `def` used to cause is gone, because shell now uses SHELL_DEF and this fallback
# is never applied to a `.sh` file.
GENERIC_DEF = re.compile(
    r"^\s*(?:export\s+)?(?:async\s+)?(?:public\s+|private\s+|protected\s+|static\s+)*"
    r"(?:def|func|fn|class|interface|type|struct|impl|sub|module)\s+([A-Za-z_][A-Za-z0-9_]*)")

DEF_RE_BY_EXT = {
    ".sh": SHELL_DEF, ".bash": SHELL_DEF,
    ".py": PY_DEF,
    ".go": GO_DEF,
}
for _ext in (".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs"):
    DEF_RE_BY_EXT[_ext] = JS_DEF


def sample_paths(targets, widen=False):
    """Resolve targets to real files. A missing target is answered by its
    future neighbors -- same directory, same extension -- because that is the
    code it will have to sit beside. `widen` adds the neighbors of targets that
    DO exist, which is what rescues a freshly created file: three lines of its
    own demonstrate no convention, while the module around it demonstrates all
    of them."""
    picked = []
    seen = set()

    def add(path):
        if path not in seen and os.path.isfile(path):
            seen.add(path)
            picked.append(path)

    for target in targets:
        if os.path.isfile(target):
            add(target)
            if not widen:
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
        self.semi = 0
        self.no_semi = 0
        self.commonjs = 0
        self.esm = 0
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
    # Unknown languages contribute to the sample count but not to any style
    # axis. Guessing their comment, definition, or statement syntax would turn
    # the documented `unknown` answer into a blocking false positive.
    if ext not in SUPPORTED_EXTENSIONS:
        return

    def_re = DEF_RE_BY_EXT.get(ext, GENERIC_DEF)
    in_block = False
    previous_was_comment = False
    heredoc = None
    for raw in lines[:MAX_LINES]:
        line = raw.rstrip("\n")
        stripped = line.strip()

        # A shell heredoc holds another language -- this repo's scripts carry
        # whole Python and jq programs in them. Skip its body so the embedded
        # code does not set the shell file's style. (An embedded program passed
        # as a single-quoted `'...'` string is left in: tracking that state
        # across lines is defeated by any apostrophe in a comment, and the real
        # damage it did -- reading jq's `def` as a shell definition -- is now
        # prevented at the source by the per-language def regex above.)
        if heredoc is not None:
            if stripped == heredoc:
                heredoc = None
            continue
        if ext in SHELL_LANGS:
            opener = HEREDOC_OPEN.search(line)
            if opener:
                heredoc = opener.group(1)
                continue

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

        match = def_re.match(line)
        if match:
            name = next((g for g in match.groups() if g), None)
            if name:
                tally.defs.append(name)
                if previous_was_comment:
                    tally.documented += 1

        if ext in QUOTED:
            tally.single += len(re.findall(r"'[^'\n]*'", line))
            tally.double += len(re.findall(r'"[^"\n]*"', line))

        # Statement terminator and module system: two of the loudest tells that a
        # file was written somewhere else. Only lines that could carry a
        # semicolon are counted -- a block opener or a continuation says nothing.
        if ext in SEMICOLON_LANGS:
            if stripped[-1:] in ";":
                tally.semi += 1
            elif stripped[-1:] not in "{}([,:+-&|?`":
                tally.no_semi += 1
            if MODULE_COMMONJS.search(stripped):
                tally.commonjs += 1
            elif MODULE_ESM.match(stripped):
                tally.esm += 1
        previous_was_comment = False


def classify_name(name):
    if "_" in name:
        return "snake_case"
    if name[:1].isupper():
        return "PascalCase"
    if any(c.isupper() for c in name):
        return "camelCase"
    return "lowercase"


def name_conflicts(name, convention):
    """A single-word name (`checkout`) is valid under every convention, and
    PascalCase is how most languages spell a class even where functions are
    camelCase. Only the unambiguous crossover is a deviation: an underscore where
    the neighbors never use one, or an interior capital where they always do."""
    style = classify_name(name)
    if style in ("lowercase", "PascalCase"):
        return False
    if convention == "snake_case":
        return style == "camelCase"
    if convention in ("camelCase", "PascalCase"):
        return style == "snake_case"
    return False


def majority(counts, floor=3):
    """Winner and its share, or (None, ...) when the evidence is too thin.
    Fail safe: a convention nobody demonstrated is not a convention."""
    total = sum(counts.values())
    if total < floor:
        return None, 0, total
    winner = max(counts, key=lambda k: counts[k])
    return winner, counts[winner], total


MIN_LINES = 20       # below this, every answer would be "unknown"


def measure(paths):
    tally = Tally()
    for path in paths:
        scan(path, tally)
    return tally


def read_axes(tally):
    """axis -> (answer, reason). Every axis reports, `unknown` included: the
    caller has to be able to tell "the neighbors do X" from "nobody showed me"."""
    axes = {}

    total_lines = tally.code + tally.comment
    if total_lines >= 20:
        pct = 100.0 * tally.comment / total_lines
        density = "sparse" if pct < 5 else ("moderate" if pct <= 15 else "heavy")
        axes["comment_density"] = (density, "{}/{} comment lines ({:.1f}%)".format(
            tally.comment, total_lines, pct))
    else:
        axes["comment_density"] = (
            "unknown", "only {} code+comment lines sampled".format(total_lines))

    if len(tally.defs) >= 3:
        share = 100.0 * tally.documented / len(tally.defs)
        answer = "yes" if share >= 70 else ("no" if share <= 30 else "mixed")
        axes["doc_comments"] = (answer, "{}/{} definitions carry a preceding comment ({:.0f}%)".format(
            tally.documented, len(tally.defs), share))
    else:
        axes["doc_comments"] = (
            "unknown", "only {} definitions sampled".format(len(tally.defs)))

    if tally.tabs > tally.spaces and tally.tabs >= 3:
        axes["indent"] = ("tabs", "{} tab-indented vs {} space-indented lines".format(
            tally.tabs, tally.spaces))
    elif tally.spaces >= 3:
        steps = [w for w in tally.indent_widths if w > 0]
        width = min(steps) if steps else 0
        axes["indent"] = ("spaces:{}".format(width),
                          "smallest indent step across {} indented lines".format(tally.spaces))
    else:
        axes["indent"] = ("unknown", "too few indented lines sampled")

    if tally.defs:
        styles = {}
        for name in tally.defs:
            style = classify_name(name)
            styles[style] = styles.get(style, 0) + 1
        winner, hits, total = majority(styles)
        if winner and hits * 2 > total:
            axes["naming"] = (winner, "{}/{} sampled definition names".format(hits, total))
        else:
            axes["naming"] = ("mixed", "no majority across {} definition names".format(total))
    else:
        axes["naming"] = ("unknown", "no definitions sampled")

    if tally.lengths:
        ordered = sorted(tally.lengths)
        p90 = ordered[min(len(ordered) - 1, int(0.9 * len(ordered)))]
        axes["line_length"] = ("p90:{} max:{}".format(p90, ordered[-1]),
                               "{} sampled lines".format(len(ordered)))

    if tally.single + tally.double >= 10:
        answer = "single" if tally.single > 2 * tally.double else (
            "double" if tally.double > 2 * tally.single else "mixed")
        axes["quotes"] = (answer, "{} single vs {} double quoted spans".format(
            tally.single, tally.double))

    if tally.semi + tally.no_semi >= 10:
        answer = ("yes" if tally.semi > 2 * tally.no_semi else
                  "no" if tally.no_semi > 2 * tally.semi else "mixed")
        axes["semicolons"] = (answer, "{} terminated vs {} bare statement lines".format(
            tally.semi, tally.no_semi))

    if tally.commonjs + tally.esm >= 2:
        answer = ("commonjs" if tally.commonjs > tally.esm else
                  "esm" if tally.esm > tally.commonjs else "mixed")
        axes["module_style"] = (answer, "{} commonjs vs {} esm statements".format(
            tally.commonjs, tally.esm))

    return axes


def measure_with_fallback(targets, widen=False):
    """A target that exists but is nearly empty demonstrates nothing. Widening to
    its neighbors answers from the module instead of shrugging -- the same
    fallback a not-yet-created target already gets."""
    tally = measure(sample_paths(targets, widen=widen))
    if tally.code + tally.comment < MIN_LINES:
        widened = measure(sample_paths(targets, widen=True))
        if widened.code + widened.comment > tally.code + tally.comment:
            return widened
    return tally


# Axes where a difference is a deviation. Deliberately excluded: line_length is a
# distribution rather than a convention (two files honouring the same limit rarely
# share a p90), and comment_density and doc_comments are ratios the directive
# already judges against the file's own budget rather than as a categorical match
# -- one documented helper in a five-definition file swings the ratio 20 points.
COMPARABLE = ("indent", "naming", "quotes", "semicolons", "module_style")
UNDEMONSTRATED = ("unknown", "mixed")

mode, targets = sys.argv[1], sys.argv[2:]

if mode == "probe":
    tally = measure_with_fallback(targets)
    if not tally.readable:
        print("sample=none reason=no readable file or neighbor for: {}".format(", ".join(targets)))
        sys.exit(1)
    axes = read_axes(tally)
    for axis in ("comment_density", "doc_comments", "indent", "naming",
                 "line_length", "quotes", "semicolons", "module_style"):
        if axis in axes:
            answer, reason = axes[axis]
            print("{}={} reason={}".format(axis, answer, reason))
    print("sample={} files: {}".format(len(tally.readable), ", ".join(tally.readable)))
    sys.exit(0)

# compare: the baseline is the neighbors WITHOUT the targets in it. Pooling a
# target into the convention it is being judged against is how a file that
# breaks every rule reports as the rule -- the deviation averages into its own
# baseline and disappears.
existing = [t for t in targets if os.path.isfile(t)]
if not existing:
    print("house-style: no readable target: {}".format(", ".join(targets)), file=sys.stderr)
    sys.exit(2)

# One baseline per target, built from ITS OWN language's neighbors. A pooled
# baseline judges a .js file against the .sh files beside it and reports camelCase
# as a deviation from snake_case, which is not a convention violation but two
# languages.
#
# Only the file under judgment is held out, not every target in the batch. Holding
# out all of them empties the baseline exactly when a diff touches most of a small
# module -- and a file the diff merely edited is still established code. The cost
# is that a pair of brand-new siblings written in the same wrong style validate
# each other, which is the honest answer anyway: inside a module with no prior
# code there is no convention yet to deviate from.
findings = []
baseline_files = set()
skipped = []
for target in sorted(existing):
    neighbors = [p for p in sample_paths([target], widen=True)
                 if os.path.normpath(p) != os.path.normpath(target)]
    baseline_tally = measure(neighbors)
    if not baseline_tally.readable:
        skipped.append(target)
        continue
    baseline_files.update(baseline_tally.readable)
    baseline = read_axes(baseline_tally)

    mine_tally = measure([target])
    mine = read_axes(mine_tally)

    # Naming is checked name by name rather than by the file's own majority: one
    # snake_case function in a camelCase module is the deviation, and a majority
    # vote over a file holding a single definition can never see it.
    want_naming = baseline.get("naming")
    if want_naming and want_naming[0] not in UNDEMONSTRATED:
        off = [n for n in mine_tally.defs if name_conflicts(n, want_naming[0])]
        if off:
            findings.append((target, "naming",
                             (classify_name(off[0]), "names: " + ", ".join(sorted(set(off))[:5])),
                             want_naming))

    for axis in COMPARABLE:
        if axis == "naming":
            continue
        want = baseline.get(axis)
        got = mine.get(axis)
        if not want or not got:
            continue
        if want[0] in UNDEMONSTRATED or got[0] in UNDEMONSTRATED:
            continue
        if want[0] != got[0]:
            findings.append((target, axis, got, want))

for target, axis, got, want in findings:
    print("{}: deviation={}: file is {} ({}); neighbors are {} ({})".format(
        target, axis, got[0], got[1], want[0], want[1]))

scope = "baseline={} files".format(len(baseline_files))
if skipped:
    scope += " (no same-language neighbor for: {})".format(", ".join(sorted(skipped)))
if findings:
    print("house-style: {} deviation(s) {}".format(len(findings), scope))
    sys.exit(1)
print("house-style: matches its neighbors {}".format(scope))
PY
