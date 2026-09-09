#!/usr/bin/env bash
# oneshot-spec-lint.sh - A SPEC.md that names a oneshot footprint keeps the oneshot shape.
#
# Why: the route reads the footprint (lib/graph/probes/oneshot.sh), and the shape is what
# keeps the route cheap: the first haiku runs on the route wrote 93-line specs against a
# 60-line template, and every line is read again by ONESHOT, the reviewer, and the
# verifier. The `spec` node's egress lists this gate; a spec with no footprint, or with
# more files than the route allows, is the full shape and passes untouched.
#
# Usage: oneshot-spec-lint.sh <SPEC.md>
# Output: `FLAG <what>` lines; exit 1 when any, 0 when clean (or no file), 2 bad call.
set -uo pipefail

spec="${1:-}"
[[ -n "$spec" ]] || { echo "usage: oneshot-spec-lint.sh <SPEC.md>" >&2; exit 2; }
# An absent file is artifact-lint's finding, reported once there, not twice.
[[ -f "$spec" ]] || exit 0
MAX_LINES=60
FOOTPRINT_MAX=3

python3 - "$spec" "$MAX_LINES" "$FOOTPRINT_MAX" <<'PY'
import re, sys
path, max_lines, footprint_max = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
text = open(path, encoding="utf-8", errors="replace").read()
lines = text.split("\n")
if lines and lines[-1] == "":
    lines = lines[:-1]
if not lines or lines[0].strip() != "---" or "---" not in lines[1:]:
    sys.exit(0)
end = lines.index("---", 1)
front = lines[1:end]
footprint = None
in_list = False
for raw in front:
    text = raw.strip()
    if re.match(r"^footprint:\s*$", raw):
        footprint, in_list = [], True
        continue
    m = re.match(r"^footprint:\s*(\[.*\])\s*$", raw)
    if m:
        footprint = [p for p in re.findall(r"[^\[\],\s'\"]+", m.group(1))]
        in_list = False
        continue
    if in_list and text.startswith("- "):
        footprint.append(text[2:].strip())
    elif in_list and raw and not raw.startswith(" "):
        in_list = False
if footprint is None or not (1 <= len(footprint) <= footprint_max):
    sys.exit(0)
flags = []
if len(lines) > max_lines:
    flags.append("FLAG [oneshot-shape] SPEC.md is %d lines; a spec with a oneshot footprint keeps to %d (skills/shared/artifact-templates/SPEC-oneshot.md.template): cut narrative, keep Problem, Implementation notes, the Good Enough criteria with their check commands, and Grounding" % (len(lines), max_lines))
body = lines[end + 1:]
if not any(l.strip() == "## Implementation notes" for l in body):
    flags.append("FLAG [oneshot-shape] SPEC.md has no '## Implementation notes' section: one bullet per footprint file naming what changes in it")
for f in flags:
    print(f)
sys.exit(1 if flags else 0)
PY
