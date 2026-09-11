#!/usr/bin/env bash
# converged-floor.sh - Deterministic floor under ITERATE's converged verdict.
#
# The judge's `converged: true` is a model judgment that ends the loop. This
# probe is the mechanical floor beneath it (docs/determinism-audit.md item 2,
# same shape as the deferral gate): convergence cannot be claimed over
# unverified scope. It never declares convergence — it can only VETO a
# converged verdict that the verification record does not support.
#
# Checks, given SPEC.md and VERIFICATION.md:
#   1. Every Good Enough criterion (GE-001..GE-NNN, numbered by SPEC checkbox
#      order) has a `- criterion: GE-NNN |` grounding row in VERIFICATION.md.
#   2. Every criterion has exactly one PASS result in "## Acceptance criteria".
#
# Acceptance table grammar (agents/verifier.md writes it, this probe reads it):
#   - one row per Good Enough criterion, keyed by `GE-NNN` or its number in the
#     column whose header is `#`, `ID`, or `Criterion ID` (else the first column);
#   - the status in the column whose header is `Status`, `Result`, `Outcome`, or
#     `Verdict` (else the third column); the cell BEGINS with PASS, FAIL, or N/A,
#     so `PASS (12 passed)` and `**FAIL**` read; `\|` inside a cell is a literal pipe.
#   A record this probe cannot read is a VERIFY defect, not an ITERATE one:
#   `--shape` checks only the grammar (each criterion has exactly one row with a
#   readable status; FAIL is fine) so `phase-exit.sh verify` answers REDO before
#   a converged verdict can be vetoed over formatting (the 6.3.0 fastapi runs
#   rewound to an empty EXECUTE that way).
#
# Usage: converged-floor.sh [--shape] <spec-path> <verification-path>
#
# Exit codes:
#   0  floor holds
#   1  floor violated (each violation printed as "FLOOR <message>") — treat the
#      verdict as NOT converged; unreadable VERIFICATION.md with an existing
#      Good Enough section also fails (fail closed: VERIFY must have written it)
#   2  bad invocation
#
# Always ends with one ANSWER+REASON line:
#   converged-floor: ok (N criteria verified)  |  converged-floor: N violation(s)
#   converged-floor: shape ok (N criteria)     (--shape)
set -uo pipefail

shape=0
feature_dir=""
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --shape) shape=1; shift ;;
    --feature-dir) feature_dir="${2:-}"; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]+"${args[@]}"}"
spec_path="${1:-}"
verification_path="${2:-}"
[[ -n "$spec_path" && -n "$verification_path" ]] || {
  echo "usage: converged-floor.sh [--shape] [--feature-dir <dir>] <spec-path> <verification-path>" >&2
  exit 2
}

# A v1 feature (feature.json's requirementsContract.format) never falls back to the
# legacy positional-numbering floor below: v1 rows are keyed by stable GE-ID/SC-ID and
# (outside --shape) must resolve to a fresh, eligible driver-owned observation record
# through the same validator verification-grounding-lint.sh uses (task-008 AC2).
# simplicity: this format-probe/PYTHONPATH opening repeats
# lib/verification-grounding-lint.sh's own v1 branch; a third caller would earn a
# shared helper, but neither script's file-ownership entry in
# docs/loop-spec/features/release-7-0/PLAN.md (task-008) lists a home for one, and
# extraction is not worth a new file for two five-line openings (duplication-scan).
if [[ -n "$feature_dir" ]]; then
  format="$(bash "$(dirname "${BASH_SOURCE[0]}")/feature-read.sh" "$feature_dir" -r --filter '.requirementsContract.format // "legacy"' 2>/dev/null || echo legacy)"
  if [[ "$format" == "v1" ]]; then
    PYTHONPATH="$(dirname "${BASH_SOURCE[0]}")${PYTHONPATH:+:$PYTHONPATH}" \
      python3 - "$feature_dir" "$spec_path" "$verification_path" "$shape" <<'PYV1'
import json
import os
import re
import sys

from requirements import parse_spec
from execution_observation import eligible_row

feature_dir, spec_path, verification_path, shape = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
violations = 0


def veto(message):
    global violations
    print("FLOOR " + message)
    violations += 1


with open(os.path.join(feature_dir, "feature.json"), encoding="utf-8") as fh:
    state = json.load(fh)
contract = state["requirementsContract"]
workspace = state.get("workspace")
root = workspace.get("root") if isinstance(workspace, dict) and (workspace.get("mode") or "single") != "single" else None
if not root:
    import subprocess
    root = subprocess.run(["git", "-C", feature_dir, "rev-parse", "--show-toplevel"],
                           stdout=subprocess.PIPE, universal_newlines=True).stdout.strip()

try:
    spec_text = open(spec_path, encoding="utf-8").read()
except OSError:
    print("FLOOR spec is not readable: %s" % spec_path)
    print("converged-floor: 1 violation(s)")
    sys.exit(1)
try:
    inventory = parse_spec(spec_text, spec_path, contract)
except ValueError as exc:
    print("FLOOR spec is not a readable v1 contract: %s" % exc)
    print("converged-floor: 1 violation(s)")
    sys.exit(1)
