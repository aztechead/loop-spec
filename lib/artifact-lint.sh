#!/usr/bin/env bash
# artifact-lint.sh - Structural format gate for model-authored phase artifacts.
#
# Why: every phase hands the next phase artifacts a model wrote (SPEC.md, PLAN.md,
# PATTERNS.md, VERIFICATION.md, the tasks[] JSON). The existing gates are semantic
# (criteria coverage, grounding, acceptance quality) and silently assume the artifact
# is STRUCTURALLY well-formed — the section headings exist, task blocks carry their
# required fields, the file is not wrapped in a stray code fence, the JSON parses.
# When a producer drifts from the template, the consumer phase burns cycles
# re-deriving or repairing the artifact instead of doing its own job (observed in
# both the Claude Code and OpenCode harnesses). This probe makes the format contract
# deterministic and pins the repair on the PRODUCER, at its own phase exit.
#
# Usage:
#   artifact-lint.sh spec         <SPEC.md path | ->
#   artifact-lint.sh plan         <PLAN.md path | ->
#   artifact-lint.sh patterns     <PATTERNS.md path | ->
#   artifact-lint.sh verification <VERIFICATION.md path | ->
#   artifact-lint.sh tasks        <tasks JSON path | ->
#   artifact-lint.sh json         <path> [<path>...]
#
# Output: one `FLAG <path>:<line>: <message>` per structural defect, then a final
# one-line answer with the reason: `artifact-lint: ok (<type>: <path>)` or
# `artifact-lint: <n> flag(s) (<type>: <path>)`.
#
# Exit codes: 0 clean, 1 any FLAG (including unreadable/empty artifact — fail safe),
# 2 bad invocation.
#
# Scope guard: this checks STRUCTURE only. Semantic gates stay where they are:
# acceptance-lint.sh (criterion quality), grounding-lint.sh (## Grounding content),
# criteria-coverage.sh / decision-coverage.sh (SPEC->PLAN handoff),
# verification-grounding-lint.sh (grounding row evidence).
set -uo pipefail

