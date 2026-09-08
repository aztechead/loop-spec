#!/usr/bin/env bash
# verify-lint.sh - Flag verify commands whose shape cannot prove the task: absence-only,
# self-reported, or a plan with no outcome assertion.
#
# Why: the first PLAN critique round on a live run (evals/findings-2026-09-07-tf-meldn.md,
# round 4) cost nine minutes and half its majors had a fixed shape a probe reads in
# milliseconds: a verify that only asserts a bad token is ABSENT (an empty file passes),
# a verify that greps a status out of a document the same task writes (the task grades
# itself), and a `terragrunt plan` with nothing asserted about its outcome (any diff
# passes). The challenger still runs; it no longer spends its round on these.
#
# Usage:
#   verify-lint.sh <tasks.json | ->
#
# Rules, on each task's verifyCommand:
#   absence-only   every assertion is a negated grep (`! grep`, `grep -v ...` as the
#                  whole check) and nothing asserts presence: add a positive assertion
#   self-reported  a grep for a status word (No changes, PASS, FAIL, STATUS, exit code,
#                  invalid_, success, blocked) in a .md/.txt file the task itself lists
#                  in files[]: run the command in the verify instead of reading a note
#   plan-outcome   a `terragrunt|tofu|terraform plan` with no `-detailed-exitcode`, no
#                  `No changes` / `Plan:` grep, and no `-out=` after it: assert the outcome
#
# Output: FLAG <task-id>: <rule> -> <verifyCommand> per finding, then a summary line.
# Exit: 0 clean, 1 findings, 2 usage or unreadable input.
set -uo pipefail

[[ $# -eq 1 ]] || { echo "usage: verify-lint.sh <tasks.json | ->" >&2; exit 2; }
if [[ "$1" == "-" ]]; then input="$(cat)"; else
  [[ -f "$1" ]] || { echo "verify-lint: tasks file not found: $1" >&2; exit 2; }
  input="$(cat "$1")"
fi
[[ "$input" =~ [^[:space:]] ]] || { echo "verify-lint: empty input" >&2; exit 2; }

python3 - "$input" <<'PY'
import json
import re
import shlex
import sys

try:
    tasks = json.loads(sys.argv[1])
except ValueError as exc:
    print("verify-lint: input is not JSON: %s" % exc, file=sys.stderr)
    raise SystemExit(2)
if isinstance(tasks, dict) and isinstance(tasks.get("tasks"), list):
    tasks = tasks["tasks"]
if not isinstance(tasks, list):
    print("verify-lint: input must be a JSON array of tasks", file=sys.stderr)
    raise SystemExit(2)

STATUS = re.compile(r"No changes|\bPASS\b|\bFAIL\b|\bSTATUS\b|exit code|invalid_|\bsuccess|\bblocked", re.I)
PLAN_OUTCOME = re.compile(r"-detailed-exitcode|No changes|Plan:|-out=|\bexit\b|\$\?")


def segments(cmd):
    """Top-level segments split on |, ||, &&, ; outside quotes."""
    lex = shlex.shlex(cmd, posix=True, punctuation_chars="|&;()")
    lex.whitespace_split = True
    segs, cur = [], []
    try:
        for tok in lex:
            if tok in ("|", "||", "&&", ";", "(", ")"):
                if cur:
                    segs.append(cur)
                cur = []
            else:
                cur.append(tok)
    except ValueError:
        return None
    if cur:
        segs.append(cur)
    return segs


def is_assertion(words):
    return bool(words) and words[0] not in ("cd", "echo", "printf", "export", "env", "true", "set")


findings = 0
for t in tasks:
    if not isinstance(t, dict):
        continue
    tid = t.get("id", "?")
    cmd = str(t.get("verifyCommand") or "")
    if not cmd.strip():
        continue
    segs = segments(cmd)
    if segs is None:
        continue
    files = [str(f) for f in (t.get("files") or [])]
    notes = [f for f in files if f.lower().endswith((".md", ".txt"))]

    # absence-only: every assertion segment is a negation.
    assertions = [w for w in segs if is_assertion(w)]
    negated = [w for w in assertions if w[0] == "!" or (w[0] in ("grep", "egrep", "fgrep") and any(a.startswith("-") and "v" in a and not a.startswith("--") for a in w[1:4]) and not any(a in ("-c",) for a in w))]
    if assertions and len(negated) == len(assertions):
        print("FLAG %s: absence-only -> %s" % (tid, cmd))
        findings += 1

    # self-reported: a status word grepped out of a note this task writes. The grep may
    # sit inside a `$( )` or a `[ ]`, so this reads the whole command, not the segments.
    if "grep" in cmd and STATUS.search(cmd) and any(n in cmd or n.rsplit("/", 1)[-1] in cmd for n in notes):
        print("FLAG %s: self-reported -> %s" % (tid, cmd))
        findings += 1
    # plan-outcome: a plan segment (not a quoted mention of one) with nothing asserted.
    elif any(w and w[0].rsplit("/", 1)[-1] in ("terragrunt", "tofu", "terraform") and "plan" in w[1:] for w in segs) \
            and not PLAN_OUTCOME.search(cmd):
        print("FLAG %s: plan-outcome -> %s" % (tid, cmd))
        findings += 1

if findings:
    print("verify-lint: %d verify command(s) cannot prove their task (absence-only, self-reported, or plan without an outcome)." % findings, file=sys.stderr)
    raise SystemExit(1)
print("verify-lint: ok (every verify asserts an outcome it does not author)")
PY
