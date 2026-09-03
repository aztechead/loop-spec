#!/usr/bin/env python3
"""Name the third-party dependencies a set of files actually imports.

lib/doc-deps.sh owns argument and path setup; this module owns the matching. The
question it answers is narrow: of everything the repo's manifests declare, which
dependencies do THESE files import? That intersection is the list whose current
documentation a design phase must consult (skills/shared/grounding-protocol.md,
"Current documentation") -- the whole manifest would be context bloat, and raw
imports alone would name the stdlib. Unknown languages, unreadable files, and
absent manifests shrink the answer instead of erroring: the probe fails safe, so
the gate's demand is never larger than what the tree could prove.
"""

from __future__ import print_function

import json
import os
import re
import sys

PY_FROM = re.compile(r"^\s*from\s+([A-Za-z_][\w.]*)\s+import")
PY_IMPORT = re.compile(r"^\s*import\s+(.+)$")
JS_SPECIFIER = re.compile(
    r"""(?:from\s+|require\(\s*|import\(\s*|^\s*import\s+)['"]([^'"]+)['"]""",
    re.M,
)
GO_SINGLE = re.compile(r'^\s*import\s+(?:\w+\s+)?"([^"]+)"', re.M)
GO_BLOCK = re.compile(r"^import\s*\(([^)]*)\)", re.M | re.S)
GO_QUOTED = re.compile(r'"([^"]+)"')
# A requirement spec's name stops at the first extra/version/marker character.
REQ_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*")
PYPROJECT_SELF = re.compile(r'^name\s*=\s*["\']([A-Za-z0-9._-]+)["\']', re.M)

PY_EXTS = (".py",)
JS_EXTS = (".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs")
GO_EXTS = (".go",)


def norm(name):
    """PEP 503-style: 'google-adk', 'google_adk', and 'google.adk' are one name."""
    return re.sub(r"[-_.]+", "_", name.lower())


