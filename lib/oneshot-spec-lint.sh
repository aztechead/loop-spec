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
set -euo pipefail

spec="${1:-}"
[[ -n "$spec" ]] || { echo "usage: oneshot-spec-lint.sh <SPEC.md>" >&2; exit 2; }
# An absent file is artifact-lint's finding, reported once there, not twice.
[[ -f "$spec" ]] || exit 0
MAX_LINES=60
FOOTPRINT_MAX=3

PYTHONPATH="$(dirname "${BASH_SOURCE[0]}")${PYTHONPATH:+:$PYTHONPATH}" python3 - "$spec" "$MAX_LINES" "$FOOTPRINT_MAX" <<'PY'
import os, re, subprocess, sys
from okf import read_document
path, max_lines, footprint_max = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
try:
    metadata, body = read_document(path)
except (OSError, ValueError) as exc:
    print("FLAG [oneshot-shape] invalid OKF SPEC.md: %s" % exc)
    raise SystemExit(1)
whole = open(path, encoding="utf-8", newline="").read()
lines = whole.split("\n")
if lines and lines[-1] == "":
    lines = lines[:-1]
front = []
footprint = metadata.get("footprint")
if footprint is not None and (not isinstance(footprint, list) or any(not isinstance(item, str) or not item.strip() for item in footprint)):
    print("FLAG [oneshot-shape] SPEC.md footprint must be a list of non-empty strings")
    raise SystemExit(1)
if footprint is None or not (1 <= len(footprint) <= footprint_max):
    sys.exit(0)
# A run the operator or the gate already put on the full route writes the full shape:
# LOOP_SPEC_ROUTE=full drew two REDOs for a missing Intent block (live run 3, 6.6.4).
# The value may be quoted (YAML): the route probe strips the quotes, so the lint does too.
if os.environ.get("LOOP_SPEC_ROUTE") == "full" or metadata.get("route") == "full":
    sys.exit(0)
flags = []
if len(lines) > max_lines:
    flags.append("FLAG [oneshot-shape] SPEC.md is %d lines; a spec with a oneshot footprint keeps to %d (skills/shared/artifact-templates/SPEC-oneshot.md.template): cut narrative, keep the frozen Intent block, Implementation notes, the Good Enough criteria with their check commands, and Grounding" % (len(lines), max_lines))
body = body.split("\n")
body_line_offset = whole[:len(whole) - len("\n".join(body))].count("\n")
if not any(l.strip() == "## Intent" for l in body):
    flags.append("FLAG [oneshot-shape] SPEC.md has no '## Intent' block: the ask goes inside `<!-- intent: frozen ... -->` and `<!-- /intent -->` (skills/shared/artifact-templates/SPEC-oneshot.md.template); no later phase edits it")
if not any(l.strip() == "## Implementation notes" for l in body):
    flags.append("FLAG [oneshot-shape] SPEC.md has no '## Implementation notes' section: one bullet per footprint file naming what changes in it")
# Every Good Enough line carries its command in backticks: the driver writes it from
# `spec fill --command --expect`, and `verification run` executes it; a sentence with no
# command stalled three live runs on empty Status cells before the boundary could
# ever see it (port audit 5, R1). Checked here, at SPEC's exit.
inside = False
for idx, l in enumerate(body):
    if l.startswith("### "):
        inside = l.strip() == "### Good Enough"
    elif l.startswith("## "):
        inside = False
    elif inside and re.match(r"^- \[[ xX]\] ", l) and not re.search(r"`[^`]+`", l):
        flags.append("FLAG [oneshot-shape] Good Enough line %d carries no backticked command: a criterion is `cycle-driver.sh spec fill --command <shell> --expect <text>`, never a sentence (%s)" % (body_line_offset + idx + 1, l.strip()[:80]))
# A footprint file's existing test module is a decision the spec makes out loud: in the
# footprint when it changes, in Implementation notes as unchanged when it does not. A
# haiku run named only wc_tool.py, shipped the flag without a test, and the reviewer
# deferred "consider adding tests" to Minor; the acceptance check for the test failed.
root = subprocess.run(["git", "-C", os.path.dirname(os.path.abspath(path)), "rev-parse", "--show-toplevel"],
                      stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, universal_newlines=True).stdout.strip()
for p in footprint if root else []:
    base = os.path.basename(p)
    stem, ext = os.path.splitext(base)
    if p.startswith("tests/") or "/tests/" in p or base.startswith("test_") or stem.endswith("_test") or stem.endswith(".test"):
        continue
    d = os.path.dirname(p)
    names = ["test_%s%s" % (stem, ext), "%s_test%s" % (stem, ext), "%s.test%s" % (stem, ext)]
    places = ["tests", d, os.path.join(d, "tests"), os.path.join(d, "__tests__"), "test"]
    for place in places:
        for name in names:
            cand = os.path.normpath(os.path.join(place, name))
            if os.path.isfile(os.path.join(root, cand)) and cand not in whole:
                flags.append("FLAG [oneshot-footprint] %s has a test module %s the spec does not name: add it to the footprint when it changes, or say in Implementation notes that it stays unchanged" % (p, cand))
                break
        else:
            continue
        break
for f in flags:
    print(f)
sys.exit(1 if flags else 0)
PY