match = re.search(r"^scenario_checks: *(.*)$", spec_text, re.M)
checks = json.loads(match.group(1)) if match else {}

expected = []
for requirement in inventory["requirements"]:
    for scenario in requirement["scenarios"]:
        expected.append((requirement, scenario))
if not expected:
    print("FLOOR no Good Enough scenarios in %s" % spec_path)
    print("converged-floor: 1 violation(s)")
    sys.exit(1)

try:
    verification_text = open(verification_path, encoding="utf-8").read()
except OSError:
    print("FLOOR VERIFICATION.md is not readable (%s) — a converged verdict needs the verification record" % verification_path)
    print("converged-floor: 1 violation(s)")
    sys.exit(1)
lines = verification_text.splitlines()
ac_start = None
for index, line in enumerate(lines):
    if line.strip() == "## Acceptance criteria":
        ac_start = index + 1
        break
rows = {}
# simplicity: this Acceptance-criteria row scan repeats
# lib/verification-grounding-lint.sh's own v1 row parser; same call as the
# format-probe opening above -- no shared home in this task's file-ownership list,
# and a two-caller ~doc-parsing loop is not worth a new module for it.
blocked_evidence = re.compile(
    r'(^|[^a-z])(blocked|could not run|not run|never ran|did not run|unable to run|skipped|reauth|'
    r"credentials? (expired|locked)|not verified|unverified)([^a-z]|$)", re.I)
if ac_start is not None:
    for index in range(ac_start, len(lines)):
        line = lines[index]
        if line.strip().startswith("## "):
            break
        if not line.strip().startswith("|"):
            continue
        cells = [c.strip() for c in re.split(r"(?<!\\)\|", line.strip())[1:-1]]
        if len(cells) < 3 or set(cells[0]) <= set("-") or cells[0] in ("#", "ID", ""):
            continue
        rows.setdefault(cells[0], []).append((cells[2], cells[3] if len(cells) > 3 else ""))

for requirement, scenario in expected:
    key = "%s/%s" % (requirement["id"], scenario["id"])
    matches = rows.get(key) or []
    if len(matches) != 1:
        result = "missing (no acceptance row keyed %s)" % key if not matches else "duplicate (%d acceptance rows keyed %s)" % (len(matches), key)
        veto("%s acceptance result is %s in %s" % (key, result, verification_path))
        continue
    status, evidence = matches[0]
    status_norm = status.upper()
    if shape:
        if not re.match(r"^(PASS|FAIL|BLOCKED|N/A)", status_norm):
            veto("%s acceptance result is unreadable (status cell '%s' must begin with PASS, FAIL, BLOCKED, or N/A) in %s" % (key, status, verification_path))
        continue
    if status_norm.startswith("FAIL"):
        veto("acceptance table row still FAIL: %s" % key)
        continue
    if status_norm.startswith("BLOCKED"):
        veto("acceptance table row BLOCKED (an operator must clear it before this can converge): %s" % key)
        continue
    if not status_norm.startswith("PASS"):
        veto("%s acceptance result is non-PASS (%s) in %s" % (key, status, verification_path))
        continue
    if blocked_evidence.search(evidence):
        veto("acceptance table row is PASS but its evidence says the check did not run (mark it BLOCKED): %s" % key)
        continue
    execution_match = re.search(r"execution:([0-9a-f]{32})", evidence)
    if not execution_match:
        veto("%s is PASS but names no execution ID in %s" % (key, verification_path))
        continue
    entry = checks.get(key) or {}
    binding = {"owner": contract["owner"], "requirement": requirement["id"],
               "revision": requirement["revision"], "scenario": scenario["id"]}
    eligible, reasons = eligible_row(feature_dir, root, binding, entry.get("command") or "",
                                      entry.get("executionInputs"), execution_match.group(1))
    if not eligible:
        veto("%s PASS execution %s is not current evidence: %s" % (key, execution_match.group(1), "; ".join(reasons)))

if violations:
    print("converged-floor: %d violation(s)" % violations)
    sys.exit(1)
if shape:
    print("converged-floor: shape ok (%d criteria)" % len(expected))
else:
    print("converged-floor: ok (%d criteria verified)" % len(expected))
PYV1
    exit $?
  fi
fi

# A missing contract is missing evidence, never an empty success condition.
spec_content=""
if ! spec_content=$(cat "$spec_path" 2>/dev/null); then
  echo "FLOOR spec is not readable: $spec_path"
  echo "converged-floor: 1 violation(s)"
  exit 1
fi

criteria_count=$(printf '%s\n' "$spec_content" \
  | awk '/^###[[:space:]]+Good Enough/{flag=1; next} flag && /^#{1,6}[[:space:]]/{flag=0} flag' \
  | grep -cE '^\s*- \[[ xX]\]' || true)

if [[ "$criteria_count" -eq 0 ]]; then
  echo "FLOOR no Good Enough checkbox criteria in $spec_path"
  echo "converged-floor: 1 violation(s)"
  exit 1
fi

