"""Deterministic probes: facts about a change, ported from the M0-era lib/*.sh tools.

Use `plan_probes` at PLAN entry (house style, duplication, indirection, security
signals, the dependencies the named files import) and `diff_probes`/`range_probes` at EXECUTE/VERIFY
(comment/failure/doc tells, indirection delta, duplication, house-style deviation) to
hand a phase measured facts instead of judgment calls a fresh context cannot make
reliably. Every probe here fails safe (an unreadable or unknown-language input shrinks
the answer, never guesses) and returns data; none of them choose a route.

Only "scan" (whole-file) semantics are ported from the shell tools' scan/diff pair:
the M1 aggregators name their own file list (`git diff --name-only`) and scan those
files whole, so the line-level "added lines only" filtering the shell diff mode did
via diff-added-lines.py is not needed here and was not ported.

simplicity: several small ported helpers (a line's shape, a window's digest, one
...) read as single-caller wrappers to
indirection-scan, because dropping "diff" mode above removed what was each one's
SECOND caller in its original script; the name still earns its place as a unit a
reader can check against the original tool. Not a ceiling to raise later -- this is
what porting nine independently-shaped tools into one module looks like.
"""
import hashlib
import json
import os
import re
import tomllib
from pathlib import Path

from loop_spec import repo as repo_module


def _resolve_all(root: Path, files: list[str]) -> list[str]:
    root = Path(root)
    return [str(p if p.is_absolute() else root / p) for p in (Path(f) for f in files)]


def _env_int_with_floor(env_var: str, floor: int, default: int) -> int:
    """Operator override outranks the default; anything unreadable falls back rather
    than running with a degenerate limit (shared by duplication-scan and
    indirection-scan, whose shell originals each had their own copy of this)."""
    raw = os.environ.get(env_var, "")
    try:
        return max(floor, int(raw))
    except ValueError:
        return default


def _tracked_or_walked_files(root) -> list[str]:
    """Every file `git ls-files` tracks under `root`, or a directory walk when
    `root` is not a git work tree -- the corpus duplication-scan and
    indirection-scan both compare a target's definitions/lines against."""
    proc = repo_module._git(root, "ls-files", "-z")
    if proc.returncode == 0:
        return [str(Path(root) / p) for p in proc.stdout.split("\0") if p]
    listing = []
    for base, dirs, names in os.walk(root):
        dirs[:] = [d for d in dirs if not d.startswith(".") and d not in ("node_modules", "vendor", "dist", "build")]
        listing.extend(os.path.join(base, n) for n in names)
    return listing


# Comment syntax per extension, shared by duplication-scan and comment-tells (their
# shell originals each carried an identical copy of this table).
_COMMENT_PREFIX_HASH = ("#",)
_COMMENT_PREFIX_SLASH = ("//", "/*", "*")
_COMMENT_PREFIX_BY_EXT = {
    ".py": _COMMENT_PREFIX_HASH, ".sh": _COMMENT_PREFIX_HASH, ".bash": _COMMENT_PREFIX_HASH,
    ".rb": _COMMENT_PREFIX_HASH, ".pl": _COMMENT_PREFIX_HASH,
    ".yml": _COMMENT_PREFIX_HASH, ".yaml": _COMMENT_PREFIX_HASH, ".toml": _COMMENT_PREFIX_HASH,
    ".tf": _COMMENT_PREFIX_HASH, ".ex": _COMMENT_PREFIX_HASH, ".exs": _COMMENT_PREFIX_HASH, ".r": _COMMENT_PREFIX_HASH,
    ".js": _COMMENT_PREFIX_SLASH, ".jsx": _COMMENT_PREFIX_SLASH, ".ts": _COMMENT_PREFIX_SLASH,
    ".tsx": _COMMENT_PREFIX_SLASH, ".mjs": _COMMENT_PREFIX_SLASH, ".cjs": _COMMENT_PREFIX_SLASH,
    ".go": _COMMENT_PREFIX_SLASH, ".java": _COMMENT_PREFIX_SLASH, ".c": _COMMENT_PREFIX_SLASH,
    ".h": _COMMENT_PREFIX_SLASH, ".cc": _COMMENT_PREFIX_SLASH, ".cpp": _COMMENT_PREFIX_SLASH,
    ".hpp": _COMMENT_PREFIX_SLASH, ".cs": _COMMENT_PREFIX_SLASH, ".rs": _COMMENT_PREFIX_SLASH,
    ".swift": _COMMENT_PREFIX_SLASH, ".kt": _COMMENT_PREFIX_SLASH, ".scala": _COMMENT_PREFIX_SLASH,
    ".php": _COMMENT_PREFIX_SLASH + _COMMENT_PREFIX_HASH,
    ".css": ("/*", "*"), ".scss": _COMMENT_PREFIX_SLASH,
    ".sql": ("--",), ".lua": ("--",), ".hs": ("--",),
}


# =============================================================================
# house-style: what conventions hold around a target, and does a file deviate?
# Port of lib/house-style.sh (already an embedded Python program).
# =============================================================================

_HS_MAX_FILES = 12
_HS_MAX_LINES = 6000

_HS_LINE_COMMENT = {
    ".py": ["#"], ".sh": ["#"], ".bash": ["#"], ".rb": ["#"], ".pl": ["#"],
    ".yml": ["#"], ".yaml": ["#"], ".toml": ["#"], ".tf": ["#"], ".r": ["#"],
    ".js": ["//"], ".jsx": ["//"], ".ts": ["//"], ".tsx": ["//"], ".mjs": ["//"],
    ".cjs": ["//"], ".go": ["//"], ".java": ["//"], ".c": ["//"], ".h": ["//"],
    ".cc": ["//"], ".cpp": ["//"], ".hpp": ["//"], ".cs": ["//"], ".rs": ["//"],
    ".swift": ["//"], ".kt": ["//"], ".scala": ["//"], ".php": ["//", "#"],
    ".sql": ["--"], ".lua": ["--"], ".hs": ["--"], ".ex": ["#"], ".exs": ["#"],
}
_HS_BLOCK_COMMENT = {
    ".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs", ".go", ".java",
    ".c", ".h", ".cc", ".cpp", ".hpp", ".cs", ".rs", ".swift",
    ".kt", ".scala", ".php", ".css", ".scss",
}
_HS_SUPPORTED_EXTENSIONS = set(_HS_LINE_COMMENT).union(_HS_BLOCK_COMMENT)
_HS_QUOTED = {".py", ".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs", ".rb"}
_HS_SEMICOLON_LANGS = {".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs"}
_HS_MODULE_COMMONJS = re.compile(r"\brequire\s*\(|\bmodule\.exports\b|\bexports\.\w")
_HS_MODULE_ESM = re.compile(r"^(?:import\s|export\s|export\{|import\{)")

_HS_SHELL_LANGS = {".sh", ".bash"}
_HS_HEREDOC_OPEN = re.compile(r"<<-?\s*[\"']?([A-Za-z_][A-Za-z0-9_]*)[\"']?")

_HS_SHELL_DEF = re.compile(
    r"^\s*(?:function\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{"
    r"|^\s*function\s+([A-Za-z_][A-Za-z0-9_]*)\b"
)
_HS_JS_DEF = re.compile(
    r"^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s*\*?\s*([A-Za-z_][A-Za-z0-9_]*)\s*\("
    r"|^\s*(?:export\s+)?(?:public\s+|private\s+|protected\s+|static\s+|readonly\s+)*"
    r"(?:const|let|var)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?:async\s+)?(?:function\b|\([^)]*\)\s*=>|[A-Za-z_$][\w$]*\s*=>)"
    r"|^\s*(?:export\s+)?(?:abstract\s+)?(?:class|interface|type|enum)\s+([A-Za-z_][A-Za-z0-9_]*)"
)
_HS_PY_DEF = re.compile(
    r"^\s*(?:async\s+)?def\s+([A-Za-z_][A-Za-z0-9_]*)"
    r"|^\s*class\s+([A-Za-z_][A-Za-z0-9_]*)"
)
_HS_GO_DEF = re.compile(
    r"^\s*func\s+(?:\([^)]*\)\s*)?([A-Za-z_][A-Za-z0-9_]*)\s*\("
    r"|^\s*type\s+([A-Za-z_][A-Za-z0-9_]*)\b"
)
_HS_GENERIC_DEF = re.compile(
    r"^\s*(?:export\s+)?(?:async\s+)?(?:public\s+|private\s+|protected\s+|static\s+)*"
    r"(?:def|func|fn|class|interface|type|struct|impl|sub|module)\s+([A-Za-z_][A-Za-z0-9_]*)"
)
_HS_DEF_RE_BY_EXT = {".sh": _HS_SHELL_DEF, ".bash": _HS_SHELL_DEF, ".py": _HS_PY_DEF, ".go": _HS_GO_DEF}
for _hs_ext in (".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs"):
    _HS_DEF_RE_BY_EXT[_hs_ext] = _HS_JS_DEF


def _hs_sample_paths(targets, widen=False):
    """Resolve targets to real files. A missing target is answered by its future
    neighbors -- same directory, same extension; `widen` adds the neighbors of an
    existing target too, which is what rescues a freshly created file."""
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
    return picked[:_HS_MAX_FILES]


class _HsTally:
    def __init__(self):
        self.code = 0
        self.comment = 0
        self.tabs = 0
        self.spaces = 0
        self.indent_widths = {}
        self.indent_sequence = []
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


