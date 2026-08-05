#!/usr/bin/env bash
# review-trail.sh - The deterministic half of the reviewer's guide.
#
# Why: the cycle spends seven phases proving the change to itself, then hands a
# human a flat diff and the word "review". The reviewer re-derives, unaided, the
# structure the loop already knew. A trail fixes that -- ordered stops, each an
# anchored `path:line` with one line of framing -- but only its PROSE is model
# work. Which files changed, which are peripheral, where the first changed hunk
# starts, and whether the finished trail actually covers the change are facts,
# and facts belong in a script the gate can run.
#
# Usage:
#   review-trail.sh surface <base-ref> [head-ref]
#   review-trail.sh lint <trail-file> <base-ref> [head-ref]
#
# `surface` emits one line per changed file, ANSWER first:
#   role=core path=lib/deliver.sh anchor=88 churn=+42/-3 reason=source file
#   surface=2 core=1 peripheral=1 reason=main..HEAD
#
# `lint` validates a written trail against that surface and reports findings:
#   finding=uncovered path=lib/deliver.sh reason=core file has no stop
#
# Exit codes:
#   0  surface emitted / trail clean
#   1  no changed file (surface) / findings reported (lint)
#   2  usage error, unreadable trail, or git failure
set -euo pipefail

command="${1:-}"
case "$command" in
  surface) [[ $# -ge 2 && $# -le 3 ]] || { echo "usage: review-trail.sh surface <base-ref> [head-ref]" >&2; exit 2; } ;;
  lint) [[ $# -ge 3 && $# -le 4 ]] || { echo "usage: review-trail.sh lint <trail-file> <base-ref> [head-ref]" >&2; exit 2; } ;;
  *) echo "usage: review-trail.sh surface <base-ref> [head-ref] | lint <trail-file> <base-ref> [head-ref]" >&2; exit 2 ;;
esac

if [[ "$command" == "lint" ]]; then
  trail="$2"; base="$3"; head="${4:-HEAD}"
  [[ -r "$trail" ]] || { echo "review-trail: cannot read trail $trail" >&2; exit 2; }
else
  trail=""; base="$2"; head="${3:-HEAD}"
fi

# One numstat call feeds both subcommands; --find-renames keeps a moved file from
# reading as an unrelated deletion plus an uncovered addition.
numstat="$(git diff --numstat --find-renames "$base" "$head" 2>/dev/null)" || {
  echo "review-trail: git diff $base..$head failed" >&2
  exit 2
}

# The anchor is the first added line's number in the post-image, so a stop lands
# on changed code rather than the top of the file. Pulled per file from the diff
# rather than guessed.
anchors="$(git diff --unified=0 --find-renames "$base" "$head" 2>/dev/null |
  awk '
    /^\+\+\+ b\// { path = substr($0, 7); have = 0; next }
    /^\+\+\+ / { path = ""; have = 0; next }
    /^@@ / && path != "" && !have {
      split($3, span, ",")
      line = substr(span[1], 2)
      if (line == "0") line = 1
      print path "\t" line
      have = 1
    }
  ')" || anchors=""

TRAIL_FILE="$trail" BASE_REF="$base" HEAD_REF="$head" \
NUMSTAT="$numstat" ANCHORS="$anchors" \
python3 - "$command" <<'PY'
from __future__ import print_function

import os
import re
import sys

command = sys.argv[1]
base = os.environ["BASE_REF"]
head = os.environ["HEAD_REF"]

# Supporting material a reviewer reads last. Deliberately path-shaped and
# conservative: a pattern that would swallow a repo's actual source is worse
# than no classification, because it would bury the change under its fixtures.
PERIPHERAL = [
    (re.compile(r"(^|/)tests?/"), "test tree"),
    (re.compile(r"(^|/)__tests__/"), "test tree"),
    (re.compile(r"(^|/)spec/"), "test tree"),
    (re.compile(r"\.(test|spec)\.[A-Za-z0-9]+$"), "test file"),
    (re.compile(r"_test\.[A-Za-z0-9]+$"), "test file"),
    (re.compile(r"(^|/)fixtures?/"), "fixture"),
    (re.compile(r"(^|/)testdata/"), "fixture"),
    (re.compile(r"(^|/)snapshots?/"), "fixture"),
    (re.compile(r"(^|/)docs?/"), "documentation"),
    (re.compile(r"\.(md|markdown|rst|txt)$"), "documentation"),
    (re.compile(r"(^|/)\.github/"), "CI config"),
    (re.compile(r"\.(ya?ml|toml|ini|cfg|properties)$"), "configuration"),
    (re.compile(r"(^|/)[^/]*lock(file)?(\.[A-Za-z0-9]+)?$"), "lockfile"),
    (re.compile(r"\.d\.ts$"), "type declarations"),
    (re.compile(r"(^|/)types?/"), "type declarations"),
]

anchors = {}
for row in os.environ.get("ANCHORS", "").splitlines():
    if "\t" in row:
        path, line = row.split("\t", 1)
        anchors[path] = line.strip() or "1"


def classify(path):
    for pattern, reason in PERIPHERAL:
        if pattern.search(path):
            return "peripheral", reason
    return "core", "source file"


files = []
for row in os.environ.get("NUMSTAT", "").splitlines():
    parts = row.split("\t")
    if len(parts) != 3:
        continue
    added, deleted, path = parts
    # A rename numstat carries `old => new`; the post-image is what a stop can
    # anchor to, so that is the path recorded.
    if " => " in path:
        path = re.sub(r"\{([^}]*) => ([^}]*)\}", r"\2", path)
        if " => " in path:
            path = path.split(" => ")[-1]
        path = path.replace("//", "/")
    role, why = classify(path)
    files.append({
        "path": path.strip(),
        "role": role,
        "why": why,
        "added": added if added != "-" else "0",
        "deleted": deleted if deleted != "-" else "0",
    })

if not files:
    print("surface=0 reason=no changed file between {} and {}".format(base, head))
    sys.exit(1)

# Fail safe for repos whose product IS markdown or config -- this plugin is one.
# Classifying every file peripheral would tell a reviewer the change has no
# substance, so the classification stands down instead of lying.
if all(entry["role"] == "peripheral" for entry in files):
    for entry in files:
        entry["role"] = "core"
        entry["why"] = "no non-peripheral file in this change; classification withheld"

for entry in files:
    entry["anchor"] = anchors.get(entry["path"], "1")


def emit_surface():
    for entry in sorted(files, key=lambda item: (item["role"] != "core", item["path"])):
        print("role={} path={} anchor={} churn=+{}/-{} reason={}".format(
            entry["role"], entry["path"], entry["anchor"],
            entry["added"], entry["deleted"], entry["why"]))
    core = sum(1 for entry in files if entry["role"] == "core")
    print("surface={} core={} peripheral={} reason={}..{}".format(
        len(files), core, len(files) - core, base, head))


if command == "surface":
    emit_surface()
    sys.exit(0)

# --- lint -----------------------------------------------------------------
# A trail is checked against the change it claims to guide, never against taste.
# Every finding names the stop and the fact that produced it.

MAX_FRAMING_WORDS = 15

STOP = re.compile(r"`?([A-Za-z0-9_./\-]+\.[A-Za-z0-9_]+):(\d+)`?")

try:
    with open(os.environ["TRAIL_FILE"], "r", encoding="utf-8", errors="replace") as handle:
        trail_lines = handle.readlines()
except OSError as exc:
    print("review-trail: cannot read trail: {}".format(exc), file=sys.stderr)
    sys.exit(2)

by_path = {entry["path"]: entry for entry in files}
findings = []
stops = []          # (order, path, line, source_line_number)

for number, raw in enumerate(trail_lines, 1):
    line = raw.rstrip("\n")
    match = STOP.search(line)
    if not match:
        continue
    path, anchor = match.group(1), int(match.group(2))
    stops.append((len(stops), path, anchor, number))

    if path not in by_path:
        findings.append("finding=unknown-path path={} reason=stop at trail line {} is not in the change surface".format(path, number))
        continue

    try:
        with open(path, "r", encoding="utf-8", errors="replace") as target:
            total = sum(1 for _ in target)
    except OSError:
        total = 0
    if total and anchor > total:
        findings.append("finding=bad-anchor path={}:{} reason=file has {} lines".format(path, anchor, total))

    # Framing sits either beside the stop or on the line above it -- the trail
    # format leads with the phrase and puts the anchor underneath. Length is the
    # only thing measurable here; whether the phrase is any GOOD is the gate
    # reviewer's call, and a script that guessed at it would be inventing.
    framing = STOP.sub("", line).strip(" -*`\t")
    if not framing:
        for previous in range(number - 2, -1, -1):
            candidate = trail_lines[previous].rstrip("\n")
            if not candidate.strip():
                continue
            if STOP.search(candidate) or candidate.lstrip().startswith("#"):
                break
            framing = candidate.strip(" -*`\t")
            break
    if framing and len(framing.split()) > MAX_FRAMING_WORDS:
        findings.append("finding=long-framing path={}:{} reason={} words, limit {}".format(
            path, anchor, len(framing.split()), MAX_FRAMING_WORDS))

if not stops:
    findings.append("finding=empty reason=no `path:line` stop found in the trail")

covered = {path for _, path, _, _ in stops}
for entry in files:
    if entry["role"] == "core" and entry["path"] not in covered:
        findings.append("finding=uncovered path={} reason=core file has no stop".format(entry["path"]))

# Peripherals last is the whole point of an ordered trail: a reviewer who opens
# the fixtures before the logic has been given a file list, not a guide.
last_core = None
for order, path, _, _ in stops:
    entry = by_path.get(path)
    if entry and entry["role"] == "core":
        last_core = order
if last_core is not None:
    for order, path, anchor, number in stops:
        entry = by_path.get(path)
        if entry and entry["role"] == "peripheral" and order < last_core:
            findings.append("finding=peripheral-early path={}:{} reason=supporting file precedes core stops (trail line {})".format(
                path, anchor, number))

for finding in findings:
    print(finding)
print("stops={} core_files={} findings={} reason=trail checked against {}..{}".format(
    len(stops), sum(1 for entry in files if entry["role"] == "core"), len(findings), base, head))
sys.exit(1 if findings else 0)
PY
