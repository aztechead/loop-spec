#!/usr/bin/env python3
"""Decide which bash and python constructs assume a floor this plugin does not have.

lib/portability-scan.sh owns argument, path, and directory-expansion setup; this module
owns the rules. The plugin's stated floor (CLAUDE.md) is bash >= 3.2, POSIX/BSD userland,
and python3 >= 3.7, because it has to run unmodified on macOS (BSD sed/grep/stat/date/
mktemp, no GNU coreutils, no `readlink -f`, no `realpath`), stock GNU/Linux, and
Alpine/BusyBox. A construct that only exists on one of those is invisible in code review
unless the reviewer happens to run the other platform -- this makes it decidable from
the text instead.

Two independent rule sets:

  shell    a bash-4-only piece of syntax (`mapfile`, `declare -A`, `${var,,}`, ...), or
           an invocation of a GNU-coreutils-only flag (`readlink -f`, `sed -i` with no
           suffix, `stat -c`, ...) that BSD's userland does not accept, or the reverse:
           `sed -i ''` (BSD's own portable idiom) that GNU sed misreads as the script
  python   a stdlib feature newer than 3.7 (walrus, `match`, `str.removeprefix`,
           `dict | dict`, positional-only `/` parameters, `os.sched_*`,
           `signal.SIGRTMIN`, the f-string `=` debug specifier)

`timeout` and `flock` are neither bash-4 nor GNU-only, but absent from a stock macOS
install with no fallback of their own; they are reported at warning severity, and only
when used with nothing guarding them (no `command -v`/`type`/`which` check anywhere in
the file) in code this plugin actually ships (`lib/`, `hooks/`) -- a test fixture proving
a rule fires is not itself a portability bug.

A shell script commonly embeds a whole python program in a heredoc
(`python3 - <<'PY' ... PY`, this repo's convention -- see lib/comment-tells.sh,
lib/failure-tells.sh, and dozens more). Detected by `python3`/`python` appearing on the
heredoc's opening line, that body is scanned under the PYTHON rules instead of the shell
ones; the shell code introducing it (everything before the `<<`) still gets the shell
rules. Any OTHER heredoc body is data -- a jq program, JSON, prompt text -- and is not
scanned as shell, matching lib/failure-tells.py's own convention for the same reason: it
is not this file's language, and reading it as one manufactures findings against code
that was never written.

A line carrying `# portability: <reason>` is never reported, the same per-line escape
convention as `# noqa`/`# type: ignore` elsewhere in this tree (lib/adk-install.sh).
"""

from __future__ import print_function

import os
import re
import shlex
import sys

MARKER = re.compile(r"#\s*portability:\s*\S")

# `<<-?` then a bare, single-, or double-quoted tag. The negative lookaround keeps a
# here-string (`<<<`) from being misread as an empty-tag heredoc.
HEREDOC_OPEN = re.compile(
    r"(?<!<)<<-?(?!<)\s*(?:\"([A-Za-z_]\w*)\"|'([A-Za-z_]\w*)'|([A-Za-z_]\w*))"
)
PYTHON_INVOKER = re.compile(r"\bpython3?\b")

CONTROL_OP = re.compile(r"&&|\|\||[|;]")
ENV_ASSIGN = re.compile(r"^[A-Za-z_]\w*=")
SKIP_PREFIX = frozenset(("sudo", "exec", "time", "env"))

LANGUAGES = {".sh": "shell", ".bash": "shell", ".py": "python"}


# ---------------------------------------------------------------------------
# Shell: comment stripping and command/argument parsing
# ---------------------------------------------------------------------------