def _hs_scan(path, tally):
    ext = os.path.splitext(path)[1].lower()
    prefixes = _HS_LINE_COMMENT.get(ext)
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            lines = handle.readlines()
    except OSError:
        return
    if not lines:
        return
    tally.readable.append(path)
    if ext not in _HS_SUPPORTED_EXTENSIONS:
        return

    def_re = _HS_DEF_RE_BY_EXT.get(ext, _HS_GENERIC_DEF)
    in_block = False
    previous_was_comment = False
    heredoc = None
    in_string = False
    if tally.indent_sequence:
        tally.indent_sequence.append(None)
    for raw in lines[:_HS_MAX_LINES]:
        line = raw.rstrip("\n")
        stripped = line.strip()

        if heredoc is not None:
            if stripped == heredoc:
                heredoc = None
            continue
        if ext in _HS_SHELL_LANGS:
            opener = _HS_HEREDOC_OPEN.search(line)
            if opener:
                heredoc = opener.group(1)
                continue

        if ext == ".py":
            triple_count = stripped.count('"""') + stripped.count("'''")
            if in_string:
                if triple_count % 2 == 1:
                    in_string = False
                continue
            if triple_count % 2 == 1:
                in_string = True
                continue

        if not stripped:
            previous_was_comment = False
            continue
        tally.lengths.append(len(line))

        is_comment = False
        if ext in _HS_BLOCK_COMMENT:
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
            tally.indent_sequence.append(width)
        else:
            tally.indent_sequence.append(0)

        match = def_re.match(line)
        if match:
            name = next((g for g in match.groups() if g), None)
            if name:
                tally.defs.append(name)
                if previous_was_comment:
                    tally.documented += 1

        if ext in _HS_QUOTED:
            tally.single += len(re.findall(r"'[^'\n]*'", line))
            tally.double += len(re.findall(r'"[^"\n]*"', line))

        if ext in _HS_SEMICOLON_LANGS:
            if stripped[-1:] in ";":
                tally.semi += 1
            elif stripped[-1:] not in "{}([,:+-&|?`":
                tally.no_semi += 1
            if _HS_MODULE_COMMONJS.search(stripped):
                tally.commonjs += 1
            elif _HS_MODULE_ESM.match(stripped):
                tally.esm += 1
        previous_was_comment = False


def _hs_classify_name(name):
    if "_" in name:
        return "snake_case"
    if name[:1].isupper():
        return "PascalCase"
    if any(c.isupper() for c in name):
        return "camelCase"
    return "lowercase"


def _hs_name_conflicts(name, convention):
    style = _hs_classify_name(name)
    if style in ("lowercase", "PascalCase"):
        return False
    if convention == "snake_case":
        return style == "camelCase"
    if convention in ("camelCase", "PascalCase"):
        return style == "snake_case"
    return False


def _hs_majority(counts, floor=3):
    total = sum(counts.values())
    if total < floor:
        return None, 0, total
    winner = max(counts, key=lambda k: counts[k])
    return winner, counts[winner], total


_HS_MIN_LINES = 20


def _hs_measure(paths):
    tally = _HsTally()
    for path in paths:
        _hs_scan(path, tally)
    return tally


def _hs_read_axes(tally):
    axes = {}

    total_lines = tally.code + tally.comment
    if total_lines >= 20:
        pct = 100.0 * tally.comment / total_lines
        density = "sparse" if pct < 5 else ("moderate" if pct <= 15 else "heavy")
        axes["comment_density"] = (density, "{}/{} comment lines ({:.1f}%)".format(tally.comment, total_lines, pct))
    else:
        axes["comment_density"] = ("unknown", "only {} code+comment lines sampled".format(total_lines))

    if len(tally.defs) >= 3:
        share = 100.0 * tally.documented / len(tally.defs)
        answer = "yes" if share >= 70 else ("no" if share <= 30 else "mixed")
        axes["doc_comments"] = (answer, "{}/{} definitions carry a preceding comment ({:.0f}%)".format(
            tally.documented, len(tally.defs), share))
    else:
        axes["doc_comments"] = ("unknown", "only {} definitions sampled".format(len(tally.defs)))

    if tally.tabs > tally.spaces and tally.tabs >= 3:
        axes["indent"] = ("tabs", "{} tab-indented vs {} space-indented lines".format(tally.tabs, tally.spaces))
    elif tally.spaces >= 3:
        deltas = {}
        previous_width = None
        for current_width in tally.indent_sequence:
            if current_width is None:
                previous_width = None
                continue
            if previous_width is not None and current_width != previous_width:
                delta = abs(current_width - previous_width)
                deltas[delta] = deltas.get(delta, 0) + 1
            previous_width = current_width
        if deltas:
            most = max(deltas.values())
            width = min(d for d, count in deltas.items() if count == most)
            axes["indent"] = ("spaces:{}".format(width), "most common indent step across {} indented lines".format(tally.spaces))
        else:
            steps = [w for w in tally.indent_widths if w > 0]
            width = min(steps) if steps else 0
            axes["indent"] = ("spaces:{}".format(width), "smallest indent step across {} indented lines".format(tally.spaces))
    else:
        axes["indent"] = ("unknown", "too few indented lines sampled")

    if tally.defs:
        styles = {}
        for name in tally.defs:
            style = _hs_classify_name(name)
            styles[style] = styles.get(style, 0) + 1
        winner, hits, total = _hs_majority(styles)
        if winner and hits * 2 > total:
            axes["naming"] = (winner, "{}/{} sampled definition names".format(hits, total))
        else:
            axes["naming"] = ("mixed", "no majority across {} definition names".format(total))
    else:
        axes["naming"] = ("unknown", "no definitions sampled")

    if tally.lengths:
        ordered = sorted(tally.lengths)
        p90 = ordered[min(len(ordered) - 1, int(0.9 * len(ordered)))]
        axes["line_length"] = ("p90:{} max:{}".format(p90, ordered[-1]), "{} sampled lines".format(len(ordered)))

    if tally.single + tally.double >= 10:
        answer = "single" if tally.single > 2 * tally.double else ("double" if tally.double > 2 * tally.single else "mixed")
        axes["quotes"] = (answer, "{} single vs {} double quoted spans".format(tally.single, tally.double))

    if tally.semi + tally.no_semi >= 10:
        answer = "yes" if tally.semi > 2 * tally.no_semi else ("no" if tally.no_semi > 2 * tally.semi else "mixed")
        axes["semicolons"] = (answer, "{} terminated vs {} bare statement lines".format(tally.semi, tally.no_semi))

    if tally.commonjs + tally.esm >= 2:
        answer = "commonjs" if tally.commonjs > tally.esm else ("esm" if tally.esm > tally.commonjs else "mixed")
        axes["module_style"] = (answer, "{} commonjs vs {} esm statements".format(tally.commonjs, tally.esm))

    return axes


def _hs_measure_with_fallback(targets, widen=False):
    tally = _hs_measure(_hs_sample_paths(targets, widen=widen))
    if tally.code + tally.comment < _HS_MIN_LINES:
        widened = _hs_measure(_hs_sample_paths(targets, widen=True))
        if widened.code + widened.comment > tally.code + tally.comment:
            return widened
    return tally


_HS_COMPARABLE = ("indent", "naming", "quotes", "semicolons", "module_style")
_HS_UNDEMONSTRATED = ("unknown", "mixed")


def house_style_probe(root: Path, files: list[str]) -> dict:
    """Facts about the neighbourhood of `files`: comment density, indent, naming,
    quote/semicolon/module style. The targets are part of their own sample -- correct
    here, since the question is about the neighbourhood, not about one file's fit."""
    targets = _resolve_all(root, files)
    tally = _hs_measure_with_fallback(targets)
    if not tally.readable:
        return {"sample": [], "reason": "no readable file or neighbor for: " + ", ".join(files)}
    axes = _hs_read_axes(tally)
    return {
        "sample": list(tally.readable),
        "axes": {name: {"answer": answer, "reason": reason} for name, (answer, reason) in axes.items()},
    }


def house_style_compare(root: Path, files: list[str]) -> list[dict]:
    """Deviations of each file in `files` from ITS OWN language's neighbors, with the
    file itself held out of its own baseline (see lib/house-style.sh for why pooling
    it in hides the exact deviation this is meant to catch)."""
    targets = _resolve_all(root, files)
    existing = [t for t in targets if os.path.isfile(t)]
    if not existing:
        return []

    findings = []
    for target in sorted(existing):
        neighbors = [p for p in _hs_sample_paths([target], widen=True) if os.path.normpath(p) != os.path.normpath(target)]
        baseline_tally = _hs_measure(neighbors)
        if not baseline_tally.readable:
            continue
        baseline = _hs_read_axes(baseline_tally)

        mine_tally = _hs_measure([target])
        mine = _hs_read_axes(mine_tally)

        want_naming = baseline.get("naming")
        if want_naming and want_naming[0] not in _HS_UNDEMONSTRATED:
            off = [n for n in mine_tally.defs if _hs_name_conflicts(n, want_naming[0])]
            if off:
                findings.append({
                    "file": target, "axis": "naming",
                    "got": {"answer": _hs_classify_name(off[0]), "reason": "names: " + ", ".join(sorted(set(off))[:5])},
                    "want": {"answer": want_naming[0], "reason": want_naming[1]},
                })

        for axis in _HS_COMPARABLE:
            if axis == "naming":
                continue
            want = baseline.get(axis)
            got = mine.get(axis)
            if not want or not got:
                continue
            if want[0] in _HS_UNDEMONSTRATED or got[0] in _HS_UNDEMONSTRATED:
                continue
            if want[0] != got[0]:
                findings.append({
                    "file": target, "axis": axis,
                    "got": {"answer": got[0], "reason": got[1]},
                    "want": {"answer": want[0], "reason": want[1]},
                })
    return findings


# =============================================================================
# duplication-scan: verbatim and shape clones, target files vs each other and a
# tracked-file corpus. Port of lib/duplication-scan.sh's "scan" mode only -- the
# "diff" mode's added-lines filtering is an aggregator concern here (see module
# docstring).
# =============================================================================

_DUP_MAX_CORPUS = 600
_DUP_MAX_LINES = 5000
_DUP_UBIQUITY_MAX = 6
_DUP_DEFAULT_MIN_LINES = 6


