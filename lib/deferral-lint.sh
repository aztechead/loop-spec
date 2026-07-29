#!/usr/bin/env bash
# deferral-lint.sh - Deterministic probe: no self-authored deferral survives a
# successful conclusion.
#
# Why: loop-spec's contract is that once SPEC/DISCUSS/PLAN fix the design, the
# model runs it to completion. Everything in the spec ships. There is no valid
# successful conclusion that includes deferred items, follow-ups, or "future
# work" the MODEL chose on its own — that is scope the design promised and the
# run silently dropped. The only legitimate deferral writers are the bounded
# gates, and each stamps a recognizable marker on the line it writes:
#   iterate-budget-spent:   ITERATE's iteration limit was exhausted (rule-driven)
#   iterate-terminal:       two full iteration limits spent on the same gap
#   verify-deferred         VERIFY's Minor-finding backlog rule (PASS_WITH_MINOR)
# A line carrying one of those markers (or PASS_WITH_MINOR, the verdict that
# produces verify-deferred entries) is gate-authored and exempt. Every other
# line that speaks deferral language on a completion surface is a violation.
#
# Usage:
#   deferral-lint.sh text     <path | ->        # scan a completion surface
#                                               # (PR body, final report draft)
#   deferral-lint.sh warnings <feature.json | -> # scan feature warnings[]
#
# Output: one `FLAG <path>:<line>: <message>` per violation, then a final
# one-line answer with the reason: `deferral-lint: ok (<type>: <path>)` or
# `deferral-lint: <n> flag(s) (<type>: <path>)`.
#
# Exit codes: 0 clean, 1 any FLAG (including unreadable input — fail safe),
# 2 bad invocation.
#
# Scope guard: this lints COMPLETION SURFACES (PR bodies, terminal reports,
# warnings[]) — never SPEC.md. A spec's "Out of scope" boundary is the design
# deciding scope up front, which is exactly what this probe protects.
set -uo pipefail

type="${1:-}"
case "$type" in
  text|warnings) [[ $# -eq 2 ]] || { echo "usage: deferral-lint.sh $type <path|->" >&2; exit 2; } ;;
  *) echo "usage: deferral-lint.sh <text|warnings> <path|->" >&2; exit 2 ;;
esac
path="$2"

# `-` means stdin; slurp to a temp file so python gets a real path either way.
stdin_tmp=""
if [[ "$path" == "-" ]]; then
  stdin_tmp="$(mktemp "${TMPDIR:-/tmp}/deferral-lint-stdin.XXXXXX")"
  cat > "$stdin_tmp"
  target="$stdin_tmp"
else
  target="$path"
fi
trap '[[ -n "$stdin_tmp" ]] && rm -f "$stdin_tmp"' EXIT

python3 - "$type" "$target" "$path" <<'PY'
import json
import re
import sys

lint_type, target, display = sys.argv[1], sys.argv[2], sys.argv[3]

# Gate markers: the deterministic writers allowed to speak deferral language.
# new-mechanism:/DEFERRED-NEW-BUG is debug's sibling-sweep rule (a distinct
# root-cause mechanism is a NEW bug, never this fix's scope) — rule-driven,
# not model-chosen.
GATE_MARKERS = re.compile(
    r"iterate-budget-spent:|iterate-terminal:|verify-deferred|PASS_WITH_MINOR"
    r"|new-mechanism:|DEFERRED-NEW-BUG"
)

# Warnings entries must START with a bounded-gate prefix to carry deferral
# language (free-form model warnings do not get to smuggle scope out).
WARNING_GATE_PREFIX = re.compile(r"^(iterate-budget-spent|iterate-terminal):")

# Self-authored deferral vocabulary (case-insensitive, word-boundary). Each
# pattern names the phrase family so the FLAG reports the exact matched term.
VOCABULARY = [
    r"\bdefer(?:red|ral|ring|s)?\b",
    r"\bfollow[- ]?ups?\b",
    r"\bfuture (?:work|prs?|pull requests?|iterations?|cycles?|enhancements?|improvements?|releases?|versions?)\b",
    r"\b(?:later|subsequent|separate|follow-on) (?:prs?|pull requests?|iterations?|cycles?|changes?|commits?|tasks?|passes|efforts?)\b",
    r"\bout of scope for now\b",
    r"\b(?:left|leave|leaving) (?:it |this |them )?(?:for|to|until) (?:later|a future)\b",
    r"\bpunt(?:ed|ing|s)?\b",
    r"\bremaining (?:work|items?|tasks?|gaps?)\b",
    r"\bnext steps?\b",
    r"\bnice[- ]to[- ]haves?\b",
    r"\bstretch goals?\b",
    r"\btime permit(?:s|ting)\b",
    r"\bif time allows\b",
    r"\bfast[- ]follow(?:s|-up)?\b",
    r"\bat a later (?:date|time|point)\b",
    r"\bdown the (?:road|line)\b",
    r"\bbacklogged\b",
    r"\bnot (?:yet )?implemented\b",
]
VOCAB_RE = re.compile("|".join(VOCABULARY), re.IGNORECASE)

flags = []

# The policy governs PROSE. File paths, commands, and code legitimately contain
# vocabulary words (a slug named "defer-token-refresh", a `verify-deferred` path),
# so inline code spans are stripped and fenced blocks are skipped before scanning.
INLINE_CODE_RE = re.compile(r"`[^`]*`")


def scan_line(lineno, line):
    if GATE_MARKERS.search(line):
        return
    line = INLINE_CODE_RE.sub("", line)
    m = VOCAB_RE.search(line)
    if m:
        flags.append(
            (
                lineno,
                "self-authored deferral %r — spec scope ships in full; implement it "
                "now, or if a bounded gate produced this line it must carry its gate "
                "marker (iterate-budget-spent: / iterate-terminal: / verify-deferred)"
                % m.group(0),
            )
        )


if lint_type == "text":
    try:
        with open(target, errors="replace") as f:
            content = f.read()
    except OSError as e:
        print("FLAG %s:0: unreadable input (%s)" % (display, e))
        print("deferral-lint: 1 flag(s) (text: %s)" % display)
        sys.exit(1)
    in_fence = False
    for i, line in enumerate(content.splitlines(), 1):
        if line.lstrip().startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        scan_line(i, line)
else:  # warnings
    try:
        with open(target, errors="replace") as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        print("FLAG %s:0: unreadable feature.json (%s)" % (display, e))
        print("deferral-lint: 1 flag(s) (warnings: %s)" % display)
        sys.exit(1)
    warnings = data.get("warnings") or []
    if not isinstance(warnings, list):
        flags.append((0, "warnings is not a list"))
        warnings = []
    for i, entry in enumerate(warnings):
        entry = str(entry)
        if WARNING_GATE_PREFIX.match(entry):
            continue
        m = VOCAB_RE.search(entry)
        if m:
            flags.append(
                (
                    i,
                    "warnings[%d] carries self-authored deferral %r without a "
                    "bounded-gate prefix (iterate-budget-spent: / iterate-terminal:) "
                    "— a warning is an audit record, not a place to drop scope"
                    % (i, m.group(0)),
                )
            )

for lineno, message in flags:
    print("FLAG %s:%d: %s" % (display, lineno, message))

if flags:
    print("deferral-lint: %d flag(s) (%s: %s)" % (len(flags), lint_type, display))
    sys.exit(1)
print("deferral-lint: ok (%s: %s)" % (lint_type, display))
PY