def strip_shell_comment(line):
    """Cut a shell line at its real `#` comment, tracking quotes just well enough to
    not mistake one inside a string for the genuine article. Quoted text is otherwise
    left intact -- unlike a prose comment, a quoted argument is real invocation data
    a rule may need to read (mktemp's template, sed -i's attached suffix)."""
    quote = None
    i = 0
    while i < len(line):
        ch = line[i]
        if quote:
            if ch == "\\" and quote == '"' and i + 1 < len(line):
                i += 2
                continue
            if ch == quote:
                quote = None
            i += 1
            continue
        if ch in ("'", '"'):
            quote = ch
            i += 1
            continue
        if ch == "#" and (i == 0 or line[i - 1].isspace()):
            return line[:i]
        i += 1
    return line


def clauses(code_line):
    """A line's pipeline/list segments -- what a portability rule scoped to one
    command must not read across (`readlink foo && sed -i bar` is two commands,
    and a flag meant for one must never be credited to the other)."""
    return CONTROL_OP.split(code_line)


def command_tokens(clause):
    """A clause's words, with a leading `VAR=value` prefix or a transparent wrapper
    (`sudo`, `time`, `env`, `exec`) skipped so the real command lands at index 0.
    Malformed quoting (a stray `'` from something this parser does not understand)
    falls back to a plain split rather than raising -- a rule that cannot parse a
    line reports nothing about it, which is the fail-safe direction here."""
    try:
        tokens = shlex.split(clause, posix=True)
    except ValueError:
        tokens = clause.split()
    i = 0
    while i < len(tokens) and (ENV_ASSIGN.match(tokens[i]) or tokens[i] in SKIP_PREFIX):
        i += 1
    return tokens[i:]


def clause_command(clause):
    tokens = command_tokens(clause)
    return (tokens[0], tokens[1:]) if tokens else (None, [])


def command_substitutions(text):
    """Every `$( ... )` body, nesting included -- `x=$(sed -i ... "$(mktemp ...)")`
    has two commands in it, and neither is `x=$(sed`, which is what a plain
    whitespace/quote tokenizer sees without this. Returns the inner text only;
    the caller re-clauses it exactly like any other shell text."""
    found = []
    i, n = 0, len(text)
    while i < n:
        if text[i] == "$" and i + 1 < n and text[i + 1] == "(":
            depth = 1
            j = i + 2
            start = j
            while j < n and depth > 0:
                if text[j] == "(":
                    depth += 1
                elif text[j] == ")":
                    depth -= 1
                j += 1
            inner = text[start:j - 1] if depth == 0 else text[start:]
            found.append(inner)
            found.extend(command_substitutions(inner))
            i = j
        else:
            i += 1
    return found


def command_texts(code_line):
    """The line itself, plus every command substitution inside it, each ready to
    be split into clauses on its own."""
    return [code_line] + command_substitutions(code_line)


def mask_shell_spans(line, blank_double):
    """A same-width view of a comment-stripped shell line with every single-quoted
    span blanked (bash never expands inside single quotes -- real code or a test
    label describing one, `'${var,,}'` does nothing either way) and a
    backslash-escaped `$` blanked too (`\\$` is always literal, in or out of double
    quotes -- how a label spells the construct without invoking it). Double-quoted
    spans are ALSO blanked when `blank_double` is set, for the handful of bash-4
    keywords (`mapfile`, `coproc`, ...) that can never legitimately sit inside a
    string; the parameter-expansion patterns (`${var,,}`, a negative array index)
    are the opposite -- `echo "${var,,}"` is their normal, correct, double-quoted
    shape, so blanking there would miss the real thing to dodge a rarer false one."""
    result = list(line)
    i, n = 0, len(line)
    quote = None
    while i < n:
        ch = line[i]
        # `\$` is always literal -- inside double quotes, inside single quotes (where
        # backslash is not even special, but blanking it here is harmless), or bare --
        # so it is blanked unconditionally, before quote state gets a say.
        if ch == "\\" and i + 1 < n and line[i + 1] == "$":
            result[i] = result[i + 1] = " "
            i += 2
            continue
        if quote:
            if ch == "\\" and quote == '"' and i + 1 < n:
                if blank_double:
                    result[i] = result[i + 1] = " "
                i += 2
                continue
            if ch == quote:
                quote = None
                i += 1
                continue
            if quote == "'" or blank_double:
                result[i] = " "
            i += 1
            continue
        if ch in ("'", '"'):
            quote = ch
            i += 1
            continue
        i += 1
    return "".join(result)