type="${1:-}"
case "$type" in
  spec|plan|patterns|verification|tasks) [[ $# -eq 2 ]] || { echo "usage: artifact-lint.sh $type <path|->" >&2; exit 2; } ;;
  json) [[ $# -ge 2 ]] || { echo "usage: artifact-lint.sh json <path> [<path>...]" >&2; exit 2; } ;;
  *) echo "usage: artifact-lint.sh <spec|plan|patterns|verification|tasks|json> <path> [...]" >&2; exit 2 ;;
esac
shift

# The python script below is fed to the interpreter over stdin, so a `-` path cannot
# also be read from stdin there. Slurp it into a temp file first.
args=()
stdin_tmp=""
for p in "$@"; do
  if [[ "$p" == "-" ]]; then
    stdin_tmp="$(mktemp "${TMPDIR:-/tmp}/artifact-lint-stdin.XXXXXX")"
    cat > "$stdin_tmp"
    args+=("--stdin:$stdin_tmp")
  else
    args+=("$p")
  fi
done
trap '[[ -n "$stdin_tmp" ]] && rm -f "$stdin_tmp"' EXIT

python3 - "$type" "${args[@]}" <<'PY'
import json
import re
import sys

atype = sys.argv[1]
paths = sys.argv[2:]

flags = 0


def flag(path, line, message):
    global flags
    print('FLAG %s:%s: %s' % (path, line, message))
    flags += 1


def read_artifact(path):
    """Return (display_path, bytes) or (display_path, None) after flagging."""
    display = path
    if path.startswith('--stdin:'):
        display, path = '<stdin>', path[len('--stdin:'):]
    try:
        data = open(path, 'rb').read()
    except OSError as exc:
        flag(display, 0, 'artifact is unreadable: %s' % exc)
        return display, None
    if not data.strip():
        flag(display, 0, 'artifact is empty')
        return display, None
    return display, data


# Template placeholder lines that indicate an unfilled artifact. Matched as whole
# stripped lines only — real artifacts legitimately contain `{slug}`-style text
# inside prose and code, so a substring scan would false-positive.
UNFILLED = {
    '# {feature_title}',
    '# {feature_title} - Implementation Plan',
    '# {feature_title} - Verification',
    '# PATTERNS.md - {slug}',
    '**Slug:** `{slug}`',
    '**Created:** {created_at}',
    '### task-001: {subject}',
    '## Concept: {name}',
}


def markdown_scan(display, data, allow_frontmatter):
    """Generic well-formedness. Returns (lines, mask) where mask[i] is True for
    lines OUTSIDE code fences (heading checks must ignore fenced content)."""
    if b'\r\n' in data:
        line_no = data.split(b'\r\n')[0].count(b'\n') + 1
        flag(display, line_no, 'CRLF line endings (write LF-only)')
        data = data.replace(b'\r\n', b'\n')
    try:
        text = data.decode('utf-8')
    except UnicodeDecodeError as exc:
        flag(display, 0, 'artifact is not valid UTF-8: %s' % exc)
        return None, None

    lines = text.splitlines()
    body_start = 0
    if allow_frontmatter and lines and lines[0].strip() == '---':
        for i in range(1, len(lines)):
            if lines[i].strip() == '---':
                body_start = i + 1
                break
        else:
            flag(display, 1, 'unclosed YAML frontmatter (opening --- has no closing ---)')
            body_start = 1

    first = None
    for i in range(body_start, len(lines)):
        if lines[i].strip():
            first = i
            break
    if first is None:
        flag(display, body_start + 1, 'no content after frontmatter')
        return lines, [True] * len(lines)

    if lines[first].lstrip().startswith('```'):
        flag(display, first + 1, 'artifact starts with a code fence — the whole file '
             'appears to be wrapped in ``` (write the markdown directly, not fenced)')
    elif not lines[first].startswith('# '):
        flag(display, first + 1, "first content line must be the '# ' H1 title "
             '(found: %r)' % lines[first][:60])

    mask = []
    in_fence = False
    last_fence_line = 0
    for i, line in enumerate(lines):
        stripped = line.lstrip()
        if stripped.startswith('```'):
            in_fence = not in_fence
            last_fence_line = i + 1
            mask.append(False)
            continue
        mask.append(not in_fence)
    if in_fence:
        flag(display, last_fence_line, 'unbalanced code fence — a ``` block is never closed')
        # Headings after the unclosed fence are real content to a renderer that
        # auto-closes; treat everything as visible so section checks still run.
        mask = [True] * len(lines)

    for i, line in enumerate(lines):
        if mask[i] and line.strip() in UNFILLED:
            flag(display, i + 1, 'unfilled template placeholder line: %s' % line.strip())

    return lines, mask


def visible(lines, mask):
    return [(i + 1, lines[i]) for i in range(len(lines)) if mask[i]]


def require_heading(display, lines, mask, heading):
    for no, line in visible(lines, mask):
        if line.strip() == heading or line.strip().startswith(heading + ' '):
            return no
    flag(display, 0, "missing required section heading '%s'" % heading)
    return None


def lint_spec(display, data):
    lines, mask = markdown_scan(display, data, allow_frontmatter=True)
    if lines is None:
        return
    require_heading(display, lines, mask, '## Problem')
    require_heading(display, lines, mask, '## Success criteria')
    ge = require_heading(display, lines, mask, '### Good Enough')
    require_heading(display, lines, mask, '## Grounding')
    if ge is not None:
        count = 0
        for no, line in visible(lines, mask):
            if no <= ge:
                continue
            s = line.strip()
            if s.startswith('## ') or s.startswith('### '):
                break
            if re.match(r'^- \[[ xX]\]\s+\S', s):
                count += 1
        if count == 0:
            flag(display, ge, "'### Good Enough' has no '- [ ]' checkbox criteria — "
                 'downstream gates (criteria-coverage, VERIFY, the iterate judge) '
                 'read exactly this checkbox format')


TASK_HEADING = re.compile(r'^### (task-[A-Za-z0-9][A-Za-z0-9-]*)\b')


def lint_plan(display, data):
    lines, mask = markdown_scan(display, data, allow_frontmatter=False)
    if lines is None:
        return
    require_heading(display, lines, mask, '## Task DAG')
    require_heading(display, lines, mask, '## Tasks')

    vis = visible(lines, mask)
    if not any(re.match(r'^\|\s*task-', line.strip()) for _, line in vis):
        flag(display, 0, "'## Task DAG' table has no '| task-...' rows")

    # Collect task blocks: from each `### task-<id>` heading to the next ##/### heading.
    blocks = []
    seen = {}
    for idx, (no, line) in enumerate(vis):
        m = TASK_HEADING.match(line.strip())
        if not m:
            continue
        tid = m.group(1)
        if tid in seen:
            flag(display, no, 'duplicate task block id %s (first at line %d)' % (tid, seen[tid]))
        else:
            seen[tid] = no
        blocks.append((tid, no, idx))

    if not blocks:
        flag(display, 0, "no '### task-<id>:' blocks found under '## Tasks' — EXECUTE "
             'Step 2a parses these blocks; use the PLAN.md.template task shape')
        return

    for b, (tid, no, idx) in enumerate(blocks):
        end = len(vis)
        for j in range(idx + 1, len(vis)):
            s = vis[j][1].strip()
            if s.startswith('## ') or s.startswith('### '):
                end = j
                break
        block = vis[idx + 1:end]
        block_text = [line.strip() for _, line in block]

        def has_marker(marker):
            # Accept the colon-outside-the-bold variant too ('**Files**:'),
            # a common model rendering of the same marker.
            alt = marker[:-3] + '**:'
            return any(t.startswith(marker) or t.startswith(alt) for t in block_text)

        for marker in ('**Files:**', '**Verify:**', '**Acceptance criteria:**'):
            if not has_marker(marker):
                flag(display, no, "task block %s is missing '%s'" % (tid, marker))
        if has_marker('**Acceptance criteria:**'):
            in_ac = False
            ac_items = 0
            for t in block_text:
                if (t.startswith('**Acceptance criteria:**')
                        or t.startswith('**Acceptance criteria**:')):
                    in_ac = True
                    continue
                if in_ac:
                    if t.startswith('**'):
                        break
                    if t.startswith('- '):
                        ac_items += 1
            if ac_items == 0:
                flag(display, no, "task block %s has an '**Acceptance criteria:**' marker "
                     'but no criteria list items under it' % tid)


def lint_patterns(display, data):
    lines, mask = markdown_scan(display, data, allow_frontmatter=False)
    if lines is None:
        return
    if not any(line.strip().startswith('## ') for _, line in visible(lines, mask)):
        flag(display, 0, "no '## ' sections found — the planner reads '## Concept:' "
             'sections (or an explicit no-analog section) from PATTERNS.md')


def lint_verification(display, data):
    lines, mask = markdown_scan(display, data, allow_frontmatter=False)
    if lines is None:
        return
    require_heading(display, lines, mask, '## Repository grounding')
    ac = require_heading(display, lines, mask, '## Acceptance criteria')
    if ac is not None:
        has_row = False
        for no, line in visible(lines, mask):
            if no <= ac:
                continue
            s = line.strip()
            if s.startswith('## '):
                break
            if s.startswith('|'):
                has_row = True
                break
        if not has_row:
            flag(display, ac, "'## Acceptance criteria' has no table rows — the iterate "
                 'judge and regression-scan read this table')


def decode_json_source(display, data):
    """Decode a JSON artifact, flagging the two common model formatting failures
    (markdown code-fence wrap, UTF-8 BOM) with an exact repair instruction instead
    of surfacing a raw parse error the producer must reverse-engineer."""
    try:
        text = data.decode('utf-8')
    except UnicodeDecodeError as exc:
        flag(display, 0, 'not valid UTF-8: %s' % exc)
        return None
    if text.startswith('\ufeff'):
        flag(display, 1, 'file starts with a UTF-8 BOM — jq consumers reject it; '
             'write plain UTF-8 with no BOM')
        return None
    stripped = text.lstrip()
    if stripped.startswith('```'):
        line_no = text[:len(text) - len(stripped)].count('\n') + 1
        flag(display, line_no, 'JSON artifact is wrapped in a markdown code fence — '
             'write the raw JSON directly, no ``` fences')
        return None
    return text


def lint_tasks(display, data):
    text = decode_json_source(display, data)
    if text is None:
        return
    try:
        tasks = json.loads(text)
    except json.JSONDecodeError as exc:
        flag(display, 0, 'tasks artifact is not valid JSON: %s' % exc)
        return
    if not isinstance(tasks, list) or not tasks:
        flag(display, 0, 'tasks must be a non-empty JSON array (got %s)'
             % type(tasks).__name__)
        return
    ids = set()
    for i, t in enumerate(tasks):
        label = 'tasks[%d]' % i
        if not isinstance(t, dict):
            flag(display, 0, '%s is not an object' % label)
            continue
        tid = t.get('id')
        if not isinstance(tid, str) or not tid.strip():
            flag(display, 0, '%s.id must be a non-empty string' % label)
        else:
            label = tid
            if tid in ids:
                flag(display, 0, 'duplicate task id %s' % tid)
            ids.add(tid)
        brief = t.get('brief') or t.get('subject')
        if not isinstance(brief, str) or not brief.strip():
            flag(display, 0, '%s needs a non-empty brief or subject' % label)
        for field in ('files', 'blockedBy'):
            v = t.get(field)
            if not isinstance(v, list) or any(not isinstance(x, str) for x in v):
                flag(display, 0, '%s.%s must be an array of strings (missing counts as '
                     'malformed — write [])' % (label, field))
        vc = t.get('verifyCommand')
        if not isinstance(vc, str) or not vc.strip():
            flag(display, 0, '%s.verifyCommand must be a non-empty string — a task '
                 'without a mechanical done-condition cannot be dispatched' % label)
        ac = t.get('acceptanceCriteria')
        if (not isinstance(ac, list) or not ac
                or any(not isinstance(x, str) or not x.strip() for x in ac)):
            flag(display, 0, '%s.acceptanceCriteria must be a non-empty array of '
                 'non-empty strings' % label)
        rf = t.get('readFirst')
        if rf is not None and (not isinstance(rf, list)
                               or any(not isinstance(x, str) for x in rf)):
            flag(display, 0, '%s.readFirst must be an array of strings when present' % label)
        sp = t.get('specPath')
        if sp is not None and not isinstance(sp, str):
            flag(display, 0, '%s.specPath must be a string or null' % label)
    for i, t in enumerate(tasks):
        if not isinstance(t, dict):
            continue
        for dep in (t.get('blockedBy') or []):
            if isinstance(dep, str) and dep not in ids:
                flag(display, 0, '%s.blockedBy references unknown task id %r'
                     % (t.get('id') or 'tasks[%d]' % i, dep))


def lint_json(display, data):
    text = decode_json_source(display, data)
    if text is None:
        return
    try:
        json.loads(text)
    except json.JSONDecodeError as exc:
        flag(display, 0, 'not valid JSON: %s' % exc)


LINTERS = {
    'spec': lint_spec,
    'plan': lint_plan,
    'patterns': lint_patterns,
    'verification': lint_verification,
    'tasks': lint_tasks,
    'json': lint_json,
}

shown = []
for path in paths:
    display, data = read_artifact(path)
    shown.append(display)
    if data is not None:
        LINTERS[atype](display, data)

target = ', '.join(shown)
if flags:
    print('artifact-lint: %d flag(s) (%s: %s)' % (flags, atype, target))
    sys.exit(1)
print('artifact-lint: ok (%s: %s)' % (atype, target))
PY