def read_text(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return None


def manifest_dirs(files, root):
    """Every directory from each file up to the repo root, nearest first.

    Workspace mode hands paths like <repo>/<path> with the workspace root as cwd,
    so the walk finds each repo's own manifest before any shared one.
    """
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


def declared_deps(dirs):
    """(python: norm->display, js: exact names, go: module paths) from manifests."""
    py, js, go = {}, set(), []
    for d in dirs:
        pkg = read_text(os.path.join(d, "package.json"))
        if pkg:
            try:
                data = json.loads(pkg)
            except ValueError:
                data = {}
            for key in ("dependencies", "devDependencies", "peerDependencies"):
                js.update((data.get(key) or {}).keys())
        try:
            entries = os.listdir(d)
        except OSError:
            entries = []
        for name in entries:
            if name.startswith("requirements") and name.endswith(".txt"):
                text = read_text(os.path.join(d, name)) or ""
                for line in text.splitlines():
                    line = line.strip()
                    if not line or line.startswith(("#", "-")):
                        continue
                    m = REQ_NAME.match(line)
                    if m:
                        py.setdefault(norm(m.group(0)), m.group(0))
        pyproject = read_text(os.path.join(d, "pyproject.toml"))
        if pyproject:
            # ponytail: quoted requirement specs anywhere in the file, no TOML
            # parse (tomllib needs 3.11; runtime floor is 3.7). Over-collecting
            # is bounded by the import intersection; the project's own name is
            # excluded so a src-layout self-import never demands its own docs.
            own = {norm(m) for m in PYPROJECT_SELF.findall(pyproject)}
            for spec in re.findall(r'["\']([A-Za-z0-9][A-Za-z0-9._-]*)\s*[<>=!~\["\']', pyproject):
                if norm(spec) not in own:
                    py.setdefault(norm(spec), spec)
        gomod = read_text(os.path.join(d, "go.mod"))
        if gomod:
            for m in re.finditer(r"^\s*(?:require\s+)?([\w.\-/]+\.[\w\-]+/[\w.\-/]+)\s+v[\d.]", gomod, re.M):
                go.append(m.group(1))
    return py, js, go


def file_imports(path):
    """(python modules, js specifiers, go import paths) this one file names."""
    text = read_text(path)
    if text is None:
        return [], [], []
    ext = os.path.splitext(path)[1].lower()
    if ext in PY_EXTS:
        mods = []
        for line in text.splitlines():
            m = PY_FROM.match(line)
            if m:
                mods.append(m.group(1))
                continue
            m = PY_IMPORT.match(line)
            if m:
                for part in m.group(1).split(","):
                    part = part.strip().split(" as ")[0].split()[0] if part.strip() else ""
                    if part and (part[0].isalpha() or part[0] == "_"):
                        mods.append(part)
        return mods, [], []
    if ext in JS_EXTS:
        return [], JS_SPECIFIER.findall(text), []
    if ext in GO_EXTS:
        paths = GO_SINGLE.findall(text)
        for block in GO_BLOCK.findall(text):
            paths.extend(GO_QUOTED.findall(block))
        return [], [], paths
    return [], [], []


def scan_deps(files):
    """Sorted display names of every declared dependency the files import."""
    files = [f for f in files if os.path.isfile(f)]
    if not files:
        return [], "no readable input files"
    py, js, go = declared_deps(manifest_dirs(files, os.getcwd()))
    if not (py or js or go):
        return [], "no manifests found between the files and the repo root"
    hits = set()
    for f in files:
        py_mods, js_specs, go_paths = file_imports(f)
        for mod in py_mods:
            segs = mod.split(".")
            for cand in (norm(segs[0]), norm("_".join(segs[:2]))):
                if cand in py:
                    hits.add(py[cand])
        for spec in js_specs:
            if spec.startswith((".", "/", "node:")):
                continue
            segs = spec.split("/")
            pkg = "/".join(segs[:2]) if spec.startswith("@") else segs[0]
            if pkg in js:
                hits.add(pkg)
        for path in go_paths:
            for mod in go:
                if path == mod or path.startswith(mod + "/"):
                    hits.add(mod)
    reason = "imports of %d file(s) intersected with declared dependencies" % len(files)
    return sorted(hits), reason


def resolve_deps(files):
    """Operator override outranks the scan (CLAUDE.md probe contract)."""
    override = os.environ.get("LOOP_SPEC_DOC_DEPS")
    if override is not None:
        deps = [] if override.strip() in ("", "none") else [
            d.strip() for d in override.split(",") if d.strip()
        ]
        return deps, "operator override (LOOP_SPEC_DOC_DEPS)"
    return scan_deps(files)


def grounding_text(artifact_text):
    """The visible (non-comment) text of the ## Grounding section, or None."""
    lines = artifact_text.splitlines()
    start = next(
        (i for i, l in enumerate(lines) if re.match(r"^##\s+Grounding(\s|$)", l)), None
    )
    if start is None:
        return None
    body, in_comment = [], False
    for line in lines[start + 1:]:
        if re.match(r"^##\s", line):
            break
        if in_comment:
            in_comment = "-->" not in line
            continue
        if "<!--" in line:
            in_comment = "-->" not in line
            continue
        body.append(line)
    return "\n".join(body)


def dep_pattern(dep):
    """'google-adk' also matches 'google_adk', 'google.adk', 'google adk'."""
    parts = [p for p in re.split(r"[-_./@\s]+", dep) if p]
    return re.compile(
        r"\b" + r"[-_./ ]?".join(re.escape(p) for p in parts) + r"\b", re.I
    )


def cmd_scan(files):
    deps, reason = resolve_deps(files)
    print("ANSWER=%s REASON=%s" % (",".join(deps) if deps else "none", reason))
    return 0


def cmd_gate(tasks_path, artifact):
    try:
        with open(tasks_path, "r", encoding="utf-8") as fh:
            tasks = json.load(fh)
        files = sorted({f for t in tasks for f in (t.get("files") or [])})
    except (OSError, ValueError, AttributeError, TypeError) as exc:
        # The tasks sidecar has its own gates (artifact-lint, phase-exit's
        # missing-file FLAG); an unreadable one here means no provable demand.
        print("doc-deps: ok (tasks unreadable, nothing to demand: %s)" % exc)
        return 0
    deps, reason = resolve_deps(files)
    if not deps:
        print("doc-deps: ok (%s)" % reason)
        return 0
    text = read_text(artifact)
    if text is None:
        print("FLAG %s:0: artifact not readable, so dependency grounding for %s cannot be checked"
              % (artifact, ", ".join(deps)))
        print("doc-deps: 1 FLAG(s)")
        return 1
    section = grounding_text(text)
    flags = 0
    for dep in deps:
        if section is not None and dep_pattern(dep).search(section):
            continue
        flags += 1
        print("FLAG %s:0: dependency '%s' is imported by planned files but has no bullet in "
              "## Grounding -- fetch its current docs and cite an EVID-NNN entry, or add "
              "'- ASSUMPTION: <claim> | verify: <command>' (skills/shared/grounding-protocol.md, "
              "Current documentation)" % (artifact, dep))
    if flags:
        print("doc-deps: %d FLAG(s) (%s)" % (flags, reason))
        return 1
    print("doc-deps: ok (%d dependenc%s covered)" % (len(deps), "y" if len(deps) == 1 else "ies"))
    return 0


def main(argv):
    if len(argv) >= 2 and argv[0] == "scan":
        return cmd_scan(argv[1:])
    if len(argv) == 5 and argv[0] == "gate" and argv[1] == "--tasks" and argv[3] == "--artifact":
        return cmd_gate(argv[2], argv[4])
    print("usage: doc-deps.py scan <file...> | gate --tasks <tasks.json> --artifact <PLAN.md>",
          file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
