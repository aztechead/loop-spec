#!/usr/bin/env bash
# Meta-test: hook suites must feed the hook's payload by redirect, never by pipe.
#
# A hook that exits before draining stdin (kill switch, out-of-scope project,
# unparseable payload) closes the pipe while the writer is still queued to write.
# The writer then dies of SIGPIPE, and `set -o pipefail` reports the PIPELINE as
# 141 even though the hook itself exited 0 -- a failure that appears only when
# run-all.sh runs suites in parallel and the scheduler delays the writer. A
# here-string has no writer process to kill, so the status is the hook's own.
#
# Write `bash "$HOOK" <<<"$payload"`, not `echo "$payload" | bash "$HOOK"`.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

while IFS= read -r suite; do
  rel="${suite#"$REPO_ROOT"/}"
  piped="$(python3 - "$suite" <<'PY'
import re, sys
# Join backslash continuations so a pipe split across lines is still one command.
text = re.sub(r"\\\n\s*", " ", open(sys.argv[1]).read())
hits = []
for number, line in enumerate(text.split("\n"), 1):
    if line.lstrip().startswith("#"):
        continue
    left, sep, right = line.partition(" | ")
    if not sep or "$HOOK" not in right:
        continue
    if re.search(r"\b(echo|printf|cat)\b", left):
        hits.append("%d: %s" % (number, line.strip()))
print("\n".join(hits))
PY
)"
  if [[ -z "$piped" ]]; then
    PASS=$((PASS + 1))
  else
    echo "FAIL: $rel pipes a payload into the hook (SIGPIPE race under pipefail):"
    printf '  %s\n' "$piped"
    FAIL=$((FAIL + 1))
  fi
done < <(find "$REPO_ROOT/hooks" -name "*.test.sh" | sort)

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
