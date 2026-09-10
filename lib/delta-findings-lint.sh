#!/usr/bin/env bash
# delta-findings-lint.sh - Deterministic probe: which lines of a challenger's delta
# reply are inside the delta round's scope.
#
# Why: skills/shared/critique-gate-protocol.md scopes a delta re-verify to the
# fix-list and the diff, and skills/shared/team-prompts/critic.md tells the lead to
# drop any other line unread. That drop was a judgment call, and the judgment is
# what thrashed: a challenger capped at "top 5-7" held findings back, raised them in
# the delta round as `introduced:` on rewritten text, and the lead accepted them,
# so every revision bought another revision. This probe applies the scope rule the
# prose already states, so the lead adjudicates only what survives.
#
# A line survives when it is:
#   unaddressed: <text>                        (a fix-list item still open; any tag)
#   introduced: "<quoted line>" ... [major]    (the quote is a `+` line of the diff)
# Every other line is dropped with a reason:
#   out-of-scope        not an unaddressed:/introduced: line
#   no-quoted-line      introduced: without a double-quoted line
#   not-an-added-line   the quote is not text the diff added
#   minor               introduced: without a [major] tag
# The DELTA-FINDINGS:/DELTA-VERIFIED: header, blank lines, and list numbering are
# not findings and are neither kept nor counted.
#
# Usage:
#   delta-findings-lint.sh filter --diff <unified diff> <reply path | ->
#
# Output: surviving lines on stdout, verbatim minus list numbering; one
# `DROP <line>: <reason>` per dropped line on stderr; then one line on stderr:
# `delta-findings-lint: kept=<n> dropped=<m>`.
#
# Exit codes: 0 filtered; 1 unreadable diff or reply (fail safe: nothing can be
# verified, so the caller relays the message and stops); 2 bad invocation.
set -uo pipefail

usage() { echo "usage: delta-findings-lint.sh filter --diff <unified diff> <reply path|->" >&2; exit 2; }

[[ "${1:-}" == "filter" ]] || usage
shift
diff_path=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --diff) diff_path="${2:-}"; [[ -n "$diff_path" ]] || usage; shift 2 ;;
    *) break ;;
  esac
done
[[ $# -eq 1 && -n "$diff_path" ]] || usage
reply="$1"
[[ -r "$diff_path" ]] || { echo "delta-findings-lint: cannot read diff: $diff_path" >&2; exit 1; }

# `-` means stdin; slurp to a temp file so python gets a real path either way.
stdin_tmp=""
if [[ "$reply" == "-" ]]; then
  stdin_tmp="$(mktemp "${TMPDIR:-/tmp}/delta-findings-lint-stdin.XXXXXX")"
  cat > "$stdin_tmp"
  reply="$stdin_tmp"
fi
trap '[[ -n "$stdin_tmp" ]] && rm -f "$stdin_tmp"' EXIT
[[ -r "$reply" ]] || { echo "delta-findings-lint: cannot read reply: $reply" >&2; exit 1; }

python3 - "$diff_path" "$reply" <<'PY'
import re
import sys

diff_path, reply_path = sys.argv[1], sys.argv[2]

def squash(text):
    return " ".join(text.split())

added = []
with open(diff_path, encoding="utf-8", errors="replace") as fh:
    for raw in fh:
        if raw.startswith("+") and not raw.startswith("+++"):
            added.append(squash(raw[1:]))

LIST_PREFIX = re.compile(r"^\s*(?:[-*+]|\d+[.)])\s+")
HEADER = re.compile(r"^\s*DELTA-(?:FINDINGS|VERIFIED)\b", re.I)
QUOTE = re.compile(r'"([^"]+)"|“([^”]+)”')
MAJOR = re.compile(r"\[major\]", re.I)

kept = dropped = 0
with open(reply_path, encoding="utf-8", errors="replace") as fh:
    for raw in fh:
        line = LIST_PREFIX.sub("", raw.rstrip("\n"), count=1).strip()
        if not line or HEADER.match(line):
            continue
        lowered = line.lower()
        reason = None
        if lowered.startswith("unaddressed:"):
            pass
        elif lowered.startswith("introduced:"):
            match = QUOTE.search(line)
            quoted = squash(match.group(1) or match.group(2)) if match else ""
            if not quoted:
                reason = "no-quoted-line"
            elif not any(quoted in a for a in added):
                reason = "not-an-added-line"
            elif not MAJOR.search(line):
                reason = "minor"
        else:
            reason = "out-of-scope"
        if reason is None:
            kept += 1
            print(line)
        else:
            dropped += 1
            print("DROP %s: %s" % (line, reason), file=sys.stderr)

print("delta-findings-lint: kept=%d dropped=%d" % (kept, dropped), file=sys.stderr)
PY
