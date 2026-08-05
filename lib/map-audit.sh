#!/usr/bin/env bash
# map-audit.sh - Is the generated codebase map still true, and still worth its
# place in the context window?
#
# Why: the map is the one loop-spec artifact that is regenerated rather than
# reasoned about, and nothing measures it. It has no size ceiling, so it grows
# every refresh; it cites paths that later get deleted, and nothing notices; its
# file->domain index only ever gains entries, so a removed source file keeps
# voting on which domains are stale forever. Every one of those is a fact a
# script can check, and an unchecked map is worse than no map -- it is wrong
# with authority, loaded into every design phase.
#
# This measures. It never rewrites the map: what to cut is a judgment, and the
# refresh path owns it.
#
# Usage:
#   map-audit.sh budget      # total size against the ceiling
#   map-audit.sh sweep       # cited paths that no longer exist
#   map-audit.sh orphans     # index entries whose file is gone
#   map-audit.sh staleness   # per-domain age, and doc/index disagreement
#   map-audit.sh audit       # all four; exit 1 if anything is found
#
# Environment:
#   LOOP_SPEC_MAP_DIR        default docs/loop-spec/codebase
#   LOOP_SPEC_MAP_INDEX      default .loop-spec/codebase/index.json
#   LOOP_SPEC_MAP_MAX_LINES  default 1000 (~20k tokens across the five domains)
#   LOOP_SPEC_MAP_MAX_AGE_DAYS  default 90, matching the refresh advisory
#
# Exit codes:
#   0  measured, nothing found
#   1  findings reported
#   2  usage error or no map to measure
set -euo pipefail

