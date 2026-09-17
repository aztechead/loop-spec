#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
usage() { echo "usage: okf.sh check PATH [--type TYPE] | bundle-check DIR [--types JSON] | index DIR" >&2; exit 2; }
[[ $# -ge 1 ]] || usage
cmd="$1"; shift
case "$cmd" in
  check)
    [[ $# -ge 1 && $# -le 3 ]] || usage
    path="$1"; shift; expected=""
    if [[ $# -eq 2 && "$1" == "--type" ]]; then expected="$2"; else [[ $# -eq 0 ]] || usage; fi
    python3 - "$SCRIPT_DIR" "$path" "$expected" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from okf import read_metadata, validate_utf8
try:
    metadata = read_metadata(sys.argv[2])
    validate_utf8(sys.argv[2])
    if sys.argv[3] and metadata["type"] != sys.argv[3]:
        raise ValueError("expected type %r, found %r" % (sys.argv[3], metadata["type"]))
except (OSError, ValueError) as exc:
    print("okf: invalid: %s" % exc, file=sys.stderr); raise SystemExit(1)
print("okf: ok (%s)" % sys.argv[2])
PY
    ;;
  bundle-check)
    [[ $# -eq 1 || ( $# -eq 3 && "$2" == "--types" ) ]] || usage
    [[ -d "$1" ]] || usage
    types='{}'; [[ $# -eq 1 ]] || types="$3"
    python3 - "$SCRIPT_DIR" "$1" "$types" <<'PY'
import json, pathlib, sys
sys.path.insert(0, sys.argv[1])
from okf import read_metadata, validate_index, validate_log, validate_utf8
root = pathlib.Path(sys.argv[2]); errors = []
try:
    expected = json.loads(sys.argv[3])
    if not isinstance(expected, dict): raise ValueError("--types must be a JSON object")
except (ValueError, json.JSONDecodeError) as exc:
    print(f"okf: invalid --types mapping: {exc}", file=sys.stderr); raise SystemExit(2)
for path in sorted(root.rglob("*.md")):
    try:
        if path.name == "index.md": validate_index(path, path == root / "index.md")
        elif path.name == "log.md": validate_log(path)
        else:
            metadata = read_metadata(path); validate_utf8(path)
            required = expected.get(str(path.relative_to(root)))
            if required is not None and metadata.get("type") != required:
                raise ValueError("expected type %r, found %r" % (required, metadata.get("type")))
    except (OSError, ValueError) as exc: errors.append(f"{path}: {exc}")
if errors:
    print("\n".join(errors), file=sys.stderr); raise SystemExit(1)
print("okf: bundle ok (%s)" % root)
PY
    ;;
  index)
    [[ $# -eq 1 && -d "$1" ]] || usage
    python3 - "$SCRIPT_DIR" "$1" <<'PY'
import os, pathlib, sys, tempfile
from urllib.parse import quote
sys.path.insert(0, sys.argv[1])
from okf import read_metadata
root = pathlib.Path(sys.argv[2]); rows = []
for p in sorted(root.iterdir(), key=lambda x: x.name):
    if p.name in {"index.md", "log.md"}: continue
    if p.is_file() and p.suffix == ".md":
        try: md = read_metadata(p)
        except (OSError, ValueError) as exc: print(f"{p}: {exc}", file=sys.stderr); raise SystemExit(1)
        title = md.get("title") if isinstance(md.get("title"), str) and md.get("title").strip() else p.stem
        desc = md.get("description") if isinstance(md.get("description"), str) else ""
        title = " ".join(title.splitlines())
        desc = " ".join(desc.splitlines())
        rows.append((quote(str(p.relative_to(root))), title, desc))
    elif p.is_dir() and any(q.is_file() and q.suffix == ".md" and q.name not in {"index.md", "log.md"} for q in p.rglob("*")):
        rows.append((quote(p.name) + "/", p.name, ""))
body = "---\nokf_version: \"0.2\"\n---\n# Concepts\n"
for link, title, desc in rows:
    label = title.replace("\\", "\\\\")
    for char in "[]()*_": label = label.replace(char, "\\" + char)
    body += "\n* [%s](%s)%s\n" % (label, link, (" - " + desc) if desc else "")
fd, temp = tempfile.mkstemp(prefix=".index.", dir=str(root))
with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as fh: fh.write(body)
target = root / "index.md"
same = False
if target.exists() and target.stat().st_size == len(body.encode("utf-8")):
    same = target.read_text(encoding="utf-8") == body
if same: os.unlink(temp)
else: os.replace(temp, target)
print("okf: index written (%s)" % (root / "index.md"))
PY
    ;;
  *) usage ;;
esac
