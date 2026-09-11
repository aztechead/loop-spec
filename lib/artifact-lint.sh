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
#   artifact-lint.sh spec         <SPEC.md path | -> [--feature-dir DIR]
#   artifact-lint.sh plan         <PLAN.md path | -> [--feature-dir DIR]
#   artifact-lint.sh patterns     <PATTERNS.md path | ->
#   artifact-lint.sh verification <VERIFICATION.md path | ->
#   artifact-lint.sh tasks        <tasks JSON path | -> [--feature-dir DIR]
#   artifact-lint.sh json         <path> [<path>...]
#
# --feature-dir selects the requirements contract (feature.json's
# requirementsContract.format): under "v1" every PLAN task block and tasks[] entry
# must carry a Requirements or Obligations reference (structural shape only --
# whether the reference resolves against the live SPEC inventory is
# lib/criteria-coverage.sh's job, run from lib/plan-exit-gate.sh). Without it, or
# under "legacy", those fields are optional and only checked when present.
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
  spec|plan|tasks) [[ $# -eq 2 || ( $# -eq 4 && "$3" == "--feature-dir" ) ]] || { echo "usage: artifact-lint.sh $type <path|-> [--feature-dir DIR]" >&2; exit 2; } ;;
  patterns|verification) [[ $# -eq 2 ]] || { echo "usage: artifact-lint.sh $type <path|->" >&2; exit 2; } ;;
  json) [[ $# -ge 2 ]] || { echo "usage: artifact-lint.sh json <path> [<path>...]" >&2; exit 2; } ;;
  *) echo "usage: artifact-lint.sh <spec|plan|patterns|verification|tasks|json> <path> [...]" >&2; exit 2 ;;
esac
shift
feature_dir=""
if [[ ( "$type" == spec || "$type" == plan || "$type" == tasks ) && $# -eq 3 ]]; then
  feature_dir="$3"
  set -- "$1"
fi

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

PYTHONPATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)${PYTHONPATH:+:$PYTHONPATH}" python3 - "$type" "$feature_dir" "${args[@]}" <<'PY'
import json
import re
import sys

atype = sys.argv[1]
feature_dir = sys.argv[2]
paths = sys.argv[3:]

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
        with open(path, 'rb') as stream:
            if atype == 'spec':
                from requirements import MAX_BYTES
                data = stream.read(MAX_BYTES + 1)
                if len(data) > MAX_BYTES:
                    flag(display, 1, 'SPEC exceeds 16 MiB')
                    return display, None
            else:
                data = stream.read()
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
    '- Architecture: {components and their owners}',
    '- Component structure: {modules and the boundary between them}',
    '- Data flows: {each flow end to end, who owns each piece of state}',
    '- API design: {endpoints or commands, request and response shapes}',
    '- Database schema: {entities, keys, indexes}',
    '- Interface architecture: {what the user meets and how it talks to the API}',
    '- Caching strategy: {what is cached, where, and how it is invalidated}',
    '- Scale bound: {the input that grows and the bound held against it}',
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


FROZEN_OPEN = re.compile(r'^<!--\s*intent:\s*frozen\b')
FROZEN_CLOSE = '<!-- /intent -->'


def require_frozen_intent(display, lines, mask, intent_no):
    """The oneshot shape keeps the ask inside a frozen block: the comment line above
    '## Intent' opens it and `<!-- /intent -->` closes it before the next section, so
    ONESHOT's exit can prove the block never changed after SPEC committed it."""
    above = [line.strip() for no, line in visible(lines, mask) if no < intent_no and line.strip()]
    if not above or not FROZEN_OPEN.match(above[-1]):
        flag(display, intent_no, "'## Intent' has no `<!-- intent: frozen ... -->` line above it "
             '(the oneshot shape keeps the ask in a frozen block: SPEC-oneshot.md.template)')
    for no, line in visible(lines, mask):
        if no <= intent_no:
            continue
        s = line.strip()
        if s == FROZEN_CLOSE:
            return
        if s.startswith('## '):
            break
    flag(display, intent_no, "'## Intent' block is not closed with `<!-- /intent -->` before the next section")


def lint_spec(display, data):
    from requirements import parse_spec
    try:
        contract = None
        if feature_dir:
            from feature_read import load_state
            contract = load_state(feature_dir).get("requirementsContract")
        parse_spec(data.decode("utf-8"), display, contract)
    except (OSError, ValueError) as exc:
        flag(display, 1, str(exc))
    from spec_questions import read_questions
    try:
        questions = read_questions(data.decode("utf-8"))
        if questions:
            flag(display, 0, "unresolved intent questions: " + "; ".join(questions))
    except (ValueError, UnicodeDecodeError) as exc:
        flag(display, 0, str(exc))
    if feature_dir:
        from feature_read import load_state
        from spec_intent import verify_intent
        try:
            feature = load_state(feature_dir)
            text = data.decode("utf-8")
            if (feature.get("specApproval") or re.search(r"^route: *full\s*$", text, re.M)
                    or not re.search(r"^## Intent$", text, re.M)):
                verify_intent(text, feature.get("specApproval"))
        except (OSError, ValueError) as exc:
            flag(display, 0, str(exc))
    lines, mask = markdown_scan(display, data, allow_frontmatter=True)
    if lines is None:
        return
    # Two shapes share the criteria and grounding sections: the full SPEC opens with
    # '## Problem'; the oneshot SPEC opens with the ask in a frozen '## Intent' block
    # and says what changes per footprint file (skills/shared/artifact-templates/).
    intent = next((no for no, line in visible(lines, mask) if line.strip() == '## Intent'), None)
    if intent is not None:
        require_frozen_intent(display, lines, mask, intent)
        require_heading(display, lines, mask, '## Implementation notes')
    elif not any(line.strip() == '## Problem' or line.strip().startswith('## Problem ')
                 for _, line in visible(lines, mask)):
        flag(display, 0, "missing required section heading '## Problem' (the full shape) "
             "or a frozen '## Intent' block (the oneshot shape, SPEC-oneshot.md.template)")
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
GE_ID = re.compile(r'GE-[0-9]{3,}')
SC_ID = re.compile(r'SC-[0-9]{3,}')
OBL_ID = re.compile(r'OBL-[A-Za-z0-9][A-Za-z0-9-]*')
SHA256 = re.compile(r'[0-9a-f]{64}')
EXECUTION_INPUTS_KEYS = {'version', 'toolchains', 'localInputs', 'externalInputs', 'sensitiveInputs'}
EXECUTION_INPUTS_OPTIONAL = {'preparationReceipt'}


def contract_format():
    """'v1' or 'legacy' by feature.json's requirementsContract, 'legacy' when the
    feature carries none yet (the ordinary case until task-009 activation)."""
    if not feature_dir:
        return 'legacy'
    from feature_read import load_state
    return (load_state(feature_dir).get('requirementsContract') or {}).get('format', 'legacy')


def items_under(block_text, marker):
    """Bullet items ('- ...') between `marker` and the next '**...**' marker line."""
    items = []
    in_section = False
    for t in block_text:
        if t.startswith(marker) or t.startswith(marker[:-3] + '**:'):
            in_section = True
            continue
        if in_section:
            if t.startswith('**'):
                break
            if t.startswith('- '):
                items.append(t[2:].strip())
    return items


# The three checkers below take an already-parsed Python value and return error
# strings (never print) so lint_plan (parses a JSON bullet/line first) and lint_tasks
# (already holds parsed JSON) share one shape check instead of two.

def requirement_ref_errors(obj):
    required = {'owner', 'requirement', 'revision', 'scenarios'}
    if not isinstance(obj, dict) or set(obj) != required:
        got = ', '.join(sorted(obj)) if isinstance(obj, dict) else type(obj).__name__
        return ['needs exactly owner, requirement, revision, scenarios (got %s)' % got]
    errors = []
    owner = obj['owner']
    if (not isinstance(owner, dict) or set(owner) != {'repository', 'feature'}
            or any(not isinstance(v, str) or not v.strip() for v in owner.values())):
        errors.append('owner needs non-empty repository and feature')
    if not isinstance(obj['requirement'], str) or not GE_ID.fullmatch(obj['requirement']):
        errors.append('requirement must be a canonical GE-NNN id')
    if not isinstance(obj['revision'], str) or not SHA256.fullmatch(obj['revision']):
        errors.append('revision must be a lowercase SHA-256')
    if (not isinstance(obj['scenarios'], list) or not obj['scenarios']
            or any(not isinstance(s, str) or not SC_ID.fullmatch(s) for s in obj['scenarios'])):
        errors.append('scenarios must be a non-empty array of canonical SC-NNN ids')
    return errors


def obligation_id_errors(item):
    if not isinstance(item, str) or not OBL_ID.fullmatch(item):
        return ["must be a bare OBL-... id declared under SPEC '## Constraints' (got %r)" % (item,)]
    return []


def execution_inputs_errors(obj):
    if not isinstance(obj, dict) or not EXECUTION_INPUTS_KEYS <= set(obj) or not set(obj) <= (EXECUTION_INPUTS_KEYS | EXECUTION_INPUTS_OPTIONAL):
        got = ', '.join(sorted(obj)) if isinstance(obj, dict) else type(obj).__name__
        return ['needs version, toolchains, localInputs, externalInputs, sensitiveInputs '
                'and only the optional preparationReceipt (got %s)' % got]
    errors = []
    if obj.get('version') != 1:
        errors.append('version must be 1')
    for key in ('toolchains', 'localInputs', 'externalInputs', 'sensitiveInputs'):
        if not isinstance(obj[key], list):
            errors.append('%s must be an array' % key)
    return errors


def lint_requirement_bullet(display, no, tid, item):
    try:
        obj = json.loads(item)
    except ValueError as exc:
        flag(display, no, '%s Requirements bullet is not single-line JSON: %s' % (tid, exc))
        return
    for message in requirement_ref_errors(obj):
        flag(display, no, '%s Requirements bullet %s' % (tid, message))


def lint_obligation_bullet(display, no, tid, item):
    for message in obligation_id_errors(item):
        flag(display, no, '%s Obligations bullet %s' % (tid, message))


def lint_execution_inputs(display, no, tid, value):
    try:
        obj = json.loads(value)
    except ValueError as exc:
        flag(display, no, '%s Execution inputs value is not single-line JSON: %s' % (tid, exc))
        return
    for message in execution_inputs_errors(obj):
        flag(display, no, '%s Execution inputs %s' % (tid, message))


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

        # Requirements/Obligations/Execution inputs: structural shape only -- whether a
        # reference resolves against the live SPEC inventory is criteria-coverage.sh's
        # relation check, run from plan-exit-gate.sh with the feature's contract.
        requirements = items_under(block_text, '**Requirements:**')
        obligations = items_under(block_text, '**Obligations:**')
        for item in requirements:
            lint_requirement_bullet(display, no, tid, item)
        for item in obligations:
            lint_obligation_bullet(display, no, tid, item)
        exec_inputs_line = next((t for t in block_text if t.startswith('**Execution inputs:**')), None)
        if exec_inputs_line is not None:
            lint_execution_inputs(display, no, tid, exec_inputs_line[len('**Execution inputs:**'):].strip())
        if contract_format() == 'v1':
            if not requirements and not obligations:
                flag(display, no, "%s carries no '**Requirements:**' or '**Obligations:**' "
                     'bullet -- a v1 cycle has no free-text coverage exemption' % tid)
            if exec_inputs_line is None:
                flag(display, no, "%s is missing '**Execution inputs:**'" % tid)


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
                # An empty Status cell is a criterion nobody ran: the oneshot skeleton
                # leaves it empty until `cycle-driver.sh verification run` observes the
                # command's exit (port audit 4, item 2).
                cells = [c.strip() for c in re.split(r'(?<!\\)\|', s)[1:-1]]
                if len(cells) >= 3 and cells[0] not in ('#', '') and not set(cells[0]) <= set('-') and cells[2] == '':
                    flag(display, no, "acceptance row %s has an empty Status cell — the driver's "
                         "`verification run` fills it from the command's exit; nobody writes a status by hand" % cells[0])
        if not has_row:
            flag(display, ac, "'## Acceptance criteria' has no table rows — the iterate "
                 'judge and regression-scan read this table')
    # An empty fenced block is a value nobody wrote: the bug-fix run at d17da82 shipped
    # an empty Final test suite fence and nothing said so (port audit 4, item 4).
    open_at = None
    for i, line in enumerate(lines):
        if line.strip().startswith('```'):
            if open_at is None:
                open_at = i
            else:
                if all(not l.strip() for l in lines[open_at + 1:i]):
                    flag(display, open_at + 1, 'empty fenced block — the block holds a command output '
                         "the driver's `verification run` writes; an empty one is a value nobody observed")
                open_at = None


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
        st = t.get('status')
        if st is not None and st not in ('pending', 'done'):
            flag(display, 0, '%s.status must be pending or done when present' % label)
        bg = t.get('batchGroup')
        if bg is not None and (not isinstance(bg, str) or not bg.strip()):
            flag(display, 0, '%s.batchGroup must be a non-empty string when present' % label)
        mt = t.get('modelTier')
        if mt is not None and mt not in ('mechanical', 'standard', 'frontier'):
            flag(display, 0, '%s.modelTier must be mechanical, standard, or frontier when present' % label)
        iface = t.get('interfaces')
        if iface is not None:
            if not isinstance(iface, dict):
                flag(display, 0, '%s.interfaces must be an object when present' % label)
            else:
                for key in ('consumes', 'produces'):
                    if key not in iface:
                        continue
                    item = iface[key]
                    if isinstance(item, str):
                        continue
                    if isinstance(item, list) and all(isinstance(x, str) for x in item):
                        continue
                    flag(display, 0, '%s.interfaces.%s must be a string or array of strings'
                         % (label, key))
        def flag_array_field(field, error_fn):
            value = t.get(field)
            if value is None:
                return value
            if not isinstance(value, list):
                flag(display, 0, '%s.%s must be an array when present' % (label, field))
            else:
                for entry in value:
                    for message in error_fn(entry):
                        flag(display, 0, '%s.%s %s' % (label, field, message))
            return value

        requirements = flag_array_field('requirements', requirement_ref_errors)
        obligations = flag_array_field('obligations', obligation_id_errors)
        execution_inputs = t.get('executionInputs')
        if execution_inputs is not None:
            for message in execution_inputs_errors(execution_inputs):
                flag(display, 0, '%s.executionInputs %s' % (label, message))
        if contract_format() == 'v1':
            if not requirements and not obligations:
                flag(display, 0, "%s carries no requirements or obligations -- a v1 cycle "
                     'has no free-text coverage exemption' % label)
            if execution_inputs is None:
                flag(display, 0, '%s.executionInputs is required under a v1 contract' % label)
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
