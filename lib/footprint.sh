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
#                                                order, once each, read-only files left out
#   footprint.sh list <feature_dir> --read-only  the read-only files, same order
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
    # A file cited both ways is read-only: the mark is the stronger fact.
    jq -rs --argjson want "$want" '
      (map(select(.readOnly)) | map(.path) | unique) as $ro
      | map(.path) | unique_by(.) as $seen
      | [.[] | select((. as $p | $ro | index($p) != null) == $want)] | .[]' "$ledger" 2>/dev/null \
      | awk '!seen[$0]++'
    ;;
  show)
    [[ -f "$ledger" ]] && cat "$ledger" || true
    ;;
  *) echo "usage: footprint.sh cite|list|show <feature_dir> ..." >&2; exit 2 ;;
esac
