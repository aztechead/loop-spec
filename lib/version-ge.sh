#!/usr/bin/env bash
# version-ge.sh - Is a dotted-integer version >= a minimum?
#
# Why: lib/teams-capability.sh and lib/workflow-availability.sh each gate a
# capability behind a minimum `claude --version`, and both used to answer with
# `printf '%s\n%s\n' "$ver" "$MIN" | sort -V | head -1` -- GNU coreutils' `-V`
# flag, absent from BSD/macOS sort (the exact rule lib/portability-scan.sh now
# checks for). Comparing dotted integers is ordinary bash arithmetic, so the
# comparison needs no subprocess and no platform-specific flag at all.
#
# Usage:
#   version-ge.sh <version> <min>
#     Both are dot-separated non-negative integers (e.g. "2.1.178"). The two may
#     have different lengths; a missing trailing component compares as 0, so
#     "2.1" equals "2.1.0".
#
# Exit codes:
#   0  <version> >= <min>
#   1  <version> < <min>
#   2  usage error, or either argument is not a dotted-integer version
set -euo pipefail

[[ $# -eq 2 ]] || { echo "usage: version-ge.sh <version> <min>" >&2; exit 2; }
for v in "$1" "$2"; do
  [[ "$v" =~ ^[0-9]+(\.[0-9]+)*$ ]] \
    || { echo "version-ge.sh: not a dotted-integer version: $v" >&2; exit 2; }
done

IFS='.' read -ra ver_parts <<<"$1"
IFS='.' read -ra min_parts <<<"$2"

width=${#ver_parts[@]}
(( ${#min_parts[@]} > width )) && width=${#min_parts[@]}

for ((i = 0; i < width; i++)); do
  v="${ver_parts[i]:-0}"
  m="${min_parts[i]:-0}"
  # 10# forces base-10 so a component like "08" is never misread as invalid octal.
  (( 10#$v > 10#$m )) && exit 0
  (( 10#$v < 10#$m )) && exit 1
done
exit 0