command="${1:-}"
case "$command" in
  budget|sweep|orphans|staleness|audit) [[ $# -eq 1 ]] || { echo "usage: map-audit.sh $command" >&2; exit 2; } ;;
  *) echo "usage: map-audit.sh budget|sweep|orphans|staleness|audit" >&2; exit 2 ;;
esac

map_dir="${LOOP_SPEC_MAP_DIR:-docs/loop-spec/codebase}"
index="${LOOP_SPEC_MAP_INDEX:-.loop-spec/codebase/index.json}"
max_lines="${LOOP_SPEC_MAP_MAX_LINES:-1000}"
max_age_days="${LOOP_SPEC_MAP_MAX_AGE_DAYS:-90}"

[[ -d "$map_dir" ]] || {
  echo "map-audit: no map directory at $map_dir" >&2
  exit 2
}

MAP_DIR="$map_dir" MAP_INDEX="$index" MAX_LINES="$max_lines" MAX_AGE_DAYS="$max_age_days" \
python3 - "$command" <<'PY'
from __future__ import print_function

import datetime
import json
import os
import re
import sys

command = sys.argv[1]
map_dir = os.environ["MAP_DIR"]
index_path = os.environ["MAP_INDEX"]
max_lines = int(os.environ["MAX_LINES"])
max_age_days = int(os.environ["MAX_AGE_DAYS"])

docs = sorted(
    os.path.join(map_dir, name)
    for name in os.listdir(map_dir)
    if name.endswith(".md")
)

findings = []


def read(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return handle.read()
    except OSError:
        return ""


def budget():
    total = 0
    per_doc = []
    for path in docs:
        count = len(read(path).splitlines())
        per_doc.append((path, count))
        total += count
    for path, count in per_doc:
        print("doc={} lines={}".format(path, count))
    answer = "over" if total > max_lines else "under"
    print("budget={} lines={} ceiling={} reason={} documents in {}".format(
        answer, total, max_lines, len(docs), map_dir))
    if total > max_lines:
        findings.append("finding=over-budget lines={} ceiling={} reason=the map must hold or shrink, never grow".format(
            total, max_lines))


# A path-shaped token the map asserts exists. Deliberately narrow: it must carry
# a directory separator and an extension, so ordinary prose ("the verify phase")
# and bare words are never mistaken for a claim about the tree.
CITED = re.compile(r"(?<![A-Za-z0-9_./-])((?:[A-Za-z0-9_.-]+/)+[A-Za-z0-9_.-]+\.[A-Za-z0-9]+)")
# Globs and placeholders are patterns, not claims -- {slug}, *.sh, `.../SPEC.md`
# and `round-N.md` name no single file, so their absence proves nothing.
PLACEHOLDER = re.compile(r"[*{}<>]|\.\.\.|(?:^|[/-])N\.[A-Za-z0-9]+$")
# A path inside a URL is a reference to somebody else's tree, and a path offered
# as an illustration is a hypothetical -- neither asserts this repo contains it.
URL_CONTEXT = re.compile(r"(?:https?://|github\.com|\.git\b|e\.g\.[^.]*$)")


def sweep():
    missing = 0
    checked = 0
    seen = set()
    for path in docs:
        for number, line in enumerate(read(path).splitlines(), 1):
            for cited in CITED.findall(line):
                if PLACEHOLDER.search(cited) or cited in seen:
                    continue
                prefix = line[:line.find(cited)]
                if URL_CONTEXT.search(prefix) or URL_CONTEXT.search(cited):
                    continue
                seen.add(cited)
                checked += 1
                if not os.path.exists(cited):
                    missing += 1
                    findings.append("finding=stale-claim path={} reason=cited at {}:{} but not in the tree".format(
                        cited, path, number))
    print("sweep={} checked={} reason=distinct cited paths across {} documents".format(
        "clean" if missing == 0 else "stale", checked, len(docs)))


def orphans():
    if not os.path.exists(index_path):
        print("orphans=unknown reason={} does not exist".format(index_path))
        return
    try:
        with open(index_path, "r", encoding="utf-8", errors="replace") as handle:
            data = json.load(handle)
    except (OSError, ValueError) as exc:
        print("orphans=unknown reason=cannot read {}: {}".format(index_path, exc))
        return
    files = data.get("files") or {}
    gone = [path for path in sorted(files) if not os.path.exists(path)]
    for path in gone:
        findings.append("finding=orphan-index-entry path={} reason=file no longer exists but still maps to {}".format(
            path, ",".join(files[path]) if isinstance(files[path], list) else files[path]))
    print("orphans={} indexed={} reason={}".format(len(gone), len(files), index_path))


STALE_BANNER = re.compile(r"^\s*>?\s*\**\s*STALE\b", re.I | re.M)


def staleness():
    stamps = {}
    if os.path.exists(index_path):
        try:
            with open(index_path, "r", encoding="utf-8", errors="replace") as handle:
                stamps = (json.load(handle) or {}).get("last_refreshed_at") or {}
        except (OSError, ValueError):
            stamps = {}
    now = datetime.datetime.utcnow()
    for domain in sorted(stamps):
        raw = stamps[domain]
        try:
            when = datetime.datetime.strptime(raw, "%Y-%m-%dT%H:%M:%SZ")
        except (TypeError, ValueError):
            print("domain={} age=unknown reason=unparseable timestamp {!r}".format(domain, raw))
            continue
        age = (now - when).days
        print("domain={} age_days={} refreshed={}".format(domain, age, raw))
        if age > max_age_days:
            findings.append("finding=stale-domain domain={} age_days={} ceiling={}".format(
                domain, age, max_age_days))

    # A doc that says STALE while the index calls it fresh is the worse failure:
    # the machine state and the prose disagree, and only the prose is honest.
    for path in docs:
        body = read(path)
        if not STALE_BANNER.search(body):
            continue
        domain = os.path.splitext(os.path.basename(path))[0].lower()
        if domain in stamps:
            findings.append("finding=trust-disagreement path={} reason=doc declares STALE but the index records {} as refreshed {}".format(
                path, domain, stamps[domain]))
    print("staleness=checked domains={} ceiling_days={}".format(len(stamps), max_age_days))


steps = {"budget": budget, "sweep": sweep, "orphans": orphans, "staleness": staleness}
if command == "audit":
    for name in ("budget", "sweep", "orphans", "staleness"):
        steps[name]()
else:
    steps[command]()

for finding in findings:
    print(finding)
print("findings={}".format(len(findings)))
sys.exit(1 if findings else 0)
PY
