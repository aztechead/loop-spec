#!/usr/bin/env python3
"""Decide the three markdown defects that are decidable from the text and the tree.

lib/doc-tells.sh owns argument and path setup; this module owns the rules, so the
matching is ordinary Python a reader can check rather than a regex buried in a
heredoc. Each rule answers a question about the READER's next move -- can they
follow this link, open this file, run this command -- and stays silent whenever
the answer needs a judgment instead of a lookup.
"""

from __future__ import print_function

import os
import re
import subprocess
import sys

MARKDOWN = (".md", ".markdown")
# A changelog records what WAS true at each release; a path it names is history,
# not rot, and every entry would flag the day the file it mentions is renamed.
HISTORICAL = re.compile(r"^(?:changelog|history|news|releases)(?:\.[a-z]+)?$", re.I)

FENCE = re.compile(r"^\s{0,3}(`{3,}|~{3,})\s*(\S*)")
INLINE_LINK = re.compile(r"\[[^\]^]*\]\(\s*<?([^)>\s]+)>?(?:\s+[\"'][^\"']*[\"'])?\s*\)")
REFERENCE_LINK = re.compile(r"^\s{0,3}\[[^\]]+\]:\s*<?(\S+)>?")
CODE_SPAN = re.compile(r"`([^`\n]+)`")

# A path a reader could open: at least one slash, no spaces, and none of the
# characters that mark a template (`{slug}`), a glob (`*.sh`), or a placeholder.
PATHISH = re.compile(r"^[A-Za-z0-9_.+-]+(?:/[A-Za-z0-9_.+-]+)+$")
LINE_ANCHOR = re.compile(r":\d+(?:-\d+)?$")
DOMAIN = re.compile(r"^[A-Za-z0-9-]+(?:\.[A-Za-z]{2,})+$")

# Only a block a reader is meant to TYPE can hold an unrunnable command. A `json`
# or `text` block is data, and `<placeholder>` inside it is illustration.
COMMAND_LANGUAGES = frozenset(
    ("bash", "sh", "shell", "zsh", "console", "shell-session", "command", "sh-session")
)
PLACEHOLDER = re.compile(
    r"<([A-Za-z][A-Za-z0-9_.-]*)>"
    r"|\b(YOUR[_-][A-Za-z0-9_-]+)\b"
    r"|\bpath/to/([A-Za-z0-9_.-]+)"
)
# Words too generic to prove anything either way: a prose hit on "file" says
# nothing about whether the reader knows what to substitute, so a placeholder
# whose every word is here is left alone rather than guessed at.
GENERIC = frozenset(
    """
    and dir directory file files for from here name names path paths some the
    this value values with your
    """.split()
)
WORD = re.compile(r"[A-Za-z0-9]+")

# A doc that names a path BECAUSE it is gone is correct, and the sentence says so
# in a small number of ways. Read across the neighbouring lines: the verdict often
# follows the list it applies to ("... none of them do").
ABSENCE = re.compile(
    r"\b(?:no longer|not exist|never existed|none of (?:them|these)|absent|deleted|"
    r"removed|dropped|gone|renamed|replaced by|superseded|found false|used to (?:be|live))\b",
    re.I,
)


def split_fences(lines):
    """Separate prose from fenced blocks in one pass.

    Returns (outside, blocks): `outside` is every (lineno, text) a reader reads as
    prose, `blocks` is one (info_string, [(lineno, text)]) per fenced block. Every
    rule below needs the same split, and a link or a path inside a fence is an
    example rather than a reference the reader is expected to follow."""
    outside, blocks = [], []
    fence, current = None, None
    for lineno, text in enumerate(lines, 1):
        match = FENCE.match(text)
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


def link_targets(text):
    """Every local link target on one prose line, already stripped of its
    fragment and title. Absolute paths and anything with a scheme belong to a web
    server or another machine -- this probe answers for files in the tree only."""
    for match in list(INLINE_LINK.finditer(text)) + list(REFERENCE_LINK.finditer(text)):
        target = match.group(1)
        if re.match(r"^[A-Za-z][A-Za-z0-9+.-]*:", target) or target.startswith(("#", "/", "//")):
            continue
        if any(mark in target for mark in ("{", "}", "$", "*", "<")):
            continue
        target = target.split("#", 1)[0].split("?", 1)[0]
        if target:
            yield target


def dead_links(doc_dir, outside):
    """A relative link whose target is not on disk. The reader clicks it, gets
    nothing, and now distrusts every other link on the page."""
    for lineno, text in outside:
        for target in link_targets(text):
            if not os.path.exists(os.path.join(doc_dir, target)):
                yield lineno, "dead-link", "{} (no such file from {}/)".format(
                    target, os.path.basename(doc_dir) or "."
                )


def stale_refs(doc_dir, repo_root, outside):
    """An inline-code path that no longer exists. This is documentation rot in its
    commonest form: the file moved, the doc kept pointing at where it used to be.

    The check fires only where the project already keeps files of that kind: the
    directory must exist AND git must track something with the same extension in
    it. That is what separates a file that moved from the two things that look
    identical in the text -- an example from another project (`app/models/user.rb`
    where there is no `app/`) and state the software writes at runtime."""
    if not repo_root:
        return
    kinds = tracked_kinds(repo_root)
    for index, (lineno, text) in enumerate(outside):
        # The cue must come from the PROSE: `lib/gone.sh` names a file whose own
        # path would otherwise read as its own obituary.
        context = CODE_SPAN.sub(" ", " ".join(
            line for _, line in outside[max(index - 1, 0):index + 2]
        ))
        for span in CODE_SPAN.findall(text):
            token = LINE_ANCHOR.sub("", span.strip())
            if not PATHISH.match(token) or token.startswith(".."):
                continue
            segments = token.split("/")
            if DOMAIN.match(segments[0]) or any(set(s) == {"."} for s in segments):
                continue
            if os.path.exists(os.path.join(repo_root, token)) or os.path.exists(
                os.path.join(doc_dir, token)
            ):
                continue
            directory = token.rpartition("/")[0]
            extension = os.path.splitext(token)[1].lower()
            # An extensionless token is as likely a directory or an event name
            # (`hooks/PreToolUse`) as a file, and neither is missing.
            if not extension or extension not in kinds.get(directory, ()):
                continue
            if ABSENCE.search(context):
                continue
            yield lineno, "stale-ref", "{} (absent, though {}/ tracks files like it)".format(
                token, directory
            )