# ---------------------------------------------------------------------------
# Shell: bash >= 4 syntax (no external command involved)
# ---------------------------------------------------------------------------

# Bare keywords/operators: never legitimately inside a string, so both quote kinds
# are blanked before matching (a description of `mapfile` in a label is not a use
# of it).
BASH4_KEYWORDS = (
    ("mapfile", re.compile(r"\bmapfile\b"),
     "mapfile needs bash >= 4 (macOS ships bash 3.2)"),
    ("readarray", re.compile(r"\breadarray\b"),
     "readarray needs bash >= 4 (macOS ships bash 3.2)"),
    ("pipe-amp", re.compile(r"(?<!\|)\|&(?!&)"),
     "|& needs bash >= 4"),
    ("append-both", re.compile(r"&>>"),
     "&>> needs bash >= 4"),
    ("coproc", re.compile(r"\bcoproc\b"),
     "coproc needs bash >= 4"),
)

# Parameter expansions: normally used inside double quotes (`echo "${var,,}"`), so
# only single quotes and an escaped `$` are blanked -- a real double-quoted use must
# still be caught.
BASH4_EXPANSIONS = (
    ("negative-index", re.compile(r"\$\{[A-Za-z_]\w*\[-\d+\]"),
     "a negative array subscript needs bash >= 4"),
    ("case-modification",
     re.compile(r"\$\{[A-Za-z_]\w*(?:\[[^\]]*\])?(?:\^\^|,,|\^|,)[^}]*\}"),
     "${var^^}/${var,,} case modification needs bash >= 4"),
)


def declare_assoc(code_line):
    for text in command_texts(code_line):
        for clause in clauses(text):
            cmd, args = clause_command(clause)
            if cmd in ("declare", "local", "typeset"):
                for arg in args:
                    if re.match(r"^-[A-Za-z]*A[A-Za-z]*$", arg):
                        return True
    return False


def read_preload(code_line):
    for text in command_texts(code_line):
        for clause in clauses(text):
            cmd, args = clause_command(clause)
            if cmd == "read":
                for arg in args:
                    if re.match(r"^-[A-Za-z]*i[A-Za-z]*$", arg):
                        return True
    return False


# ---------------------------------------------------------------------------
# Shell: GNU-coreutils-only flags (BSD/macOS ships a different implementation)
# ---------------------------------------------------------------------------

def _leading_flags(args):
    """The prefix of `args` that are still option tokens -- everything from the
    first non-option token on belongs to whatever xargs execs, not to xargs."""
    leading = []
    for arg in args:
        if not arg.startswith("-"):
            break
        leading.append(arg)
    return leading


def _flag(args, short=None, long_prefix=None, pattern=None):
    for arg in args:
        if short is not None and arg == short:
            return True
        if long_prefix is not None and arg.startswith(long_prefix):
            return True
        if pattern is not None and pattern.match(arg):
            return True
    return False


def sed_findings(args):
    findings = []
    if _flag(args, short="-r") or _flag(args, long_prefix="--regexp-extended"):
        findings.append(("sed-extended-r", "sed -r is GNU-only; -E works on both"))
    for i, arg in enumerate(args):
        if arg == "-i":
            following = args[i + 1] if i + 1 < len(args) else None
            if following == "":
                findings.append((
                    "sed-inplace-empty-suffix",
                    "sed -i '' is BSD-only; GNU sed reads '' as the script -- "
                    "write to a temp file and mv instead",
                ))
            else:
                findings.append((
                    "sed-inplace",
                    "sed -i with no suffix is GNU-only; BSD needs sed -i '' or sed -i.bak",
                ))
            break
    return findings


