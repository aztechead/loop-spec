#!/usr/bin/env bash
# footprint.sh - The scout's record of the files a change touches, on disk.
#
# Why: the oneshot route is decided from the footprint, and at dda2cca the footprint
# was prose the lead retyped into SPEC.md's frontmatter: it named a protected test
# file, and the exit gate bounced the lead twice for not editing a file the task forbade
# it to touch. The rule (docs/loop-spec/orchestrator-port-principles.md, rule 1): the
# route is computed by a probe from facts the scout wrote to disk, and the footprint is
# the set of files the scout cited with file:line minus the files marked read-only. The
# model may lengthen the route; it never types the inputs the probe reads. This ledger
# is where the scout writes, and lib/graph/probes/oneshot.sh --candidate and
# cycle-driver.sh spec skeleton are the readers.
#
# Usage:
#   footprint.sh cite <feature_dir> <path>:<line> [--read-only] [<why>]
#       Append one cite. <path> is repository-relative (workspace-root relative in
#       workspace mode); --read-only marks a file the change must not touch (a protected
#       test, a generated file), which keeps it out of the footprint and puts it in the
#       spec's Implementation notes as read-only.
#   footprint.sh list <feature_dir>              the footprint: cited paths, first-cite
#                                                order, once each, read-only files left
#                                                out, plus the existing test module of
#                                                every cited source file
#   footprint.sh list <feature_dir> --read-only  the read-only files, same order
#
# Read-only is a fact from the task, never from the lead: a file is read-only only when
# feature.json.protected (the invocation token `protected:a,b`) names it; a --read-only
# mark on any other file is a plain cite, with a notice on stderr. A cited source file's
# existing test module (test_<stem>, <stem>_test, <stem>.test under tests/, its own
# directory, or test/) is in the footprint by construction, protected ones read-only, and
# leaves only through `cycle-driver.sh spec footprint drop`. The b5008b4 and d17da82
# feature runs shipped without a test because the lead marked the test module read-only
# in its own words (orchestrator-port-followup-4.md, item 1).
#   footprint.sh show <feature_dir>              every cite, one JSON object per line
#
# Ledger: <feature_dir>/footprint.jsonl, append-only, {path, line, readOnly, why, at}.
# Exit 0; 1 bad cite (no <path>:<line>, an absolute path); 2 bad invocation.
set -uo pipefail

cmd="${1:-}"; feature_dir="${2:-}"; shift 2 || true
[[ -n "$cmd" && -d "$feature_dir" ]] || { echo "usage: footprint.sh cite|list|show <feature_dir> ..." >&2; exit 2; }
ledger="$feature_dir/footprint.jsonl"

case "$cmd" in
  cite)
    cite="${1:-}"; shift || true
    read_only=false; why=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --read-only) read_only=true; shift ;;
        *) why="$1"; shift ;;
      esac
    done
    path="${cite%:*}"; line="${cite##*:}"
    [[ -n "$path" && "$line" =~ ^[0-9]+$ && "$cite" == *:* ]] \
      || { echo "footprint.sh: a cite is <path>:<line> (got '$cite'); the scout cites what it read" >&2; exit 1; }
    [[ "$path" != /* ]] || { echo "footprint.sh: $path is absolute; cite the repository-relative path" >&2; exit 1; }
    jq -cn --arg path "$path" --argjson line "$line" --argjson ro "$read_only" --arg why "$why" \
      --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '{path:$path, line:$line, readOnly:$ro, why:$why, at:$at}' >> "$ledger"
    ;;
  list)
    [[ -f "$ledger" ]] || exit 0
    want=false; [[ "${1:-}" == "--read-only" ]] && want=true
    protected="[]"
    if [[ -f "$feature_dir/feature.json" ]]; then
      protected="$(bash "$(dirname "${BASH_SOURCE[0]}")/feature-read.sh" "$feature_dir" -c --filter '.protected // []' 2>/dev/null || echo '[]')"
    fi
    root="$(git -C "$feature_dir" rev-parse --show-toplevel 2>/dev/null || true)"
    LOOP_SPEC_FOOTPRINT_ROOT="$root" python3 - "$ledger" "$protected" "$want" <<'PY'
import json, os, sys
ledger, protected, want = sys.argv[1], set(json.loads(sys.argv[2])), sys.argv[3] == "true"
root = os.environ.get("LOOP_SPEC_FOOTPRINT_ROOT") or ""
cites = []
for line in open(ledger, encoding="utf-8"):
    try:
        e = json.loads(line)
    except ValueError:
        continue
    if e.get("path") and e["path"] not in cites:
        cites.append(e["path"])
    if e.get("readOnly") and e.get("path") not in protected:
        print("footprint.sh: %s is marked read-only by the scout but the task protects no such file (feature.json.protected); "
              "it stays in the footprint" % e["path"], file=sys.stderr)
def is_test(p):
    b = os.path.basename(p); stem = os.path.splitext(b)[0]
    return p.startswith("tests/") or "/tests/" in p or p.startswith("test/") or b.startswith("test_") or stem.endswith("_test") or stem.endswith(".test")
paths = list(cites)
for p in cites:
    if is_test(p) or not root:
        continue
    stem, ext = os.path.splitext(os.path.basename(p)); d = os.path.dirname(p)
    for place in ("tests", d, os.path.join(d, "tests"), os.path.join(d, "__tests__"), "test"):
        for name in ("test_%s%s" % (stem, ext), "%s_test%s" % (stem, ext), "%s.test%s" % (stem, ext)):
            cand = os.path.normpath(os.path.join(place, name))
            if os.path.isfile(os.path.join(root, cand)) and cand not in paths:
                paths.append(cand)
for p in paths:
    if (p in protected) == want:
        print(p)
PY
    ;;
  show)
    [[ -f "$ledger" ]] && cat "$ledger" || true
    ;;
  *) echo "usage: footprint.sh cite|list|show <feature_dir> ..." >&2; exit 2 ;;
esac
