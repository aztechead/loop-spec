#!/usr/bin/env bash
# deferral-lint.sh - Deterministic probe: no self-authored deferral survives a
# successful conclusion.
#
# Why: loop-spec's contract is that once SPEC/DISCUSS/PLAN fix the design, the
# model runs it to completion. Everything in the spec ships. There is no valid
# successful conclusion that includes an explicit model-chosen deferred-scope
# declaration — that is scope the design promised and the run silently dropped.
# This is deliberately a STRUCTURED check, not a forbidden-word scanner: reports,
# negations, template defaults, and runtime warnings may all accurately mention the
# word "deferred" without dropping any feature scope. The only legitimate deferral
# writers are the bounded gates, and each stamps a recognizable marker on the line it
# writes:
#   iterate-budget-spent:   ITERATE's iteration limit was exhausted (rule-driven)
#   iterate-terminal:       two full iteration limits spent on the same gap
#   verify-deferred         VERIFY's Minor-finding backlog rule (PASS_WITH_MINOR)
# A line carrying one of those markers (or PASS_WITH_MINOR, the verdict that
# produces verify-deferred entries) is gate-authored and exempt. Every other explicit
# deferred-scope declaration on a completion surface is a violation.
#
# Usage:
#   deferral-lint.sh text     <path | ->        # scan a completion surface
#                                               # (PR body, final report draft)
#   deferral-lint.sh warnings <feature.json | -> # validate warning JSON shape only
#
# Output: one `FLAG <path>:<line>: <message>` per violation, then a final
# one-line answer with the reason: `deferral-lint: ok (<type>: <path>)` or
# `deferral-lint: <n> flag(s) (<type>: <path>)`.
#
# Exit codes: 0 clean, 1 any FLAG (including unreadable input — fail safe),
# 2 bad invocation.
#
# Scope guard: this lints explicit deferred-scope declarations in completion
# surfaces (PR bodies, terminal reports). Runtime `warnings[]` are observations, not
# an assertion that feature scope was dropped, and therefore never trigger this gate.
# It never scans SPEC.md. A spec's "Out of scope" boundary is the design
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
    r"^\s*(?:[-*+]\s*)?(?:iterate-budget-spent:|iterate-terminal:|verify-deferred"
    r"|PASS_WITH_MINOR|new-mechanism:|DEFERRED-NEW-BUG)",
    re.I,
)

flags = []

# The policy governs declared scope. File paths, commands, quoted reports, and code
# legitimately contain this vocabulary, so inline code spans, fenced blocks, and
# Markdown blockquotes are ignored before looking for a declaration.
INLINE_CODE_RE = re.compile(r"`[^`]*`")
NONE_RE = re.compile(r"^(?:none|no(?:ne)?|n/?a|nothing|0|not applicable|no action required)\.?$", re.I)
DECLARATION_RE = re.compile(
    r"^\s*(?:[-*+]\s*)?(?:\*\*)?"
    r"(deferred(?:\s+(?:scope|items?|work))?|follow[- ]?ups?|future work|remaining work)"
    r"(?:\*\*)?\s*:\s*(.*\S)\s*$",
    re.I,
)
HEADING_RE = re.compile(
    r"^\s{0,3}(#{1,6})\s+"
    r"(deferred(?:\s+(?:scope|items?|work))?|follow[- ]?ups?|future work|remaining work)"
    r"\s*#*\s*$",
    re.I,
)
# A direct first-person commitment is also structured enough to be meaningful.
# It deliberately does not match third-party reports such as "the guard matched
# deferred" or negations such as "no follow-up action required".
COMMITMENT_RE = re.compile(
    r"\b(?:we|i)\s+(?:will\s+)?(?:defer|leave|punt)\b.*"
    r"\b(?:later|future|follow[- ]?on|separate)\b",
    re.I,
)
BARE_PAST_DEFERRAL_RE = re.compile(
    r"^\s*(?:[-*+]\s*)?deferred\b.*\b(?:later|future|follow[- ]?on|separate)\b",
    re.I,
)


def declaration_has_scope(value):
    value = INLINE_CODE_RE.sub("", value).strip()
    return bool(value) and not NONE_RE.fullmatch(value)


def flag(lineno, label):
    flags.append((
        lineno,
        "self-authored deferred scope declaration (%s) — implement the named scope "
        "now, or use a bounded-gate marker (iterate-budget-spent: / iterate-terminal: "
        "/ verify-deferred) when the gate, rather than the model, created it" % label,
    ))


def scan_text(content):
    lines = content.splitlines()
    in_fence = False
    index = 0
    while index < len(lines):
        raw = lines[index]
        lineno = index + 1
        if raw.lstrip().startswith("```"):
            in_fence = not in_fence
            index += 1
            continue
        if in_fence or raw.lstrip().startswith(">") or GATE_MARKERS.search(raw):
            index += 1
            continue
        line = INLINE_CODE_RE.sub("", raw)
        heading = HEADING_RE.match(line)
        if heading:
            level = len(heading.group(1))
            values = []
            index += 1
            while index < len(lines):
                candidate = lines[index]
                next_heading = re.match(r"^\s{0,3}(#{1,6})\s+", candidate)
                if next_heading and len(next_heading.group(1)) <= level:
                    break
                if not candidate.lstrip().startswith(">") and not candidate.lstrip().startswith("```"):
                    values.append(candidate.strip().lstrip("-*+ ").strip())
                index += 1
            meaningful = [value for value in values if value and not NONE_RE.fullmatch(value)]
            if meaningful:
                flag(lineno, heading.group(2))
            continue
        declaration = DECLARATION_RE.match(line)
        if declaration and declaration_has_scope(declaration.group(2)):
            flag(lineno, declaration.group(1))
        elif COMMITMENT_RE.search(line) or BARE_PAST_DEFERRAL_RE.search(line):
            flag(lineno, "first-person commitment")
        index += 1


if lint_type == "text":
    try:
        with open(target, errors="replace") as f:
            content = f.read()
    except OSError as e:
        print("FLAG %s:0: unreadable input (%s)" % (display, e))
        print("deferral-lint: 1 flag(s) (text: %s)" % display)
        sys.exit(1)
    scan_text(content)
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
    # Runtime warnings describe observations such as a non-blocking map refresh;
    # they are not a declaration that feature scope was dropped. Never infer scope
    # from a reserved word in this unstructured diagnostics channel.

for lineno, message in flags:
    print("FLAG %s:%d: %s" % (display, lineno, message))

if flags:
    print("deferral-lint: %d flag(s) (%s: %s)" % (len(flags), lint_type, display))
    sys.exit(1)
print("deferral-lint: ok (%s: %s)" % (lint_type, display))
PY