def mktemp_findings(args):
    findings = []
    has_t = "-t" in args
    has_suffix = _flag(args, long_prefix="--suffix")
    if has_t and has_suffix:
        findings.append((
            "mktemp-suffix",
            "mktemp -t with --suffix is not portable; BSD mktemp -t ignores --suffix",
        ))
    template = next((a for a in args if not a.startswith("-")), None)
    if template is not None and not re.search(r"X{3,}$", template):
        findings.append((
            "mktemp-template",
            "mktemp's template must end in >= 3 X's for BSD mktemp to accept it",
        ))
    return findings


COMMAND_RULES = {
    "sed": sed_findings,
    "readlink": lambda args: (
        [("readlink-canonicalize", "readlink -f/-e/-m is GNU-only (no -f on macOS)")]
        if _flag(args, pattern=re.compile(r"^-[a-zA-Z]*[fem][a-zA-Z]*$")) else []
    ),
    "mktemp": mktemp_findings,
    "date": lambda args: (
        [("date-parse", "date -d/--date is GNU-only")]
        if _flag(args, short="-d", long_prefix="--date") else []
    ),
    "stat": lambda args: (
        [("stat-format", "stat -c/--format is GNU-only; BSD stat uses -f")]
        if _flag(args, short="-c", long_prefix="--format") else []
    ),
    "grep": lambda args: (
        [("grep-perl", "grep -P/--perl-regexp is GNU-only")]
        if _flag(args, short="-P", long_prefix="--perl",
                 pattern=re.compile(r"^-[a-zA-Z]*P[a-zA-Z]*$")) else []
    ),
    "sort": lambda args: (
        [("sort-version", "sort -V is GNU-only (absent from BSD sort)")]
        if _flag(args, short="-V", pattern=re.compile(r"^-[a-zA-Z]*V[a-zA-Z]*$")) else []
    ),
    "cp": lambda args: (
        [("cp-parents", "cp --parents is GNU-only")]
        if _flag(args, long_prefix="--parents") else []
    ),
    "find": lambda args: (
        [("find-printf", "find -printf is GNU-only")]
        if _flag(args, short="-printf") else []
    ),
    # xargs's OWN flags only, not the utility it invokes -- `xargs -r git tag -d x`
    # has a `-d` that belongs to `git tag`, and xargs's own options can only ever
    # precede the utility name (xargs's own grammar, not this parser's guess).
    "xargs": lambda args: (
        [("xargs-delim", "xargs -d/--delimiter is GNU-only")]
        if _flag(_leading_flags(args), short="-d", long_prefix="--delimiter") else []
    ),
}

# `timeout`/`flock` are absent from a stock macOS install (not a GNU-flag question --
# the binary itself is missing) and are only worth a WARNING, and only unguarded in
# shipped code: a test proving this probe catches them is not itself a bug, and a repo
# that already checked `command -v timeout` has made its own portability call.
NO_FALLBACK_COMMANDS = ("timeout", "flock")


def self_guarded(text, cmd):
    """True when `cmd` is invoked in two or more `||` branches of the same text --
    the `stat -c ... || stat -f ... || date -u +%s` shape (lib/cycle-result.sh) that
    IS this plugin's own portable idiom for a GNU/BSD split. A command tried once and
    never retried under a different flag is not a fallback; flagging the one that
    already handles both platforms would teach people to ignore this probe."""
    hits = 0
    for branch in re.split(r"\|\|", text):
        if any(clause_command(clause)[0] == cmd for clause in clauses(branch)):
            hits += 1
            if hits >= 2:
                return True
    return False


