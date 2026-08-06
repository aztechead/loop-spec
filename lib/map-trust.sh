#!/usr/bin/env bash
# map-trust.sh - Read and write the trust marking on codebase-map documents.
#
# Why: without a trust field, a claim a human ratified and a claim a mapper
# inferred at 2 a.m. are indistinguishable forever. map-audit.sh measures how
# far the map has decayed; this field is what makes those numbers actionable —
# a `generated` domain with outdated claims is routine refresh work, a
# `verified` one is a broken promise. Ported from BMAD-METHOD's
# verified/generated split (docs/loop-spec/bmad-scan-proposals.md B6).
#
# The marking lives in YAML frontmatter at the top of each domain document,
# managed keys only — anything else in the block is preserved untouched:
#   trust: generated | verified
#   verified_at: YYYY-MM-DD   (only while verified)
#   verified_by: <name>       (only while verified)
#
# Usage:
#   map-trust.sh read [<doc>...]            # report trust per doc, ANSWER first
#   map-trust.sh mark <doc> generated       # what every refresh stamps
#   map-trust.sh mark <doc> verified --by <name>
#
# Marking generated DROPS verified_at/verified_by: regeneration voids a
# ratification, because the human confirmed the old prose, not the new.
# Promotion to verified is an operator action — no loop-spec skill may run it
# in autonomous mode, for the same reason a model does not grade its own gate.
#
# Reads $LOOP_SPEC_MAP_DIR (default docs/loop-spec/codebase) when `read` is
# given no paths.
#
# Exit codes:
#   0  read reported / mark written
#   2  usage error, missing document, or failed write
set -euo pipefail

command="${1:-}"
map_dir="${LOOP_SPEC_MAP_DIR:-docs/loop-spec/codebase}"

usage() {
  echo "usage: map-trust.sh read [<doc>...] | mark <doc> generated | mark <doc> verified --by <name>" >&2
  exit 2
}

case "$command" in
  read)
    shift
    docs=("$@")
    if [[ ${#docs[@]} -eq 0 ]]; then
      [[ -d "$map_dir" ]] || { echo "map-trust: no map directory at $map_dir" >&2; exit 2; }
      while IFS= read -r doc; do docs+=("$doc"); done < <(ls "$map_dir"/*.md 2>/dev/null | sort)
    fi
    [[ ${#docs[@]} -gt 0 ]] || { echo "map-trust: no documents to read in $map_dir" >&2; exit 2; }
    ;;
  mark)
    doc="${2:-}"; level="${3:-}"
    [[ -n "$doc" && -f "$doc" ]] || { echo "map-trust: no document at '${doc:-}'" >&2; exit 2; }
    case "$level" in
      generated) [[ $# -eq 3 ]] || usage; by="" ;;
      verified)
        [[ $# -eq 5 && "${4:-}" == "--by" && -n "${5:-}" ]] || usage
        by="$5"
        ;;
      *) usage ;;
    esac
    docs=("$doc")
    ;;
  *) usage ;;
esac

COMMAND="$command" LEVEL="${level:-}" BY="${by:-}" \
python3 - "${docs[@]}" <<'PY'
from __future__ import print_function

import datetime
import os
import re
import sys
import tempfile

command = os.environ["COMMAND"]
MANAGED = ("trust", "verified_at", "verified_by")
KEY = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*):\s*(.*?)\s*$")


def split_frontmatter(lines):
    """Return (frontmatter_lines, body_lines); frontmatter is [] when absent."""
    if not lines or lines[0].rstrip("\n") != "---":
        return [], lines
    for index in range(1, len(lines)):
        if lines[index].rstrip("\n") == "---":
            return lines[1:index], lines[index + 1:]
    return [], lines


def read_keys(front):
    values = {}
    for line in front:
        match = KEY.match(line.rstrip("\n"))
        if match:
            values[match.group(1)] = match.group(2)
    return values


def report(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            front, _ = split_frontmatter(handle.readlines())
    except OSError as exc:
        print("map-trust: cannot read {}: {}".format(path, exc), file=sys.stderr)
        sys.exit(2)
    values = read_keys(front)
    trust = values.get("trust", "unmarked")
    reason = "no trust frontmatter" if trust == "unmarked" else "frontmatter"
    print("doc={} trust={} verified_at={} verified_by={} reason={}".format(
        path, trust, values.get("verified_at", "-") or "-",
        values.get("verified_by", "-") or "-", reason))
    return trust


def mark(path):
    level = os.environ["LEVEL"]
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            front, body = split_frontmatter(handle.readlines())
    except OSError as exc:
        print("map-trust: cannot read {}: {}".format(path, exc), file=sys.stderr)
        sys.exit(2)

    def is_managed(line):
        match = KEY.match(line.rstrip("\n"))
        return match is not None and match.group(1) in MANAGED

    kept = [line for line in front if not is_managed(line)]
    managed = ["trust: {}\n".format(level)]
    if level == "verified":
        today = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
        managed.append("verified_at: {}\n".format(today))
        managed.append("verified_by: {}\n".format(os.environ["BY"]))

    new_lines = ["---\n"] + managed + kept + ["---\n"]
    if not front and body and body[0].strip():
        new_lines.append("\n")
    new_lines += body

    directory = os.path.dirname(os.path.abspath(path))
    handle = tempfile.NamedTemporaryFile("w", dir=directory, delete=False,
                                         encoding="utf-8", suffix=".map-trust")
    try:
        handle.writelines(new_lines)
        handle.close()
        os.replace(handle.name, path)
    except OSError as exc:
        os.unlink(handle.name)
        print("map-trust: cannot write {}: {}".format(path, exc), file=sys.stderr)
        sys.exit(2)
    print("doc={} trust={} reason=marked".format(path, level))


paths = sys.argv[1:]
if command == "mark":
    mark(paths[0])
else:
    counts = {"verified": 0, "generated": 0, "unmarked": 0}
    for path in paths:
        trust = report(path)
        counts[trust if trust in counts else "unmarked"] += 1
    print("trust=read docs={} verified={} generated={} unmarked={} reason=trust frontmatter".format(
        len(paths), counts["verified"], counts["generated"], counts["unmarked"]))
PY