def tracked_kinds(repo_root, _cache={}):
    """{directory: {extensions tracked directly in it}}.

    This is what separates a file that MOVED from a file that never existed. A
    directory git tracks `.sh` files in is a place this project keeps scripts, so
    a missing `.sh` there is rot. A directory that tracks none is where the
    software writes at runtime -- `.loop-spec/runtime.json` is documented
    precisely because no run has created it yet."""
    if repo_root not in _cache:
        kinds = {}
        try:
            out = subprocess.check_output(
                ["git", "-C", repo_root, "ls-files"], stderr=subprocess.DEVNULL
            ).decode("utf-8", "replace")
        except (subprocess.CalledProcessError, OSError):
            out = ""
        for tracked in out.splitlines():
            directory, _, base = tracked.rpartition("/")
            kinds.setdefault(directory, set()).add(os.path.splitext(base)[1].lower())
        _cache[repo_root] = kinds
    return _cache[repo_root]


def undefined_placeholders(outside, blocks):
    """A command the reader cannot run: it holds a placeholder the page never
    explains. `<repo-url>` is fine when the prose says which repository; it is a
    dead end when the only mention of it is inside the block itself."""
    prose = set()
    for _, text in outside:
        prose.update(word.lower() for word in WORD.findall(text))
    for info, block in blocks:
        if info not in COMMAND_LANGUAGES:
            continue
        for lineno, text in block:
            for match in PLACEHOLDER.finditer(text):
                token = match.group(0)
                name = next(group for group in match.groups() if group)
                words = {w.lower() for w in WORD.findall(name) if len(w) > 2}
                distinctive = words - GENERIC
                if distinctive and not distinctive & prose:
                    yield lineno, "undefined-placeholder", (
                        "{} (the prose never says what to substitute)".format(token)
                    )


def scan(path, text, repo_root):
    """Every finding in one document, sorted and de-duplicated."""
    lines = text.splitlines()
    outside, blocks = split_fences(lines)
    doc_dir = os.path.dirname(os.path.abspath(path)) or "."
    findings = list(dead_links(doc_dir, outside))
    findings += list(stale_refs(doc_dir, repo_root, outside))
    findings += list(undefined_placeholders(outside, blocks))
    return sorted(set(findings))


def repo_root_of(doc_dir):
    """The work tree the document sits in, or None outside a repository -- in
    which case stale-ref has nothing to check a path against and stays quiet."""
    try:
        root = subprocess.check_output(
            ["git", "-C", doc_dir, "rev-parse", "--show-toplevel"],
            stderr=subprocess.DEVNULL,
        )
    except (subprocess.CalledProcessError, OSError):
        return None
    return root.decode("utf-8", "replace").strip() or None


def read_at(path, rev):
    """Document text at `rev`, or from the work tree when no rev was given."""
    if rev:
        try:
            blob = subprocess.check_output(
                ["git", "show", "{}:{}".format(rev, path)], stderr=subprocess.DEVNULL
            )
        except (subprocess.CalledProcessError, OSError):
            return None
        return blob.decode("utf-8", "replace")
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError:
        return None


def added_lines(tsv_path):
    """Diff mode: {path: {lineno, ...}} for the markdown a change added lines to.
    Reporting the whole file would hand a change every defect the document
    already had; only what this change introduced is its own to answer for."""
    added = {}
    with open(tsv_path, "r", encoding="utf-8", errors="replace") as handle:
        for row in handle:
            parts = row.rstrip("\n").split("\t", 2)
            if len(parts) == 3 and parts[0].lower().endswith(MARKDOWN):
                added.setdefault(parts[0], set()).add(int(parts[1]))
    return added


def main(argv):
    rev, skipped = None, 0
    if "--rev" in argv:
        index = argv.index("--rev")
        rev = argv[index + 1]
        argv = argv[:index] + argv[index + 2:]

    if argv[:1] == ["--tsv"]:
        keep = added_lines(argv[1])
        candidates = sorted(keep)
    else:
        keep = None
        candidates = argv

    paths = []
    for path in candidates:
        if path.lower().endswith(MARKDOWN) and not HISTORICAL.match(os.path.basename(path)):
            paths.append(path)
        else:
            skipped += 1

    total, scanned = 0, 0
    for path in paths:
        text = read_at(path, rev)
        if text is None:
            if keep is not None:
                continue        # deleted or renamed by the change; nothing to read
            print("doc-tells: cannot read {}".format(path), file=sys.stderr)
            return 2
        scanned += 1
        root = repo_root_of(os.path.dirname(os.path.abspath(path)) or ".")
        for lineno, tell, detail in scan(path, text, root):
            if keep is not None and lineno not in keep[path]:
                continue
            print("{}:{}: tell={}: {}".format(path, lineno, tell, detail))
            total += 1

    reason = "{} file(s)".format(scanned)
    if skipped:
        reason += ", {} skipped (not markdown, or a changelog)".format(skipped)
    if total:
        print("doc-tells: {} finding(s) ({})".format(total, reason))
        return 1
    print("doc-tells: clean ({})".format(reason))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