def shell_line_findings(code_line):
    """(rule, reason) pairs in one already comment-stripped line of real shell code."""
    findings = []
    keyword_view = mask_shell_spans(code_line, blank_double=True)
    for name, pattern, reason in BASH4_KEYWORDS:
        if pattern.search(keyword_view):
            findings.append((name, reason))
    expansion_view = mask_shell_spans(code_line, blank_double=False)
    for name, pattern, reason in BASH4_EXPANSIONS:
        if pattern.search(expansion_view):
            findings.append((name, reason))
    if declare_assoc(code_line):
        findings.append(("declare-assoc", "declare/local -A needs bash >= 4"))
    if read_preload(code_line):
        findings.append(("read-preload", "read -i needs bash >= 4"))
    for text in command_texts(code_line):
        for clause in clauses(text):
            cmd, args = clause_command(clause)
            if not cmd or self_guarded(text, cmd):
                continue
            if cmd == "realpath":
                findings.append(("realpath", "realpath is not shipped on macOS/BSD by default"))
            checker = COMMAND_RULES.get(cmd)
            if checker:
                findings.extend(checker(args))
    return findings


def invoked_commands(code_line):
    """Every command name this line actually runs, substitutions included, for the
    file-scoped timeout/flock fallback check."""
    return [cmd for text in command_texts(code_line) for clause in clauses(text)
            for cmd in (clause_command(clause)[0],) if cmd]


# ---------------------------------------------------------------------------
# Python: comment/string masking (docstrings and prose must not seed a finding)
# ---------------------------------------------------------------------------

def mask_python(lines, blank_inline_strings=True):
    """One same-width line per input line, with `#` comments and every triple-quoted
    span (docstrings, which can carry line-spanning example code) blanked out always.
    A rule that matched inside a docstring's example, or a string that happens to
    spell `os.sched_getaffinity`, would be reporting on prose -- not on a construct
    this file actually executes.

    Single-line `'...'`/`"..."` strings are blanked too UNLESS `blank_inline_strings`
    is false: the f-string debug-specifier rule needs to read what is actually inside
    the braces of an f-string, which is real syntax the interpreter evaluates, not
    prose -- the same distinction lib/portability_scan.py's shell side draws for a
    quoted mktemp template or a sed -i suffix."""
    masked = []
    triple = None
    for text in lines:
        result = list(text)
        i = 0
        quote = None
        if triple:
            end = text.find(triple)
            if end == -1:
                masked.append(" " * len(text))
                continue
            for k in range(end + 3):
                result[k] = " "
            i = end + 3
            triple = None
        while i < len(text):
            if quote:
                if text.startswith(quote, i):
                    if blank_inline_strings:
                        result[i] = " "
                    i += 1
                    quote = None
                elif text[i] == "\\" and i + 1 < len(text):
                    if blank_inline_strings:
                        result[i] = result[i + 1] = " "
                    i += 2
                else:
                    if blank_inline_strings:
                        result[i] = " "
                    i += 1
                continue
            if text.startswith(("'''", '"""'), i):
                tq = text[i:i + 3]
                closing = text.find(tq, i + 3)
                if closing == -1:
                    for k in range(i, len(text)):
                        result[k] = " "
                    triple = tq
                    i = len(text)
                    break
                for k in range(i, closing + 3):
                    result[k] = " "
                i = closing + 3
                continue
            if text[i] == "#":
                for k in range(i, len(text)):
                    result[k] = " "
                break
            if text[i] in ("'", '"'):
                quote = text[i]
                if blank_inline_strings:
                    result[i] = " "
                i += 1
                continue
            i += 1
        masked.append("".join(result))
    return masked


PY_WALRUS = re.compile(r":=")
PY_MATCH_HEAD = re.compile(r"^(\s*)match\s+[^=:{}]*:\s*$")
PY_REMOVEPREFIX = re.compile(r"\.removeprefix\(")
PY_REMOVESUFFIX = re.compile(r"\.removesuffix\(")
# The unambiguous shape only: at least one side spelled as a literal `{...}` (or a
# `dict(...)` call), because `a | b` alone is indistinguishable from an int or set
# union without type information this probe does not have. Narrower recall, but a
# rule that cannot tell dict-union from set-union should say nothing rather than guess.
PY_DICT_MERGE = re.compile(r"\}\s*\|\s*\{|\}\s*\|\s*\w+\(\)|\)\s*\|\s*\{")
PY_DEF = re.compile(r"\bdef\s+\w+\s*\(([^()]*)\)")
PY_SCHED = re.compile(r"\bos\.sched_\w+")
PY_SIGRTMIN = re.compile(r"\bsignal\.SIGRTMIN\w*\b")
PY_FSTRING_DEBUG = re.compile(r"""f['"][^'"\n]*\{[^{}=!<>]+=(?=[}:!])""")


