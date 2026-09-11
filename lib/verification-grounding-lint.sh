#!/usr/bin/env bash
# Deterministic post-change repository-evidence gate for VERIFICATION.md.
set -euo pipefail

usage() {
  echo "usage: verification-grounding-lint.sh <VERIFICATION.md> [--repo <root>]... [--spec <SPEC.md>] [--criterion <id>]... [--feature-dir <dir>]" >&2
}

[[ $# -ge 1 ]] || { usage; exit 2; }
artifact="$1"
shift
repos=()
criteria=()
criteria_count=0
spec=""
feature_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      repos+=("$2"); shift 2;;
    --criterion)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      criteria[$criteria_count]="$2"; criteria_count=$((criteria_count+1)); shift 2;;
    --spec)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      spec="$2"; shift 2;;
    --feature-dir)
      [[ $# -ge 2 ]] || { usage; exit 2; }
      feature_dir="$2"; shift 2;;
    *) usage; exit 2;;
  esac
done
[[ ${#repos[@]} -gt 0 ]] || repos=(".")

# A v1 feature (feature.json's requirementsContract.format) never falls back to the
# legacy positional-numbering path below: task-008 AC1/AC3 -- rows are keyed by stable
# GE-ID/SC-ID and rechecked against their driver-owned observation record, never by
# SPEC document order. Legacy and no-contract features are unaffected.
if [[ -n "$feature_dir" ]]; then
  format="$(bash "$(dirname "${BASH_SOURCE[0]}")/feature-read.sh" "$feature_dir" -r --filter '.requirementsContract.format // "legacy"' 2>/dev/null || echo legacy)"
  if [[ "$format" == "v1" ]]; then
    [[ -n "$spec" ]] || { echo "usage: verification-grounding-lint.sh: --feature-dir with a v1 contract also requires --spec" >&2; exit 2; }
    PYTHONPATH="$(dirname "${BASH_SOURCE[0]}")${PYTHONPATH:+:$PYTHONPATH}" \
      python3 - "$artifact" "$feature_dir" "${repos[0]}" "$spec" <<'PYV1'
import json
import os
import re
import sys

import feature_read
from requirements import parse_spec
from execution_observation import eligible_row

artifact, feature_dir, root, spec_path = sys.argv[1:5]
flags = 0


def flag(line, message):
    global flags
    print('FLAG %s:%s: %s' % (artifact, line, message))
    flags += 1


contract = feature_read.load_state(feature_dir)["requirementsContract"]
try:
    spec_text = open(spec_path, encoding="utf-8").read()
    inventory = parse_spec(spec_text, spec_path, contract)
except (OSError, ValueError) as exc:
    flag(0, "SPEC is not readable as this feature's v1 contract: %s" % exc)
    print("verification-grounding-lint: %d violation(s)" % flags)
    sys.exit(1)
match = re.search(r"^scenario_checks: *(.*)$", spec_text, re.M)
checks = json.loads(match.group(1)) if match else {}

expected = {}
for requirement in inventory["requirements"]:
    for scenario in requirement["scenarios"]:
        expected["%s/%s" % (requirement["id"], scenario["id"])] = (requirement, scenario)

if not os.path.isfile(artifact):
    flag(0, "artifact does not exist")
    print("verification-grounding-lint: %d violation(s)" % flags)
    sys.exit(1)
text = open(artifact, encoding="utf-8").read()

# ## Repository grounding: same row grammar as the legacy path, keyed by GE-ID/SC-ID.
grounding_start = None
lines = text.splitlines()
for index, line in enumerate(lines):
    if line.strip() == "## Repository grounding":
        grounding_start = index + 1
        break
if grounding_start is None:
    flag(0, "missing ## Repository grounding section")
else:
    row_re = re.compile(r"^- criterion:\s*(.+?)\s*\|\s*implementation:\s*(.+?)\s*\|\s*integration:\s*(.+?)\s*$")
    ref_re = re.compile(r"^(.+):([1-9][0-9]*)\s+-\s+(.+)$")
    none_re = re.compile(r"^none\s+-\s+(.{10,})$", re.I)
    seen = set()
    for index in range(grounding_start, len(lines)):
        line = lines[index]
        if line.startswith("## "):
            break
        stripped = line.strip()
        if not stripped:
            continue
        match = row_re.match(stripped)
        if not match:
            continue
        criterion, implementation, integration = [p.strip() for p in match.groups()]
        seen.add(criterion)
        for label, value in (("implementation", implementation), ("integration", integration)):
            if label == "integration" and none_re.match(value):
                continue
            ref = ref_re.match(value)
            if not ref:
                flag(index + 1, "%s must be <repo-relative-file>:<line> - <what it proves>" % label)
                continue
            relative = ref.group(1).strip()
            candidate = os.path.realpath(os.path.join(root, relative))
            if os.path.isabs(relative) or ".." in relative.replace("\\", "/").split("/") or not os.path.isfile(candidate):
                flag(index + 1, "%s cites missing file %s" % (label, relative))
    for key in expected:
        if key not in seen:
            flag(grounding_start, "missing grounding row for scenario %s" % key)

# ## Acceptance criteria: v1 rows are keyed by GE-ID/SC-ID, never a numeric alias, and
# a PASS row must resolve to a fresh, eligible driver-owned observation record.
ac_start = None
for index, line in enumerate(lines):
    if line.strip() == "## Acceptance criteria":
        ac_start = index + 1
        break
if ac_start is None:
    flag(0, "missing ## Acceptance criteria section")
else:
    rows = {}
    for index in range(ac_start, len(lines)):
        line = lines[index]
        if line.strip().startswith("## "):
            break
        if not line.strip().startswith("|"):
            continue
        cells = [c.strip() for c in re.split(r"(?<!\\)\|", line.strip())[1:-1]]
        if len(cells) < 3 or set(cells[0]) <= set("-") or cells[0] in ("#", "ID", ""):
            continue
        key = cells[0]
        rows[key] = (index + 1, cells[2], cells[3] if len(cells) > 3 else "")
    for key, (line_no, status, evidence) in rows.items():
        if re.fullmatch(r"[0-9]+", key):
            flag(line_no, "acceptance row %s is a numeric alias; v1 rows are keyed GE-ID/SC-ID" % key)
            continue
        if key not in expected:
            flag(line_no, "acceptance row %s references a scenario not in the SPEC inventory" % key)
            continue
        requirement, scenario = expected[key]
        execution_match = re.search(r"execution:([0-9a-f]{32})", evidence)
        if status.upper().startswith("PASS"):
            if not execution_match:
                flag(line_no, "acceptance row %s is PASS but names no execution ID" % key)
                continue
            execution_id = execution_match.group(1)
            entry = checks.get(key) or {}
            binding = {"owner": contract["owner"], "requirement": requirement["id"],
                       "revision": requirement["revision"], "scenario": scenario["id"]}
            eligible, reasons = eligible_row(feature_dir, root, binding, entry.get("command") or "",
                                              entry.get("executionInputs"), execution_id)
            if not eligible:
                flag(line_no, "acceptance row %s claims PASS but execution %s is not current evidence: %s" % (
                    key, execution_id, "; ".join(reasons)))
    for key in expected:
        if key not in rows:
            flag(ac_start, "missing acceptance row for scenario %s" % key)

if flags:
    print("verification-grounding-lint: %d violation(s)" % flags)
    sys.exit(1)
print("verification-grounding-lint: ok")
PYV1
    exit $?
  fi
fi

python_args=("$artifact" "${repos[@]}" --)
if [[ "$criteria_count" -gt 0 ]]; then
  python_args+=("${criteria[@]}")
fi
LOOP_SPEC_GROUNDING_SPEC="$spec" python3 - "${python_args[@]}" <<'PY'
import os
import re
import sys

artifact = sys.argv[1]
separator = sys.argv.index('--')
roots = [os.path.realpath(p) for p in sys.argv[2:separator]]
expected = sys.argv[separator + 1:]
spec = os.environ.get('LOOP_SPEC_GROUNDING_SPEC', '')

# The grammar travels with the flag: the 6.2.0 haiku readme-sync run wrote "- none" and
# a table under the heading three times, and "malformed grounding row" gave it nothing
# to change.
ROW_HELP = ('expected one row per Good Enough criterion, exactly `- criterion: GE-001 | '
            'implementation: <repo-relative-file>:<line> - <what it proves> | integration: '
            '<repo-relative-file>:<line> - <what it proves>` (or `integration: none - <reason '
            'of ten or more characters>`); no table, no bare `- none`')

def fail(line, message):
    print('FLAG %s:%s: %s' % (artifact, line, message))
    raise SystemExit(1)

if not os.path.isfile(artifact):
    fail(0, 'artifact does not exist')

with open(artifact, encoding='utf-8') as handle:
    lines = handle.read().splitlines()

if spec:
    if not os.path.isfile(spec):
        fail(0, 'SPEC artifact does not exist')
    with open(spec, encoding='utf-8') as handle:
        spec_lines = handle.read().splitlines()
    in_good_enough = False
    good_enough_count = 0
    for line in spec_lines:
        if line.strip() == '### Good Enough':
            in_good_enough = True
            continue
        if in_good_enough and line.startswith('### '):
            break
        if in_good_enough and re.match(r'^- \[[ xX]\]\s+\S', line.strip()):
            good_enough_count += 1
    if good_enough_count == 0:
        fail(0, 'SPEC has no Good Enough criteria')
    expected.extend('GE-%03d' % number for number in range(1, good_enough_count + 1))

start = None
for index, line in enumerate(lines):
    if line.strip() == '## Repository grounding':
        start = index + 1
        break
if start is None:
    fail(0, 'missing ## Repository grounding section')

# Rows are long (criterion + two file:line refs + proofs) and model-authored
# markdown legitimately wraps them; join indented continuation lines onto the
# preceding row before matching. FLAG line numbers keep the row's first line.
section = []
for index in range(start, len(lines)):
    line = lines[index]
    if line.startswith('## '):
        break
    if not line.strip():
        continue
    if section and line[:1] in (' ', '\t') and section[-1][1].startswith('- '):
        prev_no, prev_text = section[-1]
        section[-1] = (prev_no, prev_text + ' ' + line.strip())
        continue
    section.append((index + 1, line.strip()))

row_re = re.compile(
    r'^- criterion:\s*(.+?)\s*\|\s*implementation:\s*(.+?)\s*'
    r'\|\s*integration:\s*(.+?)\s*$')
ref_re = re.compile(r'^(.+):([1-9][0-9]*)\s+-\s+(.+)$')
none_re = re.compile(r'^none\s+-\s+(.{10,})$', re.I)
rows = {}

def validate_ref(value, line, label):
    match = ref_re.match(value)
    if not match:
        fail(line, '%s must be <repo-relative-file>:<line> - <what it proves>' % label)
    relative, line_text, proof = match.groups()
    relative = relative.strip()
    if os.path.isabs(relative) or '..' in relative.replace('\\', '/').split('/'):
        fail(line, '%s path must stay within a declared repository root' % label)
    cited_line = int(line_text)
    for root in roots:
        candidate = os.path.realpath(os.path.join(root, relative))
        try:
            contained = os.path.commonpath([root, candidate]) == root
        except ValueError:
            contained = False
        if not contained or not os.path.isfile(candidate):
            continue
        with open(candidate, encoding='utf-8', errors='replace') as cited:
            line_count = sum(1 for _ in cited)
        if cited_line > line_count:
            fail(line, '%s line %s exceeds %s line count %s' %
                 (label, cited_line, relative, line_count))
        if not proof.strip():
            fail(line, '%s must explain what the reference proves' % label)
        return
    fail(line, '%s cites missing file %s' % (label, relative))

for line_number, line in section:
    match = row_re.match(line)
    if not match:
        fail(line_number, 'malformed grounding row; ' + ROW_HELP)
    criterion, implementation, integration = [part.strip() for part in match.groups()]
    if criterion in rows:
        fail(line_number, 'duplicate grounding row for criterion %s' % criterion)
    validate_ref(implementation, line_number, 'implementation')
    if not none_re.match(integration):
        validate_ref(integration, line_number, 'integration')
    rows[criterion] = line_number

if not rows:
    fail(start + 1, 'repository grounding section has no evidence rows; ' + ROW_HELP)
for criterion in expected:
    if criterion not in rows:
        fail(start + 1, 'missing grounding row for criterion %s' % criterion)

print('verification-grounding-lint: ok')
PY
