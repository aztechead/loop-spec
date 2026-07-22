#!/usr/bin/env bash
# Deterministic post-change repository-evidence gate for VERIFICATION.md.
set -euo pipefail

usage() {
  echo "usage: verification-grounding-lint.sh <VERIFICATION.md> [--repo <root>]... [--spec <SPEC.md>] [--criterion <id>]..." >&2
}

[[ $# -ge 1 ]] || { usage; exit 2; }
artifact="$1"
shift
repos=()
criteria=()
criteria_count=0
spec=""
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
    *) usage; exit 2;;
  esac
done
[[ ${#repos[@]} -gt 0 ]] || repos=(".")

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

section = []
for index in range(start, len(lines)):
    if lines[index].startswith('## '):
        break
    if lines[index].strip():
        section.append((index + 1, lines[index].strip()))

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
        fail(line_number, 'malformed grounding row')
    criterion, implementation, integration = [part.strip() for part in match.groups()]
    if criterion in rows:
        fail(line_number, 'duplicate grounding row for criterion %s' % criterion)
    validate_ref(implementation, line_number, 'implementation')
    if not none_re.match(integration):
        validate_ref(integration, line_number, 'integration')
    rows[criterion] = line_number

if not rows:
    fail(start + 1, 'repository grounding section has no evidence rows')
for criterion in expected:
    if criterion not in rows:
        fail(start + 1, 'missing grounding row for criterion %s' % criterion)

print('verification-grounding-lint: ok')
PY