def python_line_findings(line, fstring_view):
    findings = []
    if PY_WALRUS.search(line):
        findings.append(("walrus", "the walrus operator := needs python >= 3.8"))
    if PY_REMOVEPREFIX.search(line):
        findings.append(("removeprefix", "str.removeprefix needs python >= 3.9"))
    if PY_REMOVESUFFIX.search(line):
        findings.append(("removesuffix", "str.removesuffix needs python >= 3.9"))
    if PY_DICT_MERGE.search(line):
        findings.append(("dict-merge", "dict | dict merge needs python >= 3.9"))
    def_match = PY_DEF.search(line)
    if def_match and "/" in [p.strip() for p in def_match.group(1).split(",")]:
        findings.append(("positional-only", "a positional-only `/` parameter needs python >= 3.8"))
    if PY_SCHED.search(line):
        findings.append(("sched-affinity", "os.sched_* is Linux-only (absent on macOS)"))
    if PY_SIGRTMIN.search(line):
        findings.append(("sigrtmin", "signal.SIGRTMIN is Linux-only (absent on macOS)"))
    if PY_FSTRING_DEBUG.search(fstring_view):
        findings.append(("fstring-debug", "the f-string {expr=} specifier needs python >= 3.8"))
    return findings


def match_statement_lines(masked_lines):
    """Indices of a real `match` STATEMENT -- not `re.match(...)`, not a variable
    named `match` -- confirmed by a `case` block actually following it, so a plain
    identifier or method call ending in a colon-shaped slice never qualifies."""
    hits = []
    total = len(masked_lines)
    for i, line in enumerate(masked_lines):
        head = PY_MATCH_HEAD.match(line)
        if not head:
            continue
        indent = len(head.group(1))
        for j in range(i + 1, total):
            following = masked_lines[j]
            if not following.strip():
                continue
            if (len(following) - len(following.lstrip()) > indent
                    and following.lstrip().startswith("case ")):
                hits.append(i)
            break
    return hits


def scan_python_lines(lines):
    """(offset, rule, reason, snippet) for a python source, given as a list of raw
    lines (offset 0 = first line of that list, whether it is a whole file or a
    heredoc body)."""
    masked = mask_python(lines)
    fstring_views = mask_python(lines, blank_inline_strings=False)
    findings = []
    for i, line in enumerate(masked):
        for rule, reason in python_line_findings(line, fstring_views[i]):
            findings.append((i, rule, reason, lines[i].strip()))
    for i in match_statement_lines(masked):
        findings.append((i, "match-stmt", "the match statement needs python >= 3.10",
                          lines[i].strip()))
    return findings


# ---------------------------------------------------------------------------
# Per-file drivers
# ---------------------------------------------------------------------------

