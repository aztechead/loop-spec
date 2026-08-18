#!/usr/bin/env bash
# Report the first auditable security/destructive-change signal in artifacts.
set -euo pipefail

[[ "${1:-}" == "first" && $# -ge 2 ]] || {
  echo "usage: security-signal.sh first <file> [file ...]" >&2
  exit 2
}
shift

python3 - "$@" <<'PY'
from __future__ import print_function

import re
import sys

# Two tiers (dogfooding: single ambiguous keywords escalated the heavy critique
# gate on runs with no security surface). STRONG terms are security-specific and
# fire alone. WEAK terms are ambiguous in ordinary engineering prose ("token
# budget", "delete the temp file", "data migration") and fire only when a SECOND
# distinct signal term also appears somewhere in the artifact set — one benign
# keyword is never enough to select the heavier gate.
strong_signals = [
    ("auth", re.compile(r"\bauth\b", re.I)),
    ("auth protocol", re.compile(r"\b(?:oauth2?|authn|authz|unauthenticated|unauthorized|reauthenticat[a-z]*)\b", re.I)),
    ("authentication", re.compile(r"\bauthenticat[a-z]*\b", re.I)),
    ("authorization", re.compile(r"\b(?:re|de|pre)?authoriz(?:e|es|ed|ing|ation)[a-z]*\b", re.I)),
    ("permission", re.compile(r"\bpermissions?\b", re.I)),
    ("credential", re.compile(r"\bcredentials?\b", re.I)),
    ("secret", re.compile(r"\bsecrets?\b", re.I)),
    ("cryptography", re.compile(r"\b(?:cryptograph[a-z]*|encrypt[a-z]*|decrypt[a-z]*|crypto(?:currency|graphic|graphy)?|crypt)\b", re.I)),
    ("payment", re.compile(r"\bpayments?\b", re.I)),
    ("billing", re.compile(r"\bbilling\b", re.I)),
    ("PII", re.compile(r"\bpii\b", re.I)),
]
weak_signals = [
    ("token", re.compile(r"\btokens?\b", re.I)),
    ("migration", re.compile(r"\bmigrat[a-z]*\b", re.I)),
    ("deletion", re.compile(r"\bdelet[a-z]*\b", re.I)),
]

# A spec names a security surface twice: once to say the change touches it, once
# to say the change must LEAVE IT ALONE. Only the first is a reason to escalate,
# and the second is what a bare substring matcher cannot tell apart -- it is why
# "do NOT touch the auth middleware" bought a full advocate/challenger debate on
# mechanical changes with no security surface at all.
#
# Two suppressions, both structural rather than semantic, so a reader can predict
# them from the text alone:
#   1. A NON-GOAL SECTION: everything under a heading that declares what the
#      change excludes, until the next heading at the same or a higher level.
#   2. A NEGATED SCOPE VERB in the term's own CLAUSE: a negation governing a verb
#      of CHANGE ("must never modify X"). Deliberately narrow -- verbs of ACTION
#      on a security surface ("never log the credential", "must not expose the
#      secret") are real requirements and still fire, and a negation in a
#      NEIGHBOURING clause suppresses nothing.
non_goal_heading = re.compile(
    r"^(#{1,6})\s*(?:[-*\d.\s]*)?(?:"
    r"non[-\s]?goals?|non[-\s]?objectives?|out[-\s]of[-\s]scope|not\s+in\s+scope|"
    r"exclusions?|explicitly\s+excluded|what\s+(?:this|it)\s+does\s+not"
    r")\b", re.I)
any_heading = re.compile(r"^(#{1,6})\s+\S")
negated_scope = re.compile(
    r"\b(?:do(?:es)?\s+not|don'?t|doesn'?t|must\s+not|mustn'?t|will\s+not|won'?t|"
    r"shall\s+not|cannot|can'?t|never|without|avoid|refrain\s+from)\b"
    r".{0,40}?"
    r"\b(?:touch(?:es|ed|ing)?|modif(?:y|ies|ied|ying)|chang(?:e|es|ed|ing)|"
    r"edit(?:s|ed|ing)?|alter(?:s|ed|ing)?|refactor(?:s|ed|ing)?|"
    r"renam(?:e|es|ed|ing)|mov(?:e|es|ed|ing)|rewrit(?:e|es|ing)|"
    r"replac(?:e|es|ed|ing)|affect(?:s|ed|ing)?|updat(?:e|es|ed|ing))\b", re.I)
untouched = re.compile(r"\b(?:unchanged|untouched|unmodified|out\s+of\s+scope|not\s+in\s+scope)\b", re.I)


# Suppression is scoped to the CLAUSE, not the line: "Do not rename the helper,
# and rotate the OAuth2 secret" is a boundary AND a real signal, and only the
# first half is the boundary. Em-dash / en-dash are clause punctuation too;
# a coordinating "and" without a comma is one clause on purpose — splitting on
# "and" would fire "do not touch the auth middleware and the permissions table"
# on its second half.
clause_split = re.compile(r"[;:,]|\.(?=\s|$)|[\u2013\u2014]")


def suppressed(clause, in_non_goal):
    if in_non_goal:
        return "non-goal section"
    if negated_scope.search(clause):
        return "negated scope verb"
    if untouched.search(clause):
        return "declared unchanged"
    return None


first_weak = None   # (path, number, name)
weak_names = set()
suppressed_count = 0
first_suppressed = None   # (path, number, name, why)

for path in sys.argv[1:]:
    non_goal_level = 0
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as artifact:
            for number, line in enumerate(artifact, 1):
                heading = any_heading.match(line)
                if heading:
                    level = len(heading.group(1))
                    if non_goal_heading.match(line):
                        non_goal_level = level
                    elif non_goal_level and level <= non_goal_level:
                        non_goal_level = 0
                # A heading is scanned like any other line -- `## Auth rework` is
                # the loudest signal an artifact carries.
                for clause in clause_split.split(line):
                    why = suppressed(clause, non_goal_level > 0)
                    for name, pattern in strong_signals:
                        if pattern.search(clause):
                            if why:
                                suppressed_count += 1
                                if first_suppressed is None:
                                    first_suppressed = (path, number, name, why)
                                break
                            print("{}:{}:term={}".format(path, number, name))
                            sys.exit(0)
                    else:
                        for name, pattern in weak_signals:
                            if pattern.search(clause):
                                if why:
                                    suppressed_count += 1
                                    if first_suppressed is None:
                                        first_suppressed = (path, number, name, why)
                                    continue
                                if first_weak is None:
                                    first_weak = (path, number, name)
                                weak_names.add(name)
    except OSError as exc:
        print("security-signal: cannot read {}: {}".format(path, exc), file=sys.stderr)
        sys.exit(2)

# Weak terms corroborate each other: two DISTINCT weak terms fire; one does not.
if first_weak is not None and len(weak_names) >= 2:
    print("{}:{}:term={} (corroborated by: {})".format(
        first_weak[0], first_weak[1], first_weak[2],
        ", ".join(sorted(weak_names - {first_weak[2]}))))
    sys.exit(0)
if suppressed_count:
    print("security-signal: no signal; {} contextual mention(s) suppressed "
          "(first: {}:{} term={} — {})".format(
              suppressed_count, first_suppressed[0], first_suppressed[1],
              first_suppressed[2], first_suppressed[3]), file=sys.stderr)
sys.exit(1)
PY