violations=0
if ! verification_content=$(cat "$verification_path" 2>/dev/null); then
  echo "FLOOR VERIFICATION.md is not readable ($verification_path) — a converged verdict needs the verification record"
  echo "converged-floor: 1 violation(s)"
  exit 1
fi

acceptance_rows="$(awk '
  /^##[[:space:]]+Acceptance criteria[[:space:]]*$/ {active=1; next}
  active && /^#/ {active=0}
  active && /^\|/ {print}
' <<<"$verification_content")"

# One pass over the table: the header names the key and status columns, every later
# row is split with escaped pipes protected, and each row prints `key<TAB>status`
# where status is PASS, FAIL, N/A, or the raw cell (`empty` for none). Separator
# rows carry no cells and print nothing.
table_rows="$(awk '
  function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); gsub(/^[*`]+|[*`]+$/, "", s); return s }
  { gsub(/\\\|/, "\001"); n = split($0, c, "|") }
  NR == 1 {
    for (k = 2; k < n; k++) {
      h = tolower(trim(c[k]))
      if (!key_col && h ~ /^(#|id|no\.?|criterion id|ge id)$/) key_col = k
      if (!status_col && h ~ /^(status|result|outcome|verdict)$/) status_col = k
    }
    if (!key_col) key_col = 2
    if (!status_col) status_col = 4
    evidence_col = status_col + 1
    next
  }
  {
    all_sep = 1
    for (k = 2; k < n; k++) if (trim(c[k]) !~ /^:?-+:?$/) all_sep = 0
    if (all_sep) next
    key = trim(c[key_col]); s = trim(c[status_col]); gsub(/\001/, "|", s)
    ev = tolower(trim(c[evidence_col])); gsub(/\001/, "|", ev)
    if (s ~ /^PASS([^A-Za-z]|$)/) s = "PASS"
    else if (s ~ /^FAIL([^A-Za-z]|$)/) s = "FAIL"
    else if (s ~ /^BLOCKED([^A-Za-z]|$)/) s = "BLOCKED"
    else if (s ~ /^N\/A([^A-Za-z]|$)/) s = "N/A"
    else if (s == "") s = "empty"
    print key "\t" s "\t" ev
  }
' <<<"$acceptance_rows")"

for ((i = 1; i <= criteria_count; i++)); do
  ge_id=$(printf 'GE-%03d' "$i")
  if (( shape == 0 )) && ! grep -qE "^\s*- criterion:\s*${ge_id}\b" <<<"$verification_content"; then
    echo "FLOOR $ge_id has no grounding row in $verification_path — unverified Good Enough scope cannot converge"
    violations=$((violations + 1))
  fi
  matches="$(awk -F'\t' -v id="$ge_id" -v number="$i" '$1 == id || $1 == number {print $2}' <<<"$table_rows")"
  count=0; [[ -n "$matches" ]] && count="$(wc -l <<<"$matches" | tr -d ' ')"
  status="$(head -1 <<<"$matches")"
  if (( count != 1 )); then
    (( count == 0 )) && result="missing (no acceptance row keyed $ge_id or $i)" || result="duplicate ($count acceptance rows keyed $ge_id or $i)"
  elif (( shape )); then
    case "$status" in PASS|FAIL|BLOCKED|N/A) result="PASS" ;; *) result="unreadable (status cell '$status' must begin with PASS, FAIL, BLOCKED, or N/A)" ;; esac
  else
    [[ "$status" == "PASS" ]] && result="PASS" || result="non-PASS ($status)"
  fi
  if [[ "$result" != "PASS" ]]; then
    echo "FLOOR $ge_id acceptance result is $result in $verification_path"
    violations=$((violations + 1))
  fi
done

# Acceptance table: any FAIL or BLOCKED status cell vetoes convergence outright, and so
# does a PASS whose evidence says the check never ran. A live verifier wrote PASS for
# "terragrunt plan succeeds" with the evidence "plan invocation is blocked by the reauth
# lock" because PASS was the only cell that let the feature converge (PR 93); BLOCKED is
# that cell now, and it does not converge either.
blocked_evidence='(^|[^a-z])(blocked|could not run|not run|never ran|did not run|unable to run|skipped|reauth|credentials? (expired|locked)|not verified|unverified)([^a-z]|$)'
if (( shape == 0 )); then
  while IFS=$'\t' read -r key status evidence; do
    if [[ "$status" == "FAIL" ]]; then
      echo "FLOOR acceptance table row still FAIL: $key"
    elif [[ "$status" == "BLOCKED" ]]; then
      echo "FLOOR acceptance table row BLOCKED (an operator must clear it before this can converge): $key"
    elif [[ "$status" == "PASS" && "$evidence" =~ $blocked_evidence ]]; then
      echo "FLOOR acceptance table row is PASS but its evidence says the check did not run (mark it BLOCKED): $key"
    else
      continue
    fi
    violations=$((violations + 1))
  done <<<"$table_rows"
fi

if [[ "$violations" -gt 0 ]]; then
  echo "converged-floor: $violations violation(s)"
  exit 1
fi
if (( shape )); then echo "converged-floor: shape ok ($criteria_count criteria)"; else echo "converged-floor: ok ($criteria_count criteria verified)"; fi