def _dup_window_size():
    return _env_int_with_floor("LOOP_SPEC_DUP_MIN_LINES", 3, _DUP_DEFAULT_MIN_LINES)


_DUP_GENERATED_FILE = re.compile(r"@generated\b|\bdo not edit\b|\bcode generated by\b|\bauto-?generated\b", re.I)
_DUP_REGION_OPEN = re.compile(r"@(?:inject|generated|codegen)\b(?!:end)", re.I)
_DUP_REGION_CLOSE = re.compile(r"@(?:inject|generated|codegen):end\b", re.I)
_DUP_STRUCTURAL = re.compile(
    r"^(?:[)}\]{(;,]|\.\.\.)+$"
    r"|^(?:fi|done|esac|end|else|do|then|return|break|continue|pass|"
    r"</\w+>|};?|\)\s*;?|\]\s*,?|\{)$",
    re.I,
)
_DUP_WHITESPACE = re.compile(r"\s+")

_DUP_KEYWORDS = frozenset("""
and as async await bool break by case catch class const continue declare def default
defer del delete do done elif else elsif end enum esac eval except export extends fi
final finally float for foreach from func function global go if impl implements import
in include input instanceof int interface is lambda let local match mod module mut new
nil none not null of or package pass print printf private protected public raise readonly
require rescue return select self set static string struct super switch then this throw
throws trait true false try type typedef typeof unset use using val var void when where
while with yield echo local source exit test then
""".split())
_DUP_IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
_DUP_NUMBER = re.compile(r"\b\d+(?:\.\d+)?\b")
_DUP_STRING = re.compile(r"""'(?:[^'\\]|\\.)*'|"(?:[^"\\]|\\.)*\"""")


def _dup_shape(text):
    text = _DUP_STRING.sub('""', text)
    text = _DUP_NUMBER.sub("0", text)
    return _DUP_IDENTIFIER.sub(lambda m: m.group(0) if m.group(0).lower() in _DUP_KEYWORDS else "V", text)


def _dup_significant(path):
    prefixes = _COMMENT_PREFIX_BY_EXT.get(os.path.splitext(path)[1].lower())
    if not prefixes:
        return []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            raw = handle.read().splitlines()[:_DUP_MAX_LINES]
    except OSError:
        return None

    if any(_DUP_GENERATED_FILE.search(line) for line in raw[:20]):
        return []

    kept = []
    generated = False
    for lineno, line in enumerate(raw, 1):
        text = line.strip()
        if not text:
            continue
        if prefixes and text.startswith(prefixes):
            if _DUP_REGION_CLOSE.search(text):
                generated = False
            elif _DUP_REGION_OPEN.search(text):
                generated = True
            continue
        if generated or _DUP_STRUCTURAL.match(text):
            continue
        collapsed = _DUP_WHITESPACE.sub(" ", text)
        kept.append((lineno, collapsed, _dup_shape(collapsed)))
    return kept


def _dup_digest(window):
    return hashlib.sha1("\n".join(window).encode("utf-8")).digest()


def _dup_windows(lines, tier, size):
    texts = [row[tier] for row in lines]
    for start in range(0, len(texts) - size + 1):
        chunk = texts[start:start + size]
        if len(set(chunk)) * 2 < size:
            continue
        yield start, _dup_digest(chunk)


def _dup_corpus_paths(root, targets):
    wanted = set(os.path.splitext(t)[1].lower() for t in targets)
    wanted.discard("")
    if not wanted:
        return []

    listing = _tracked_or_walked_files(root)

    seen = set(os.path.realpath(t) for t in targets)
    candidates = [
        path for path in listing
        if os.path.splitext(path)[1].lower() in wanted
        and os.path.realpath(path) not in seen
        and os.path.isfile(path)
    ]

    cwd = os.path.realpath(root)
    dirs_of_targets = set(os.path.dirname(os.path.realpath(t)) for t in targets)
    roots_of_targets = set(os.path.relpath(os.path.realpath(t), cwd).split(os.sep)[0] for t in targets)

    def distance(path):
        absolute = os.path.realpath(path)
        directory = os.path.dirname(absolute)
        if directory in dirs_of_targets:
            return 0
        if os.path.relpath(absolute, cwd).split(os.sep)[0] in roots_of_targets:
            return 1
        return 2

    candidates.sort(key=lambda p: (distance(p), p))
    return candidates[:_DUP_MAX_CORPUS]


def _dup_read_all(paths, lines_by_path, unreadable):
    for path in paths:
        lines = _dup_significant(path)
        if lines is None:
            unreadable.append(path)
        else:
            lines_by_path[path] = lines


def _dup_unique_paths(paths):
    picked = []
    seen = set()
    for path in paths:
        identity = os.path.realpath(path)
        if identity not in seen:
            seen.add(identity)
            picked.append(path)
    return picked


def _dup_build_index(lines_by_path, tier, size):
    index = {}
    for path, lines in lines_by_path.items():
        for start, key in _dup_windows(lines, tier, size):
            index.setdefault(key, []).append((path, start))
    return index


def _dup_span(lines, start, length, size):
    return lines[start][0], lines[min(start + length + size - 2, len(lines) - 1)][0]


def _dup_find_clones(path, lines, index, tier, size):
    findings = []
    run = None

    def close(run):
        if run:
            findings.append(run)
        return None

    for start, key in _dup_windows(lines, tier, size):
        matches = index.get(key, [])
        if len(set(other for other, _ in matches)) > _DUP_UBIQUITY_MAX:
            run = close(run)
            continue
        elsewhere = [(other, index_of) for other, index_of in matches if other != path or abs(index_of - start) >= size]
        if not elsewhere:
            run = close(run)
            continue
        if run and (run["partner"], run["partner_start"] + run["length"]) in elsewhere:
            run["length"] += 1
            continue
        run = close(run)
        partner, partner_start = sorted(elsewhere)[0]
        run = {"start": start, "length": 1, "partner": partner, "partner_start": partner_start}
    close(run)
    return findings


def duplication_scan(root: Path, files: list[str]) -> list[dict]:
    """Verbatim (`duplicate`) and renamed-identifier (`similar`) clones of `files`
    against each other and against the repo's tracked files of the same extension."""
    root = Path(root)
    min_lines = _dup_window_size()
    shape_lines = min_lines + 2

    targets = _dup_unique_paths([t for t in _resolve_all(root, files) if os.path.isfile(t)])
    if not targets:
        return []

    unreadable = []
    target_lines = {}
    corpus_lines = {}
    _dup_read_all(targets, target_lines, unreadable)
    _dup_read_all(_dup_corpus_paths(root, targets), corpus_lines, unreadable)

    everything = dict(target_lines)
    everything.update(corpus_lines)

    reported = set()
    covered = {}
    findings = []
    for label, tier, size in (("duplicate", 1, min_lines), ("similar", 2, shape_lines)):
        index = _dup_build_index(everything, tier, size)
        for path in sorted(target_lines):
            lines = target_lines[path]
            for clone in _dup_find_clones(path, lines, index, tier, size):
                partner = everything.get(clone["partner"])
                if not partner:
                    continue
                here = _dup_span(lines, clone["start"], clone["length"], size)
                there = _dup_span(partner, clone["partner_start"], clone["length"], size)
                pair = tuple(sorted([(path,) + here, (clone["partner"],) + there]))
                if pair in reported:
                    continue
                if any(low <= here[1] and here[0] <= high for low, high in covered.get(path, ())):
                    continue
                reported.add(pair)
                covered.setdefault(path, []).append(here)
                covered.setdefault(clone["partner"], []).append(there)
                findings.append({
                    "file": path, "from": here[0], "to": here[1], "kind": label,
                    "lines": clone["length"] + size - 1,
                    "partnerFile": clone["partner"], "partnerFrom": there[0], "partnerTo": there[1],
                })
    return findings


# =============================================================================
# indirection-scan: a private, small, single-caller definition the change added.
# Port of lib/indirection-scan.sh's "scan" mode. `layers` (not in the shell tool)
# is the count of such findings in `files` as given -- a baseline snapshot the
# diff/range aggregators compare a later count against (see module docstring).
# =============================================================================

_IND_MAX_CORPUS = 600
_IND_MAX_LINES = 5000
_IND_DEFAULT_MAX_BODY = 5


def _ind_max_body():
    return _env_int_with_floor("LOOP_SPEC_INDIRECTION_MAX_BODY", 1, _IND_DEFAULT_MAX_BODY)


_IND_DEF_PATTERNS = {
    ".py": re.compile(r"^(?P<indent>\s*)def\s+(?P<name>[A-Za-z_]\w*)\s*\("),
    ".js": re.compile(
        r"^(?P<indent>\s*)(?:(?P<export>export\s+)?(?:async\s+)?function\s+(?P<name>[A-Za-z_]\w*)\s*\("
        r"|(?P<export2>export\s+)?const\s+(?P<name2>[A-Za-z_]\w*)\s*=\s*(?:async\s*)?(?:\([^)]*\)|[A-Za-z_$][\w$]*)\s*=>)"
    ),
    ".sh": re.compile(r"^(?P<indent>)(?P<name>[A-Za-z_]\w*)\s*\(\)\s*\{"),
    ".go": re.compile(r"^(?P<indent>)func\s+(?:\([^)]*\)\s*)?(?P<name>[A-Za-z_]\w*)\s*\("),
}
for _ind_alias, _ind_base in ((".jsx", ".js"), (".ts", ".js"), (".tsx", ".js"), (".mjs", ".js"), (".cjs", ".js"), (".bash", ".sh")):
    _IND_DEF_PATTERNS[_ind_alias] = _IND_DEF_PATTERNS[_ind_base]

