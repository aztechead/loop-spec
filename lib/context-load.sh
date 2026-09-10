#!/usr/bin/env bash
# context-load.sh - How many lines a phase skill makes the lead read.
#
# Why: on the short route the lead read about 1,850 lines of skill and contract prose
# for a two-line fix, against the reference implementation's 475 for the same job. Each line adds cost
# on every turn (port audit 1, F3). Nothing measured
# it, so nothing could bound it. This probe sums the body and every file the body tells
# the lead to read, so a test can hold a path under a number.
#
# Usage:
#   context-load.sh sum   <entry> [entry ...] [--root DIR] [--transitive]
#       one `<lines>\t<path>` row per file read, then `TOTAL <n>`
#   context-load.sh cites <entry> [--root DIR] [--transitive]
#       the reading list, one entry per line
#
# An entry is a repository-relative markdown path, optionally `#<heading text>` to
# name one section (its lines run from the heading to the next heading of the same or
# a higher level). A cite is a backticked entry inside the body: `skills/shared/x.md`,
# `skills/shared/x.md#Heading`, `skills/shared/artifact-templates/y.md.template`, or
# `${CLAUDE_SKILL_DIR}/references/z.md` (resolved against the body's own skill dir).
# Scripts are executed, never read, so `lib/*.sh` paths are not cites. Depth is one:
# the body names every file the lead reads, and a mention inside a cited contract is a
# cross-reference the lead does not follow; --transitive follows them, for the number
# a reader who does follow everything would pay. A file is counted once.
#
# Exit: 0 answered; 2 bad invocation, unreadable root, or an entry that names a file or
# section the tree does not hold (named on stderr: a cite to nothing is the failure this
# probe must not average away).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cmd="${1:-}"; shift || true
case "$cmd" in sum|cites) ;; *) echo "usage: context-load.sh sum|cites <entry> [entry ...] [--root DIR] [--transitive]" >&2; exit 2 ;; esac
root="$SCRIPT_DIR/.."; transitive=0; entries=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) root="${2:-}"; shift 2 ;;
    --transitive) transitive=1; shift ;;
    *) entries+=("$1"); shift ;;
  esac
done
(( ${#entries[@]} >= 1 )) || { echo "usage: context-load.sh $cmd <entry> [entry ...] [--root DIR] [--transitive]" >&2; exit 2; }
[[ -d "$root" ]] || { echo "context-load.sh: root is not a directory: $root" >&2; exit 2; }

python3 - "$cmd" "$root" "$transitive" "${entries[@]}" <<'PY'
import os, re, sys
cmd, root, transitive = sys.argv[1], os.path.realpath(sys.argv[2]), sys.argv[3] == "1"
entries = sys.argv[4:]
CITE = re.compile(r"`((?:\$\{(?:LOOP_SPEC_SKILL_DIR|CLAUDE_SKILL_DIR)\}/references/|skills/)[A-Za-z0-9_./-]+?\.md(?:\.template)?)(#[^`]+)?`")

def resolve(raw, from_path):
    if raw.startswith(("${LOOP_SPEC_SKILL_DIR}/", "${CLAUDE_SKILL_DIR}/")):
        skill_dir = from_path.split("/")[0] + "/" + from_path.split("/")[1]
        return skill_dir + raw[raw.index("}") + 1:]
    return raw

def section(lines, heading):
    start = level = None
    for i, line in enumerate(lines):
        m = re.match(r"^(#+)\s+(.*?)\s*$", line)
        if m and m.group(2).strip("`") == heading.strip("`"):
            start, level = i, len(m.group(1)); break
    if start is None:
        return None
    end = len(lines)
    for j in range(start + 1, len(lines)):
        m = re.match(r"^(#+)\s", lines[j])
        if m and len(m.group(1)) <= level:
            end = j; break
    return lines[start:end]

seen, rows, queue, missing = set(), [], list(entries), []
while queue:
    entry = queue.pop(0)
    path, _, heading = entry.partition("#")
    full = os.path.join(root, path)
    if not os.path.isfile(full):
        missing.append(entry); continue
    lines = open(full, encoding="utf-8", errors="replace").read().split("\n")
    if lines and lines[-1] == "":
        lines = lines[:-1]
    if heading:
        lines = section(lines, heading)
        if lines is None:
            missing.append(entry); continue
    if path in seen:
        continue
    seen.add(path)
    rows.append((len(lines), entry))
    if transitive or entry in entries:
        for raw, frag in CITE.findall("\n".join(lines)):
            cite = resolve(raw, path) + (frag or "")
            if cite.partition("#")[0] not in seen:
                queue.append(cite)
if missing:
    for m in missing:
        print("context-load.sh: no such file or section: %s" % m, file=sys.stderr)
    sys.exit(2)
if cmd == "cites":
    for _, entry in rows[len([e for e in entries if e in [r[1] for r in rows]]):]:
        print(entry)
else:
    for n, entry in rows:
        print("%d\t%s" % (n, entry))
    print("TOTAL %d" % sum(n for n, _ in rows))
PY
