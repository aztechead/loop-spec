#!/usr/bin/env bash
# docs-probe.sh - Current version and documentation for a named dependency, from live sources.
#
# The plugin's own answer to "which version is current, and how does its current
# release do X?" (`skills/shared/grounding-protocol.md`, "Current documentation";
# `skills/shared/engineering-directives.md`, the version row). It asks the registry or
# the release tracker over the network, never a local catalog or model memory, and
# returns one line for a version or the documentation sections that match a topic.
# Sources are a table in lib/docs-probe.py, one row per ecosystem; the ecosystem comes
# from --ecosystem, else the manifest in --dir, else every row in turn. The runtime row
# has a mirror (the endoflife project's release data on GitHub) for a network that
# blocks endoflife.date, and a bare lookup whose runtime sources never answered stops
# with `unverified` rather than name a same-named package (`python` is one on npm).
#
# Usage:
#   docs-probe.sh latest  <name> [--ecosystem runtime|pypi|npm|crates|rubygems|go] [--dir DIR]
#       -> version=<v> source=<url> ecosystem=<e>
#   docs-probe.sh resolve <name> [--ecosystem E] [--version V] [--dir DIR]
#       -> {name, ecosystem, version, homepage, docs, repo, source}
#   docs-probe.sh docs    <name> [--ecosystem E] [--version V] [--topic WORD ...] [--max-lines N] [--dir DIR]
#       -> "docs: <name>@<v> source=<url>" then the sections that match the topic
#          (llms.txt where the docs live, else the README at the version's tag, else the
#          registry's readme, else the docs page as text)
#
# Exit codes: 0 answered; 1 nothing answered (the one line says `version=unverified`
# or `docs: unverified` with the reason; record an ASSUMPTION, never a guess);
# 2 bad invocation.
#
# Environment: LOOP_SPEC_DOCS_CACHE_DIR, LOOP_SPEC_DOCS_CACHE_TTL_SECS (default 3600),
# LOOP_SPEC_DOCS_FIXTURES (canned responses; the offline test double).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
  latest|resolve|docs) [[ $# -ge 2 ]] || { sed -n '12,22p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; } ;;
  *) sed -n '12,22p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
python3 "$SCRIPT_DIR/docs-probe.py" "$@"
rc=$?
(( rc == 2 )) && sed -n '12,22p' "$0" | sed 's/^# \{0,1\}//' >&2
exit $rc