def scan_shell_file(path, lines):
    findings = []          # (lineno, rule, reason, snippet)
    marker_lines = set()
    timeout_lines = {name: [] for name in NO_FALLBACK_COMMANDS}
    guarded = {name: False for name in NO_FALLBACK_COMMANDS}
    full_text = "\n".join(lines)
    for name in NO_FALLBACK_COMMANDS:
        if re.search(r"\b(?:command\s+-v|type|which)\s+" + re.escape(name) + r"\b", full_text):
            guarded[name] = True

    py_blocks = []          # (start_index, body_lines) deferred until after the main pass
    i = 0
    n = len(lines)
    while i < n:
        raw = lines[i]
        if MARKER.search(raw):
            marker_lines.add(i)
        code = strip_shell_comment(raw)
        opener = HEREDOC_OPEN.search(code)
        if opener:
            tag = next(g for g in opener.groups() if g)
            pre = code[:opener.start()]
            for rule, reason in shell_line_findings(pre):
                findings.append((i, rule, reason, raw.strip()))
            for cmd in invoked_commands(pre):
                if cmd in timeout_lines:
                    timeout_lines[cmd].append(i)
            is_python = bool(PYTHON_INVOKER.search(pre))
            body_start = i + 1
            j = body_start
            while j < n and lines[j].strip() != tag:
                j += 1
            if is_python:
                py_blocks.append((body_start, lines[body_start:j]))
            i = j + 1 if j < n else j
            continue
        for rule, reason in shell_line_findings(code):
            findings.append((i, rule, reason, raw.strip()))
        for cmd in invoked_commands(code):
            if cmd in timeout_lines:
                timeout_lines[cmd].append(i)
        i += 1

    shipped = re.search(r"(^|/)(lib|hooks)/", path) is not None
    if shipped:
        for name, lines_hit in timeout_lines.items():
            if guarded[name]:
                continue
            for lineno in lines_hit:
                findings.append((lineno, "{}-no-fallback".format(name),
                                  "{} is absent from a stock macOS install with nothing "
                                  "here to fall back to".format(name), lines[lineno].strip(),
                                  "warning"))

    for start, body in py_blocks:
        for offset, rule, reason, snippet in scan_python_lines(body):
            lineno = start + offset
            if MARKER.search(lines[lineno]):
                marker_lines.add(lineno)
            findings.append((lineno, rule, reason, snippet))

    return [f for f in findings if f[0] not in marker_lines]


def scan_py_file(path, lines):
    marker_lines = {i for i, line in enumerate(lines) if MARKER.search(line)}
    findings = []
    for offset, rule, reason, snippet in scan_python_lines(lines):
        if offset in marker_lines:
            continue
        findings.append((offset, rule, reason, snippet))
    return findings


def scan(path, text):
    """Every finding in one file: (lineno [1-based], rule, reason, snippet, severity).
    `severity` is "" for an ordinary (blocking) finding and "warning" for the
    timeout/flock fallback check."""
    ext = os.path.splitext(path)[1].lower()
    language = LANGUAGES.get(ext)
    if not language:
        return None
    lines = text.splitlines()
    raw = scan_shell_file(path, lines) if language == "shell" else scan_py_file(path, lines)
    out = []
    for entry in raw:
        lineno, rule, reason, snippet = entry[:4]
        severity = entry[4] if len(entry) > 4 else ""
        out.append((lineno + 1, rule, reason, snippet[:100], severity))
    return sorted(set(out))


def read(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError:
        return None


def main(argv):
    if not argv:
        print("usage: portability_scan.py <file> [file ...]", file=sys.stderr)
        return 2

    total, scanned, skipped = 0, 0, 0
    for path in argv:
        ext = os.path.splitext(path)[1].lower()
        if ext not in LANGUAGES:
            skipped += 1
            continue
        text = read(path)
        if text is None:
            print("portability-scan: cannot read {}".format(path), file=sys.stderr)
            return 2
        scanned += 1
        for lineno, rule, reason, snippet, severity in scan(path, text):
            tag = "tell={} severity={}".format(rule, severity) if severity else "tell={}".format(rule)
            print("{}:{}: {}: {} ({})".format(path, lineno, tag, snippet, reason))
            total += 1

    reason = "{} file(s)".format(scanned)
    if skipped:
        reason += ", {} skipped (not .sh/.bash/.py)".format(skipped)
    if total:
        print("portability-scan: {} finding(s) ({})".format(total, reason))
        return 1
    print("portability-scan: clean ({})".format(reason))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
