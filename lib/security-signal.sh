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

signals = [
    ("auth", re.compile(r"\bauth\b", re.I)),
    ("auth protocol", re.compile(r"\b(?:oauth2?|authn|authz|unauthenticated|unauthorized|reauthenticat[a-z]*)\b", re.I)),
    ("authentication", re.compile(r"\bauthenticat[a-z]*\b", re.I)),
    ("authorization", re.compile(r"\b(?:re|de|pre)?authoriz[a-z]*\b", re.I)),
    ("permission", re.compile(r"\bpermissions?\b", re.I)),
    ("credential", re.compile(r"\bcredentials?\b", re.I)),
    ("secret", re.compile(r"\bsecrets?\b", re.I)),
    ("token", re.compile(r"\btokens?\b", re.I)),
    ("cryptography", re.compile(r"\b(?:cryptograph[a-z]*|encrypt[a-z]*|decrypt[a-z]*|crypto(?:currency|graphic|graphy)?|crypt)\b", re.I)),
    ("payment", re.compile(r"\bpayments?\b", re.I)),
    ("billing", re.compile(r"\bbilling\b", re.I)),
    ("PII", re.compile(r"\bpii\b", re.I)),
    ("migration", re.compile(r"\bmigrat[a-z]*\b", re.I)),
    ("deletion", re.compile(r"\bdelet[a-z]*\b", re.I)),
]

for path in sys.argv[1:]:
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as artifact:
            for number, line in enumerate(artifact, 1):
                for name, pattern in signals:
                    if pattern.search(line):
                        print("{}:{}:term={}".format(path, number, name))
                        sys.exit(0)
    except OSError as exc:
        print("security-signal: cannot read {}: {}".format(path, exc), file=sys.stderr)
        sys.exit(2)
sys.exit(1)
PY