_IND_COMMENT_PREFIX = {".py": "#", ".sh": "#", ".bash": "#"}
_IND_HEREDOC_OPEN = re.compile(r"<<-?\s*[\"']?([A-Za-z_]\w*)[\"']?")

_IND_EXPORTED = {
    ".py": lambda name, text: ("__all__" in text and ('"{}"'.format(name) in text or "'{}'".format(name) in text)),
    ".js": lambda name, text: bool(
        re.search(r"\bexport\b[^\n]*\b{}\b".format(re.escape(name)), text)
        or re.search(r"\bmodule\.exports\b[\s\S]{{0,200}}\b{}\b".format(re.escape(name)), text)
        or re.search(r"\bexports\.{}\b".format(re.escape(name)), text)
    ),
    ".sh": lambda name, text: bool(re.search(r"\bexport\s+-f\s+{}\b".format(re.escape(name)), text)),
    ".go": lambda name, text: name[:1].isupper(),
}
for _ind_alias, _ind_base in ((".jsx", ".js"), (".ts", ".js"), (".tsx", ".js"), (".mjs", ".js"), (".cjs", ".js"), (".bash", ".sh")):
    _IND_EXPORTED[_ind_alias] = _IND_EXPORTED[_ind_base]


def _ind_read(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return handle.read().splitlines()[:_IND_MAX_LINES]
    except OSError:
        return None


def _ind_body_length(lines, start, indent, ext):
    comment = _IND_COMMENT_PREFIX.get(ext)
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


def _ind_definitions(path):
    ext = os.path.splitext(path)[1].lower()
    pattern = _IND_DEF_PATTERNS.get(ext)
    lines = _ind_read(path) if pattern else None
    if not lines:
        return [], ""

    found = []
    heredoc = None
    for index, line in enumerate(lines):
        stripped = line.strip()
        if heredoc is not None:
            if stripped == heredoc:
                heredoc = None
            continue
        if ext in (".sh", ".bash"):
            opener = _IND_HEREDOC_OPEN.search(line)
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
        body = _ind_body_length(lines, index, groups.get("indent") or "", ext)
        if body is None:
            continue
        found.append((name, index + 1, body))
    return found, "\n".join(lines)


def _ind_corpus_text(root, targets):
    wanted = set(os.path.splitext(t)[1].lower() for t in targets)
    wanted.discard("")
    listing = _tracked_or_walked_files(root)

    chunks = {}
    target_by_identity = {os.path.realpath(path): path for path in targets}
    for path in listing:
        if os.path.splitext(path)[1].lower() not in wanted:
            continue
        lines = _ind_read(path)
        if lines is None:
            continue
        key = target_by_identity.get(os.path.realpath(path), path)
        chunks[key] = lines
        if len(chunks) >= _IND_MAX_CORPUS:
            break
    return chunks


def indirection_scan(root: Path, files: list[str]) -> dict:
    """Private, small, single-caller definitions `files` hold right now (a wrapper
    that would fail YAGNI). `layers` is the total count, for a caller to snapshot as
    a baseline and diff against later (`diff_probes`/`range_probes`)."""
    root = Path(root)
    max_body = _ind_max_body()

    picked = []
    seen_targets = set()
    for target in _resolve_all(root, files):
        if not os.path.isfile(target):
            continue
        identity = os.path.realpath(target)
        if identity in seen_targets:
            continue
        seen_targets.add(identity)
        picked.append(target)
    targets = picked

    corpus = _ind_corpus_text(root, targets)
    for path in targets:
        if path not in corpus:
            lines = _ind_read(path)
            if lines is not None:
                corpus[path] = lines

    findings = []
    total_defs = 0
    for path in sorted(targets):
        defs, text = _ind_definitions(path)
        total_defs += len(defs)
        ext = os.path.splitext(path)[1].lower()
        is_exported = _IND_EXPORTED.get(ext, lambda name, text: True)

        for name, lineno, body in defs:
            if body > max_body:
                continue
            if is_exported(name, text):
                continue
            word = re.compile(r"\b{}\b".format(re.escape(name)))
            sites = []
            for other, lines in corpus.items():
                for index, line in enumerate(lines):
                    if other == path and index + 1 == lineno:
                        continue
                    if word.search(line):
                        sites.append((other, index + 1))
            if len(sites) != 1:
                continue
            where, at = sites[0]
            findings.append({"file": path, "line": lineno, "name": name, "bodyLines": body, "calledFrom": where, "calledAt": at})

    return {"findings": findings, "totalDefs": total_defs, "maxBody": max_body, "layers": len(findings)}


# =============================================================================
# security-signal: the first auditable security/destructive-change signal, per
# file. Port of lib/security-signal.sh, adapted from "first across all files,
# exit on match" to "one finding per file" per this wave's public signature;
# corroboration of a weak term is scoped to that file's own text (see report).
# =============================================================================

_SEC_STRONG = [
    ("auth", re.compile(r"\bauth\b", re.I)),
    ("auth protocol", re.compile(r"\b(?:oauth2?|authn|authz|unauthenticated|unauthorized|reauthenticat[a-z]*)\b", re.I)),
    ("authentication", re.compile(r"\bauthenticat[a-z]*\b", re.I)),
    ("authorization", re.compile(r"\b(?:re|de|pre)?authoriz(?:e|es|ed|ing|ation)[a-z]*\b", re.I)),
    ("permission", re.compile(r"\bpermissions?\b", re.I)),
    ("credential", re.compile(r"\bcredentials?\b", re.I)),
    ("secret", re.compile(r"\bsecrets?\b", re.I)),
    ("cryptography", re.compile(r"\b(?:cryptograph[a-z]*|encrypt[a-z]*|decrypt[a-z]*|crypto(?:currency|graphic|graphy)?|crypt)\b", re.I)),
    ("payment", re.compile(r"\bpayments?\b", re.I)),
    ("billing", re.compile(r"\bbilling\b", re.I)),
    ("PII", re.compile(r"\bpii\b", re.I)),
]
_SEC_WEAK = [
    ("token", re.compile(r"\btokens?\b", re.I)),
    ("migration", re.compile(r"\bmigrat[a-z]*\b", re.I)),
    ("deletion", re.compile(r"\bdelet[a-z]*\b", re.I)),
]

_SEC_NON_GOAL_HEADING = re.compile(
    r"^(#{1,6})\s*(?:[-*\d.\s]*)?(?:"
    r"non[-\s]?goals?|non[-\s]?objectives?|out[-\s]of[-\s]scope|not\s+in\s+scope|"
    r"exclusions?|explicitly\s+excluded|what\s+(?:this|it)\s+does\s+not"
    r")\b", re.I,
)
_SEC_ANY_HEADING = re.compile(r"^(#{1,6})\s+\S")
_SEC_NEGATED_SCOPE = re.compile(
    r"\b(?:do(?:es)?\s+not|don'?t|doesn'?t|must\s+not|mustn'?t|will\s+not|won'?t|"
    r"shall\s+not|cannot|can'?t|never|without|avoid|refrain\s+from)\b"
    r".{0,40}?"
    r"\b(?:touch(?:es|ed|ing)?|modif(?:y|ies|ied|ying)|chang(?:e|es|ed|ing)|"
    r"edit(?:s|ed|ing)?|alter(?:s|ed|ing)?|refactor(?:s|ed|ing)?|"
    r"renam(?:e|es|ed|ing)|mov(?:e|es|ed|ing)|rewrit(?:e|es|ing)|"
    r"replac(?:e|es|ed|ing)|affect(?:s|ed|ing)?|updat(?:e|es|ed|ing))\b", re.I,
)
_SEC_UNTOUCHED = re.compile(r"\b(?:unchanged|untouched|unmodified|out\s+of\s+scope|not\s+in\s+scope)\b", re.I)
_SEC_CLAUSE_SPLIT = re.compile(r"[;:,]|\.(?=\s|$)|[–—]")


def _sec_suppressed(clause, in_non_goal):
    if in_non_goal:
        return "non-goal section"
    if _SEC_NEGATED_SCOPE.search(clause):
        return "negated scope verb"
    if _SEC_UNTOUCHED.search(clause):
        return "declared unchanged"
    return None


def _sec_scan_lines(numbered, only=None, where="line"):
    """The first signal in `numbered` ((number, text) pairs). With `only`, a term counts
    on a line in it and nowhere else, while headings are still tracked on every line so
    a non-goal section keeps its context (7.3.0: the change, not the whole file)."""
    non_goal_level = 0
    first_weak = None
    weak_names = set()
    for number, line in numbered:
        heading = _SEC_ANY_HEADING.match(line)
        if heading:
            level = len(heading.group(1))
            if _SEC_NON_GOAL_HEADING.match(line):
                non_goal_level = level
            elif non_goal_level and level <= non_goal_level:
                non_goal_level = 0
        if only is not None and number not in only:
            continue
        for clause in _SEC_CLAUSE_SPLIT.split(line):
            why = _sec_suppressed(clause, non_goal_level > 0)
            strong_hit = False
            for name, pattern in _SEC_STRONG:
                if pattern.search(clause):
                    strong_hit = True
                    if why:
                        break
                    return {"signal": name, "reason": "term={} at {} {}".format(name, where, number)}
            if strong_hit:
                continue
            for name, pattern in _SEC_WEAK:
                if pattern.search(clause):
                    if why:
                        continue
                    if first_weak is None:
                        first_weak = (number, name)
                    weak_names.add(name)
    if first_weak is not None and len(weak_names) >= 2:
        number, name = first_weak
        corroborators = ", ".join(sorted(weak_names - {name}))
        return {"signal": name, "reason": "term={} at {} {} (corroborated by: {})".format(name, where, number, corroborators)}
    return None


def _sec_scan_file(path, only=None):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return _sec_scan_lines(enumerate(handle, 1), only)
    except OSError:
        return None


_HUNK = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")


def _diff_lines(root: Path, base_sha: str, head_sha: str, name: str) -> tuple[set, list]:
    """(added line numbers at head, removed (number at base, text) pairs) for one file,
    from its own -U0 diff: only `@@` headers and the lines after them are read, never a
    file-name header, so quoting and prefix settings cannot mislead it."""
    out = repo_module.run_git(root, "diff", "-U0", "--no-renames", "--no-color", "--no-ext-diff",
                              "{}..{}".format(base_sha, head_sha), "--", name)
    added, removed, old_line, in_hunk = set(), [], 0, False
    for line in out.splitlines():
        hunk = _HUNK.match(line)
        if hunk:
            in_hunk = True
            old_line = int(hunk.group(1))
            start, count = int(hunk.group(3)), int(hunk.group(4) or 1)
            added.update(range(start, start + count))
        elif in_hunk and line.startswith("-"):
            removed.append((old_line, line[1:]))
            old_line += 1
    return added, removed


def _change_security_signals(root: Path, base_sha: str, head_sha: str, names: list[str]) -> list[dict]:
    """security_signal over the change only: added lines of each file at head, then its
    removed lines (deleting a permission check is a security change too)."""
    findings = []
    for name in names:
        added, removed = _diff_lines(root, base_sha, head_sha, name)
        result = _sec_scan_file(root / name, only=added) if added and (root / name).is_file() else None
        if result is None and removed:
            result = _sec_scan_lines(removed, where="removed line")
        if result:
            findings.append({"file": name, "signal": result["signal"], "reason": result["reason"]})
    return findings


def security_signal(root: Path, files: list[str]) -> list[dict]:
    """The first auditable security/destructive-change signal in each of `files`,
    skipping a file with none. Two strong terms escalate alone; a weak term (token,
    migration, deletion) needs a second, distinct weak term in the SAME file."""
    findings = []
    for name, path in zip(files, _resolve_all(root, files)):
        result = _sec_scan_file(path)
        if result:
            findings.append({"file": name, "signal": result["signal"], "reason": result["reason"]})
    return findings


# =============================================================================
# doc-deps: which declared third-party dependencies do these files actually
# import? Port of lib/doc-deps.py's `scan_deps`, enriched with the manifest path
# and importing files the design's return shape asks for. The `gate` subcommand
# and the LOOP_SPEC_DOC_DEPS operator override are not part of this wave's public
# API and were not ported.
# =============================================================================

_DD_PY_FROM = re.compile(r"^\s*from\s+([A-Za-z_][\w.]*)\s+import")
_DD_PY_IMPORT = re.compile(r"^\s*import\s+(.+)$")
_DD_JS_SPECIFIER = re.compile(r"""(?:from\s+|require\(\s*|import\(\s*|^\s*import\s+)['"]([^'"]+)['"]""", re.M)
_DD_GO_SINGLE = re.compile(r'^\s*import\s+(?:\w+\s+)?"([^"]+)"', re.M)
_DD_GO_BLOCK = re.compile(r"^import\s*\(([^)]*)\)", re.M | re.S)
_DD_GO_QUOTED = re.compile(r'"([^"]+)"')
_DD_REQ_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*")
_DD_PYPROJECT_SELF = re.compile(r'^name\s*=\s*["\']([A-Za-z0-9._-]+)["\']', re.M)

_DD_PY_EXTS = (".py",)
_DD_JS_EXTS = (".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs")
_DD_GO_EXTS = (".go",)


def _dd_norm(name):
    return re.sub(r"[-_.]+", "_", name.lower())


def _dd_read_text(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return None


def _dd_manifest_dirs(files, root):
    seen, dirs = set(), []
    root = os.path.realpath(root)
    for f in files:
        d = os.path.realpath(os.path.dirname(os.path.abspath(f)) or ".")
        while True:
            if d not in seen:
                seen.add(d)
                dirs.append(d)
            if d == root or os.path.dirname(d) == d:
                break
            d = os.path.dirname(d)
    return dirs


def _dd_declared_deps(dirs):
    """(python, js, go): normalized/exact name -> (display name, manifest path)."""
    py, js, go = {}, {}, []
    for d in dirs:
        pkg_path = os.path.join(d, "package.json")
        pkg = _dd_read_text(pkg_path)
        if pkg:
            try:
                data = json.loads(pkg)
            except ValueError:
                data = {}
            for key in ("dependencies", "devDependencies", "peerDependencies"):
                for name in (data.get(key) or {}).keys():
                    js.setdefault(name, pkg_path)
        try:
            entries = os.listdir(d)
        except OSError:
            entries = []
        for name in entries:
            if name.startswith("requirements") and name.endswith(".txt"):
                req_path = os.path.join(d, name)
                text = _dd_read_text(req_path) or ""
                for line in text.splitlines():
                    line = line.strip()
                    if not line or line.startswith(("#", "-")):
                        continue
                    m = _DD_REQ_NAME.match(line)
                    if m:
                        py.setdefault(_dd_norm(m.group(0)), (m.group(0), req_path))
        pyproject_path = os.path.join(d, "pyproject.toml")
        pyproject = _dd_read_text(pyproject_path)
        if pyproject:
            own = {_dd_norm(m) for m in _DD_PYPROJECT_SELF.findall(pyproject)}
            for spec in re.findall(r'["\']([A-Za-z0-9][A-Za-z0-9._-]*)\s*[<>=!~\["\']', pyproject):
                if _dd_norm(spec) not in own:
                    py.setdefault(_dd_norm(spec), (spec, pyproject_path))
        gomod_path = os.path.join(d, "go.mod")
        gomod = _dd_read_text(gomod_path)
        if gomod:
            for m in re.finditer(r"^\s*(?:require\s+)?([\w.\-/]+\.[\w\-]+/[\w.\-/]+)\s+v[\d.]", gomod, re.M):
                go.append((m.group(1), gomod_path))
    return py, js, go


def _dd_file_imports(path):
    text = _dd_read_text(path)
    if text is None:
        return [], [], []
    ext = os.path.splitext(path)[1].lower()
    if ext in _DD_PY_EXTS:
        mods = []
        for line in text.splitlines():
            m = _DD_PY_FROM.match(line)
            if m:
                mods.append(m.group(1))
                continue
            m = _DD_PY_IMPORT.match(line)
            if m:
                for part in m.group(1).split(","):
                    part = part.strip().split(" as ")[0].split()[0] if part.strip() else ""
                    if part and (part[0].isalpha() or part[0] == "_"):
                        mods.append(part)
        return mods, [], []
    if ext in _DD_JS_EXTS:
        return [], _DD_JS_SPECIFIER.findall(text), []
    if ext in _DD_GO_EXTS:
        paths = _DD_GO_SINGLE.findall(text)
        for block in _DD_GO_BLOCK.findall(text):
            paths.extend(_DD_GO_QUOTED.findall(block))
        return [], [], paths
    return [], [], []


def doc_deps(root: Path, files: list[str]) -> list[dict]:
    """Third-party dependencies `files` actually import, intersected with what the
    repo's manifests (package.json/requirements.txt/pyproject.toml/go.mod) declare --
    the list whose current docs a design phase must consult, not the whole manifest."""
    resolved = [f for f in _resolve_all(root, files) if os.path.isfile(f)]
    if not resolved:
        return []
    py, js, go = _dd_declared_deps(_dd_manifest_dirs(resolved, str(root)))
    if not (py or js or go):
        return []

    hits = {}
    for f in resolved:
        py_mods, js_specs, go_paths = _dd_file_imports(f)
        for mod in py_mods:
            segs = mod.split(".")
            for cand in (_dd_norm(segs[0]), _dd_norm("_".join(segs[:2]))):
                if cand in py:
                    display, manifest = py[cand]
                    hits.setdefault(display, {"manifest": manifest, "importedBy": set()})["importedBy"].add(f)
        for spec in js_specs:
            if spec.startswith((".", "/", "node:")):
                continue
            segs = spec.split("/")
            pkg = "/".join(segs[:2]) if spec.startswith("@") else segs[0]
            if pkg in js:
                hits.setdefault(pkg, {"manifest": js[pkg], "importedBy": set()})["importedBy"].add(f)
        for path in go_paths:
            for mod, manifest in go:
                if path == mod or path.startswith(mod + "/"):
                    hits.setdefault(mod, {"manifest": manifest, "importedBy": set()})["importedBy"].add(f)

    return [
        {"package": name, "manifest": info["manifest"], "importedBy": sorted(info["importedBy"])}
        for name, info in sorted(hits.items())
    ]


# =============================================================================
# comment-tells: comments written for the generator, not the next reader. Port
# of lib/comment-tells.sh's "scan" mode.
# =============================================================================

_CT_EXEMPT = re.compile(
    r"\b(?:simplicity|TODO|FIXME|NOTE|HACK|XXX|SAFETY|WHY|WARNING|SECURITY)\b[:!]?"
    r"|\b(?:usage|example|args|arguments|params|parameters|returns|raises|"
    r"outputs?|exit codes?)\s*:"
    r"|\b(?:eslint|prettier|noqa|pylint|pyright|mypy|ruff|shellcheck|ts-ignore|"
    r"ts-expect-error)\b|\btype:\s*ignore\b|\bSPDX-|\bCopyright\b|\bLicensed under\b",
    re.I,
)
_CT_CHANGELOG = re.compile(
    r"^(?:previously|used to (?:be|call|return|live)|renamed from|moved from|"
    r"changed from|replaces the old|no longer (?:used|needed|called)|"
    r"was:\s|formerly|deprecated in favou?r of)\b",
    re.I,
)
_CT_DIFF_NARRATION = re.compile(
    r"^(?:(?:added|adding|updated|updating|removed|removing|refactored|"
    r"refactoring)(?=[\s:,])(?!\s+(?:in|to|entries?|files?)\b)|new(?=:))",
    re.I,
)
_CT_DEFINITION = re.compile(
    r"^\s*(?:export\s+|async\s+|public\s+|private\s+|protected\s+|static\s+)*"
    r"(?:def|func|function|fn|class|interface|type|struct|impl)\b"
    r"|^\s*[A-Za-z_][A-Za-z0-9_]*\s*\(\)\s*\{"
)
_CT_LITERAL = re.compile(r"""(['"])(?:(?!\1).){8,}\1""")
_CT_ECHO_MAX_WORDS = 10
_CT_STOPWORDS = frozenset("""
a an and are as at be by call calls called check do does for from get gets has have if in
into is it its let make makes new not of on or over return returns set sets so than that the
their then there these this to up us use used uses value values via was we when where which
while will with
""".split())
_CT_TOKEN = re.compile(r"[A-Za-z_][A-Za-z0-9_]*|\d+")
_CT_CASE_SPLIT = re.compile(r"[A-Z]?[a-z]+|[A-Z]{2,}(?![a-z])|\d+")


def _ct_strip_marker(text):
    body = text.strip()
    for prefix in ("/**", "/*", "*/", "//", "#!", "#", "--", ";;"):
        if body.startswith(prefix):
            body = body[len(prefix):]
            break
    return body.strip(" *\t")


def _ct_atoms(text):
    words = set()
    for token in _CT_TOKEN.findall(text):
        parts = _CT_CASE_SPLIT.findall(token)
        if parts:
            words.update(part.lower() for part in parts)
        else:
            words.add(token.lower())
    return words


def _ct_echoes(body, code_line):
    if len(body.split()) > _CT_ECHO_MAX_WORDS:
        return False
    if _CT_DEFINITION.match(code_line) or _CT_LITERAL.search(code_line):
        return False
    code = {t for t in _ct_atoms(code_line) if t not in _CT_STOPWORDS}
    if len(code) < 2:
        return False
    return code.issubset(_ct_atoms(body))


def _ct_blocks(numbered, is_comment):
    index = 0
    total = len(numbered)
    while index < total:
        if not is_comment(numbered[index][1]):
            index += 1
            continue
        start = index
        run = [numbered[index]]
        index += 1
        while index < total and is_comment(numbered[index][1]) and numbered[index][0] == numbered[index - 1][0] + 1:
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


def _ct_scan(path, numbered):
    prefixes = _COMMENT_PREFIX_BY_EXT.get(os.path.splitext(path)[1].lower())
    if not prefixes:
        return []

    def is_comment(text):
        body = text.strip()
        return bool(body) and body.startswith(prefixes)

    header_end = 0
    if numbered and numbered[0][0] == 1:
        for index, (_, text) in enumerate(numbered):
            if not text.strip() or is_comment(text):
                header_end = index + 1
                continue
            break

    findings = []
    for start, run, following in _ct_blocks(numbered, is_comment):
        if start < header_end:
            continue
        if any(_CT_EXEMPT.search(text) for _, text in run):
            continue

        lineno, text = run[0]
        head = _ct_strip_marker(text)
        if not head:
            continue
        if _CT_CHANGELOG.search(head):
            findings.append((lineno, "changelog", head[:80]))
        elif _CT_DIFF_NARRATION.match(head):
            findings.append((lineno, "diff-narration", head[:80]))
        elif len(run) == 1 and following and _ct_echoes(head, following):
            findings.append((lineno, "echoes-code", head[:80]))

    return sorted(set(findings))


def comment_tells(root: Path, files: list[str]) -> list[dict]:
    """Comments in `files` that were written for the generator, not the reader:
    changelog narration, diff narration ("Added ..."), or a one-line comment that
    only restates the code line right below it."""
    findings = []
    for path in sorted(_resolve_all(root, files)):
        if not os.path.isfile(path):
            continue
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as handle:
                numbered = list(enumerate(handle.read().splitlines(), 1))
        except OSError:
            continue
        for lineno, tell, body in _ct_scan(path, numbered):
            findings.append({"file": path, "line": lineno, "tell": tell, "detail": body})
    return findings


# =============================================================================
# failure-tells: code a person cannot operate when it breaks. Port of
# lib/failure-tells.py's rules wholesale (pure text logic, nothing to drop).
# =============================================================================

_FT_LANGUAGE = {
    ".py": "python", ".sh": "shell", ".bash": "shell",
    ".js": "js", ".jsx": "js", ".mjs": "js", ".cjs": "js",
    ".ts": "js", ".tsx": "js",
}
_FT_HEREDOC_OPEN = re.compile(r"<<-?\s*[\"']?([A-Za-z_][A-Za-z0-9_]*)[\"']?")

_FT_EXCEPT_INLINE = re.compile(r"^(\s*)except\b(?P<clause>[^:]*):\s*(pass|\.\.\.|continue)\s*$")
_FT_EXCEPT_OPEN = re.compile(r"^(\s*)except\b(?P<clause>[^:]*):\s*$")
_FT_BROAD = re.compile(r"^\s*(?:\(?\s*(?:Exception|BaseException)\s*\)?)?(?:\s+as\s+\w+)?\s*$")
_FT_EMPTY_BODY = re.compile(r"^\s*(pass|\.\.\.|continue)\s*$")
_FT_CATCH_INLINE = re.compile(r"\bcatch\s*(?:\([^)]*\))?\s*\{\s*\}")
_FT_CATCH_OPEN = re.compile(r"\bcatch\s*(?:\([^)]*\))?\s*\{\s*$")

_FT_SHELL_EXIT = re.compile(r"(?:^|;|\|\||&&|\{)\s*exit\s+([1-9][0-9]*)\b")
_FT_PY_EXIT = re.compile(r"\bsys\.exit\(\s*([1-9][0-9]*)\s*\)")
_FT_JS_EXIT = re.compile(r"\bprocess\.exit\(\s*([1-9][0-9]*)\s*\)")
_FT_SPEAKS = re.compile(
    r"echo|printf|\bcat\b|>&2|print\(|log|console\.|die|usage|(?<!pipe)fail|error|warn|"
    r"raise|throw|message|msg|\bjq\b",
    re.I,
)
_FT_GUARDED_EXIT = re.compile(r"(?:\|\||&&).*(?:exit|sys\.exit|process\.exit)\b")

_FT_PY_RAISE = re.compile(r"\braise\s+\w*(?:Error|Exception)\s*\(\s*(?P<prefix>[a-z]*)(?P<quote>[\"'])(?P<body>[^\"']*)(?P=quote)\s*\)")
_FT_JS_THROW = re.compile(r"\bthrow\s+new\s+\w*Error\s*\(\s*(?P<quote>[\"'`])(?P<body>[^\"'`]*)(?P=quote)\s*\)")
_FT_SH_SAY = re.compile(r"\becho\s+(?P<quote>[\"'])(?P<body>[^\"']*)(?P=quote)\s*>&2")

_FT_GENERIC = frozenset("""
a an and argument arguments bad broke broken data err error errors exception
failed failing failure fault incorrect input internal invalid issue occurred
oops param params parameter parameters problem request something sorry the
this to unexpected unknown unsupported value values went wrong
""".split())
_FT_INTERPOLATION = re.compile(r"[{}$%]|\\\(")
_FT_WORD = re.compile(r"[A-Za-z]+")
_FT_MAX_GENERIC_WORDS = 6


def _ft_executable_lines(lines, language):
    masked = []
    quote = None
    block_comment = False
    terminator = None
    for text in lines:
        if language == "shell" and terminator is not None:
            masked.append(" " * len(text))
            if text.strip() == terminator:
                terminator = None
            continue
        code = list(text)
        index = 0
        pending_terminator = None
        while index < len(text):
            if block_comment:
                code[index] = " "
                if text.startswith("*/", index):
                    code[index:index + 2] = "  "
                    index += 2
                    block_comment = False
                else:
                    index += 1
                continue
            if quote:
                width = len(quote)
                if text.startswith(quote, index):
                    code[index:index + width] = " " * width
                    index += width
                    quote = None
                elif text[index] == "\\":
                    code[index] = " "
                    if index + 1 < len(text):
                        code[index + 1] = " "
                    index += 2
                else:
                    code[index] = " "
                    index += 1
                continue

            if language == "js" and text.startswith("/*", index):
                code[index:index + 2] = "  "
                index += 2
                block_comment = True
                continue
            if language == "js" and text.startswith("//", index):
                code[index:] = " " * (len(text) - index)
                break
            if language in ("python", "shell") and text[index] == "#":
                if language == "python" or index == 0 or text[index - 1].isspace():
                    code[index:] = " " * (len(text) - index)
                    break

            if language == "shell" and not text.startswith("<<<", index):
                opener = _FT_HEREDOC_OPEN.match(text, index)
                if opener:
                    pending_terminator = opener.group(1)

            if language == "python" and text.startswith(("'''", '\"\"\"'), index):
                quote = text[index:index + 3]
                code[index:index + 3] = "   "
                index += 3
                continue
            allowed_quotes = ("'", '"', "`") if language == "js" else ("'", '"')
            if text[index] in allowed_quotes:
                quote = text[index]
                code[index] = " "
            index += 1
        masked.append("".join(code))
        if pending_terminator is not None:
            terminator = pending_terminator
        if language == "python" and quote in ("'", '"'):
            quote = None
    return masked


def _ft_code_lines(lines, language, executable=None):
    executable = executable if executable is not None else _ft_executable_lines(lines, language)
    for index, text in enumerate(lines):
        if executable[index].strip():
            yield index, text, executable[index]


def _ft_only_statement_is_empty(lines, start, indent):
    body = []
    for text in lines[start + 1:]:
        if not text.strip():
            continue
        if text.strip().startswith("#"):
            return False
        if len(text) - len(text.lstrip()) <= indent:
            break
        body.append(text)
        if len(body) > 1:
            return False
    return len(body) == 1 and bool(_FT_EMPTY_BODY.match(body[0]))


def _ft_next_code_line_closes(lines, start):
    for text in lines[start + 1:]:
        stripped = text.strip()
        if not stripped:
            continue
        if stripped.startswith(("//", "/*", "*")):
            return False
        return stripped.startswith("}")
    return False


def _ft_swallowed(lines, language):
    if language == "python":
        for index, text, code in _ft_code_lines(lines, language):
            match = _FT_EXCEPT_INLINE.match(code)
            if match:
                if _FT_BROAD.match(match.group("clause")):
                    yield index + 1, "swallowed", text.strip()
                continue
            match = _FT_EXCEPT_OPEN.match(code)
            if match and _FT_BROAD.match(match.group("clause")) and _ft_only_statement_is_empty(lines, index, len(match.group(1))):
                yield index + 1, "swallowed", text.strip()
    elif language == "js":
        for index, text, code in _ft_code_lines(lines, language):
            if _FT_CATCH_INLINE.search(code):
                yield index + 1, "swallowed", text.strip()
            elif _FT_CATCH_OPEN.search(code) and _ft_next_code_line_closes(lines, index):
                yield index + 1, "swallowed", text.strip()


def _ft_speaks_nearby(lines, index):
    seen = 0
    for text in [lines[index]] + [lines[i] for i in range(index - 1, -1, -1)]:
        if not text.strip():
            continue
        if _FT_SPEAKS.search(text):
            return True
        seen += 1
        if seen > 5:
            break
    return False


def _ft_silent_exit(lines, language):
    patterns = {"shell": _FT_SHELL_EXIT, "python": _FT_PY_EXIT, "js": _FT_JS_EXIT}
    pattern = patterns[language]
    executable = _ft_executable_lines(lines, language)
    for index, text, code in _ft_code_lines(lines, language, executable):
        match = pattern.search(code)
        if not match or _FT_GUARDED_EXIT.search(code):
            continue
        if _ft_speaks_nearby(executable, index):
            continue
        yield index + 1, "silent-exit", text.strip()


def _ft_contextless(lines, language):
    patterns = {"python": (_FT_PY_RAISE,), "js": (_FT_JS_THROW,), "shell": (_FT_SH_SAY,)}
    operators = {"python": "raise", "js": "throw", "shell": "echo"}
    for index, text, code in _ft_code_lines(lines, language):
        for pattern in patterns[language]:
            for match in pattern.finditer(text):
                if not code.startswith(operators[language], match.start()):
                    continue
                if match.groupdict().get("prefix") == "f":
                    continue
                body = match.group("body")
                if _FT_INTERPOLATION.search(body) or "," in text[match.end("body"):match.end()]:
                    continue
                words = [w.lower() for w in _FT_WORD.findall(body)]
                if not words or len(words) > _FT_MAX_GENERIC_WORDS:
                    continue
                if set(words) <= _FT_GENERIC:
                    yield index + 1, "contextless-error", body.strip()


def _ft_scan(path, text):
    language = _FT_LANGUAGE.get(os.path.splitext(path)[1].lower())
    if not language:
        return []
    lines = text.splitlines()
    findings = list(_ft_swallowed(lines, language))
    findings += list(_ft_silent_exit(lines, language))
    findings += list(_ft_contextless(lines, language))
    return sorted(set(findings))


def failure_tells(root: Path, files: list[str]) -> list[dict]:
    """The three failure-path defects in `files`: a caught error whose handler does
    nothing (`swallowed`), a non-zero exit with nothing said first (`silent-exit`),
    or an error message built only from synonyms for "it broke" (`contextless-error`)."""
    findings = []
    for path in sorted(_resolve_all(root, files)):
        if os.path.splitext(path)[1].lower() not in _FT_LANGUAGE:
            continue
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as handle:
                text = handle.read()
        except OSError:
            continue
        for lineno, tell, detail in _ft_scan(path, text):
            findings.append({"file": path, "line": lineno, "tell": tell, "detail": detail[:90]})
    return findings


# =============================================================================
# doc-tells: markdown a human cannot maintain or operate from. Port of
# lib/doc-tells.py's "scan" mode; the git lookups it made with subprocess go
# through loop_spec.repo._git instead (no subprocess to a shell script).
# =============================================================================

_DT_MARKDOWN = (".md", ".markdown")
_DT_HISTORICAL = re.compile(r"^(?:changelog|history|news|releases)(?:\.[a-z]+)?$", re.I)

_DT_FENCE = re.compile(r"^\s{0,3}(`{3,}|~{3,})\s*(\S*)")
_DT_INLINE_LINK = re.compile(r"\[[^\]^]*\]\(\s*<?([^)>\s]+)>?(?:\s+[\"'][^\"']*[\"'])?\s*\)")
_DT_REFERENCE_LINK = re.compile(r"^\s{0,3}\[[^\]]+\]:\s*<?(\S+)>?")
_DT_CODE_SPAN = re.compile(r"`([^`\n]+)`")

_DT_PATHISH = re.compile(r"^[A-Za-z0-9_.+-]+(?:/[A-Za-z0-9_.+-]+)+$")
_DT_LINE_ANCHOR = re.compile(r":\d+(?:-\d+)?$")
_DT_DOMAIN = re.compile(r"^[A-Za-z0-9-]+(?:\.[A-Za-z]{2,})+$")

_DT_COMMAND_LANGUAGES = frozenset(("bash", "sh", "shell", "zsh", "console", "shell-session", "command", "sh-session"))
_DT_PLACEHOLDER = re.compile(
    r"<([A-Za-z][A-Za-z0-9_.-]*)>"
    r"|\b(YOUR[_-][A-Za-z0-9_-]+)\b"
    r"|\bpath/to/([A-Za-z0-9_.-]+)"
)
_DT_GENERIC = frozenset("""
    and dir directory file files for from here name names path paths some the
    this value values with your
""".split())
_DT_WORD = re.compile(r"[A-Za-z0-9]+")

_DT_ABSENCE = re.compile(
    r"\b(?:no longer|not exist|never existed|none of (?:them|these)|absent|deleted|"
    r"removed|dropped|gone|renamed|replaced by|superseded|found false|used to (?:be|live))\b",
    re.I,
)


def _dt_split_fences(lines):
    outside, blocks = [], []
    fence, current = None, None
    for lineno, text in enumerate(lines, 1):
        match = _DT_FENCE.match(text)
        if fence is None:
            if match:
                fence = match.group(1)[0] * 3
                current = (match.group(2).lower(), [])
                blocks.append(current)
            else:
                outside.append((lineno, text))
            continue
        if match and match.group(1).startswith(fence) and not match.group(2):
            fence, current = None, None
            continue
        current[1].append((lineno, text))
    return outside, blocks


def _dt_link_targets(text):
    for match in list(_DT_INLINE_LINK.finditer(text)) + list(_DT_REFERENCE_LINK.finditer(text)):
        target = match.group(1)
        if re.match(r"^[A-Za-z][A-Za-z0-9+.-]*:", target) or target.startswith(("#", "/", "//")):
            continue
        if any(mark in target for mark in ("{", "}", "$", "*", "<")):
            continue
        target = target.split("#", 1)[0].split("?", 1)[0]
        if target:
            yield target


def _dt_dead_links(doc_dir, outside):
    for lineno, text in outside:
        for target in _dt_link_targets(text):
            if not os.path.exists(os.path.join(doc_dir, target)):
                yield lineno, "dead-link", "{} (no such file from {}/)".format(target, os.path.basename(doc_dir) or ".")


def _dt_tracked_kinds(repo_root):
    kinds = {}
    proc = repo_module._git(Path(repo_root), "ls-files")
    out = proc.stdout if proc.returncode == 0 else ""
    for tracked in out.splitlines():
        directory, _, base = tracked.rpartition("/")
        kinds.setdefault(directory, set()).add(os.path.splitext(base)[1].lower())
    return kinds


def _dt_stale_refs(doc_dir, repo_root, outside):
    if not repo_root:
        return
    kinds = _dt_tracked_kinds(repo_root)
    for index, (lineno, text) in enumerate(outside):
        context = _DT_CODE_SPAN.sub(" ", " ".join(line for _, line in outside[max(index - 1, 0):index + 2]))
        for span in _DT_CODE_SPAN.findall(text):
            token = _DT_LINE_ANCHOR.sub("", span.strip())
            if not _DT_PATHISH.match(token) or token.startswith(".."):
                continue
            segments = token.split("/")
            if _DT_DOMAIN.match(segments[0]) or any(set(s) == {"."} for s in segments):
                continue
            if os.path.exists(os.path.join(repo_root, token)) or os.path.exists(os.path.join(doc_dir, token)):
                continue
            directory = token.rpartition("/")[0]
            extension = os.path.splitext(token)[1].lower()
            if not extension or extension not in kinds.get(directory, ()):
                continue
            if _DT_ABSENCE.search(context):
                continue
            yield lineno, "stale-ref", "{} (absent, though {}/ tracks files like it)".format(token, directory)


def _dt_undefined_placeholders(outside, blocks):
    prose = set()
    for _, text in outside:
        prose.update(word.lower() for word in _DT_WORD.findall(text))
    for info, block in blocks:
        if info not in _DT_COMMAND_LANGUAGES:
            continue
        for lineno, text in block:
            for match in _DT_PLACEHOLDER.finditer(text):
                token = match.group(0)
                name = next(group for group in match.groups() if group)
                words = {w.lower() for w in _DT_WORD.findall(name) if len(w) > 2}
                distinctive = words - _DT_GENERIC
                if distinctive and not distinctive & prose:
                    yield lineno, "undefined-placeholder", "{} (the prose never says what to substitute)".format(token)


def _dt_scan(path, text, repo_root):
    lines = text.splitlines()
    outside, blocks = _dt_split_fences(lines)
    doc_dir = os.path.dirname(os.path.abspath(path)) or "."
    findings = list(_dt_dead_links(doc_dir, outside))
    findings += list(_dt_stale_refs(doc_dir, repo_root, outside))
    findings += list(_dt_undefined_placeholders(outside, blocks))
    return sorted(set(findings))


def _dt_repo_root_of(doc_dir):
    proc = repo_module._git(Path(doc_dir), "rev-parse", "--show-toplevel")
    if proc.returncode != 0:
        return None
    return proc.stdout.strip() or None


def doc_tells(root: Path, files: list[str]) -> list[dict]:
    """The three markdown defects decidable from the text and the tree: a relative
    link whose target is not on disk (`dead-link`), an inline-code path git no
    longer tracks (`stale-ref`), or a command holding a placeholder the page never
    explains (`undefined-placeholder`)."""
    findings = []
    for path in _resolve_all(root, files):
        if not path.lower().endswith(_DT_MARKDOWN) or _DT_HISTORICAL.match(os.path.basename(path)):
            continue
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as handle:
                text = handle.read()
        except OSError:
            continue
        doc_dir = os.path.dirname(os.path.abspath(path)) or "."
        repo_root = _dt_repo_root_of(doc_dir)
        for lineno, tell, detail in _dt_scan(path, text, repo_root):
            findings.append({"file": path, "line": lineno, "tell": tell, "detail": detail})
    return findings


# =============================================================================
# Aggregators (roadmap 8 / M2 wiring): PLAN gets a snapshot of the touched files,
# EXECUTE/VERIFY get a delta over a git range.
# =============================================================================


_CHECK_FILES = {
    "ruff.toml": "ruff", ".ruff.toml": "ruff", "mypy.ini": "mypy", ".mypy.ini": "mypy",
    "pyrightconfig.json": "pyright", "tsconfig.json": "tsc", ".flake8": "flake8",
}
_PYPROJECT_TOOLS = ("ruff", "mypy", "pyright")
_PACKAGE_SCRIPTS = ("lint", "typecheck", "type-check", "format:check")


def repo_checks_probe(repo: Path, sha: str) -> list[dict]:
    """Which lint/typecheck/format tools a repo configures at `sha`, read from git
    objects (never the working tree, which may be on another branch). Facts for the
    planner, which chooses the commands; nothing here decides a command."""
    listing = repo_module._git(repo, "ls-tree", "--name-only", "-z", sha)
    if listing.returncode != 0:
        return []
    names = set(listing.stdout.split("\0"))
    facts = [{"tool": tool, "source": name, "sha": sha} for name, tool in sorted(_CHECK_FILES.items()) if name in names]

    def read(name: str) -> str | None:
        shown = repo_module._git(repo, "show", f"{sha}:{name}")
        return shown.stdout if shown.returncode == 0 else None

    if "pyproject.toml" in names and (text := read("pyproject.toml")) is not None:
        try:
            tool_table = tomllib.loads(text).get("tool") or {}
        except tomllib.TOMLDecodeError:
            tool_table = {}
        facts += [{"tool": t, "source": f"pyproject.toml [tool.{t}]", "sha": sha} for t in _PYPROJECT_TOOLS if t in tool_table]
    if "package.json" in names and (text := read("package.json")) is not None:
        try:
            scripts = json.loads(text).get("scripts") or {}
        except (ValueError, AttributeError):
            scripts = {}
        facts += [{"tool": f"npm run {n}", "source": f"package.json scripts.{n}: {scripts[n]}", "sha": sha}
                  for n in _PACKAGE_SCRIPTS if isinstance(scripts, dict) and n in scripts]
    return facts


_ANY_PR_URL = re.compile(r"https?://[^\s/]+/([^\s/]+)/([^\s/]+)/pull/(\d+)")
_PR_WORD = re.compile(r"\bPR\s*#?(\d+)\b", re.IGNORECASE)
_PR_HASH = re.compile(r"(?<![\w/&])#(\d+)\b")


def _origin_is(path: Path, owner: str, name: str) -> bool:
    url = (repo_module.origin_url(path) or "").rstrip("/")
    return url.removesuffix(".git").endswith(f"/{owner}/{name}") or url.removesuffix(".git").endswith(f":{owner}/{name}")


def pr_refs(repos: list[tuple[str, Path]], text: str) -> list[dict]:
    """Every pull request `text` names, resolved against each workspace repo (7.3.0,
    the router's facts): `{ref, number, url, repo, adoptable, reason}`. A URL on any
    host resolves only in a repo whose origin is that URL's repository. An explicit
    reference (a URL or `PR #n`) that nothing adopts stays, with `repo: null` and the
    reason, so the router sees why; a bare `#n` that nothing adopts is dropped."""
    wanted = [(m.group(0), int(m.group(3)), (m.group(1), m.group(2))) for m in _ANY_PR_URL.finditer(text)]
    wanted += [(m.group(0), int(m.group(1)), None) for m in _PR_WORD.finditer(text)]
    bare = [(m.group(0), int(m.group(1)), None) for m in _PR_HASH.finditer(text)]
    rows, seen = [], set()
    for ref, number, owner_repo in wanted + bare:
        explicit = (ref, number, owner_repo) not in bare
        adopted_any, why = False, "no workspace repository has this pull request open"
        for name, path in repos:
            if (name, number) in seen or (owner_repo and not _origin_is(path, *owner_repo)):
                continue
            adoption = repo_module.adopt_pr(path, ref if owner_repo else number)
            if adoption.adopt:
                seen.add((name, number))
                adopted_any = True
                rows.append({"ref": ref, "number": number, "url": adoption.url, "repo": name,
                             "adoptable": True, "reason": adoption.reason})
            else:
                why = adoption.reason
        if not adopted_any and explicit and not any(r["number"] == number for r in rows):
            rows.append({"ref": ref, "number": number, "url": None, "repo": None, "adoptable": False, "reason": why})
    return rows


def plan_probes(root: Path, files: list[str]) -> dict:
    """Everything a PLAN implementation needs about the files a request names:
    house style, duplication, indirection, security signals, and the third-party
    dependencies those files import, in one call. Offline: the planner fetches a
    dependency's docs itself."""
    return _relativize({
        "houseStyle": house_style_probe(root, files),
        "duplication": duplication_scan(root, files),
        "indirection": indirection_scan(root, files),
        "securitySignals": security_signal(root, files),
        "deps": doc_deps(root, files),
    }, root)


def _relativize(obj, root: Path):
    """Every string in `obj` under `root` (as given or resolved) made root-relative,
    so a probe run in a checkout that is then removed names repo paths."""
    prefixes = {str(root).rstrip(os.sep) + os.sep, os.path.realpath(root).rstrip(os.sep) + os.sep}
    if isinstance(obj, dict):
        return {k: _relativize(v, root) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_relativize(v, root) for v in obj]
    if isinstance(obj, str):
        for prefix in prefixes:
            if obj.startswith(prefix):
                return obj[len(prefix):]
    return obj


_PATH_CHARS = r"[\w./-]"
_NAMED_FILES_CAP = 20


def named_files(repo_path: Path, sha: str, texts: list[str]) -> list[str]:
    """Tracked files at `sha` that `texts` name: the full repo-relative path, or a
    basename with a dot that is unique in that tree, with no path character
    ([A-Za-z0-9_./-]) on either side. Sorted, then capped."""
    tracked = [line for line in repo_module.run_git(repo_path, "ls-tree", "-r", "--name-only", sha).splitlines() if line]
    text = "\n".join(texts)
    basenames: dict[str, list[str]] = {}
    for path in tracked:
        basenames.setdefault(os.path.basename(path), []).append(path)

    def named(token):
        return re.search(rf"(?<!{_PATH_CHARS}){re.escape(token)}(?!{_PATH_CHARS})", text) is not None

    hits = {path for path in tracked if named(path)}
    hits |= {paths[0] for base, paths in basenames.items() if "." in base and len(paths) == 1 and named(base)}
    return sorted(hits)[:_NAMED_FILES_CAP]


def _diff_touched_files(repo_path: Path, base_sha: str, head_sha: str) -> list[str]:
    out = repo_module.run_git(repo_path, "diff", "--name-only", "{}..{}".format(base_sha, head_sha))
    return [line for line in out.splitlines() if line]


def _range_style_probes(path: Path, base_sha: str, head_sha: str, base_layers: int) -> dict:
    path = Path(path)
    touched = _diff_touched_files(path, base_sha, head_sha)
    files = [f for f in touched if (path / f).is_file()]
    md_files = [f for f in files if f.lower().endswith(_DT_MARKDOWN)]
    indirection = indirection_scan(path, files)
    return {
        "commentTells": comment_tells(path, files),
        "failureTells": failure_tells(path, files),
        "indirection": {
            "layers": indirection["layers"],
            "delta": indirection["layers"] - base_layers,
            "findings": indirection["findings"],
        },
        "duplication": duplication_scan(path, files),
        "houseStyleCompare": house_style_compare(path, files),
        "docTells": doc_tells(path, md_files),
        "securitySignals": _change_security_signals(path, base_sha, head_sha, touched),
    }


def diff_probes(worktree: Path, base_sha: str, head_sha: str, base_layers: int) -> dict:
    """Review-time facts over what changed between two commits in a checked-out
    worktree: comment/failure/doc tells, duplication, house-style deviation, and
    the indirection-layer delta against a caller-supplied baseline count."""
    return _range_style_probes(worktree, base_sha, head_sha, base_layers)


def range_probes(repo: Path, base_sha: str, head_sha: str, base_layers: int) -> dict:
    """Same facts as `diff_probes`, over the whole reviewed range rather than one
    incremental diff (VERIFY's full-pass case)."""
    return _range_style_probes(repo, base_sha, head_sha, base_layers)
