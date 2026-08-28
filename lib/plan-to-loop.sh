#!/usr/bin/env bash
# lib/plan-to-loop.sh — convert EXECUTE tasks[] JSON into a loop-runner plan.
#
# Usage:
#   plan-to-loop.sh --slug <slug> --spec <SPEC.md path> --plan <PLAN.md path> \
#                   [--max-iterations <n>] [--tasks-file <file>]
#
# Reads the EXECUTE tasks[] array (the Step 2a/2b shape: id, brief|subject,
# files[], blockedBy[], verifyCommand, acceptanceCriteria[], readFirst[],
# specPath) from --tasks-file or stdin. Emits a loop-runner plan
# (skills/loop-runner/scripts/planlib.py schema) on stdout.
#
# Contract:
#   - Every task MUST carry a non-empty verifyCommand; a task without a
#     done-condition cannot be looped safely. Exit 1 listing offenders.
#   - SPEC.md and PLAN.md are force-protected in every task so no worker can
#     edit the requirements to match its work (verifier integrity).
#   - blockedBy edges map to deps verbatim (explicit + synthetic edges).
#
# Exit codes: 0 ok, 1 invalid tasks input, 2 bad invocation.
set -euo pipefail

# The probes the code-for-humans directive names ship beside this script, and the
# loop-runner worker they are handed to runs with the target repository as its cwd.
# Resolving the absolute path here is what makes the directive executable there.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SLUG="" SPEC="" PLAN="" MAX_ITER="10" TASKS_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --slug)           SLUG="$2"; shift 2 ;;
    --spec)           SPEC="$2"; shift 2 ;;
    --plan)           PLAN="$2"; shift 2 ;;
    --max-iterations) MAX_ITER="$2"; shift 2 ;;
    --tasks-file)     TASKS_FILE="$2"; shift 2 ;;
    *) echo "plan-to-loop: unknown arg '$1'" >&2; exit 2 ;;
  esac
done

if [[ -z "$SLUG" || -z "$SPEC" || -z "$PLAN" ]]; then
  echo "usage: plan-to-loop.sh --slug <slug> --spec <path> --plan <path> [...]" >&2
  exit 2
fi

if [[ -n "$TASKS_FILE" ]]; then
  TASKS_JSON=$(cat "$TASKS_FILE")
else
  TASKS_JSON=$(cat)
fi

printf '%s' "$TASKS_JSON" | python3 -c "
import json, re, sys

slug, spec, plan, max_iter, lib_dir = sys.argv[1:6]

try:
    tasks = json.load(sys.stdin)
except Exception as e:
    print(f'plan-to-loop: invalid tasks JSON: {e}', file=sys.stderr)
    sys.exit(1)

if not isinstance(tasks, list) or not tasks:
    print('plan-to-loop: tasks[] is empty or not a list', file=sys.stderr)
    sys.exit(1)

ID_RE = re.compile(r'^[a-z0-9][a-z0-9-]{1,63}$')

# Global constraints travel VERBATIM into every worker prompt (a loop-runner worker
# sees only its prompt, never the plan). Absent section or '- none' => no block.
def read_global_constraints(plan_path):
    try:
        with open(plan_path, errors='replace') as f:
            lines = f.read().splitlines()
    except OSError:
        return []
    block, in_section = [], False
    for line in lines:
        if re.match(r'^##\s+Global constraints\s*$', line):
            in_section = True
            continue
        if in_section:
            if re.match(r'^#{1,6}\s', line):
                break
            s = line.strip()
            if s and not s.startswith('<!--') and s != '- none':
                block.append(s)
    return block

global_constraints = read_global_constraints(plan)

def norm_id(raw):
    s = re.sub(r'[^a-z0-9-]+', '-', str(raw).lower()).strip('-')
    return s[:64]

errs, out_tasks = [], []
id_map = {}
for t in tasks:
    raw = t.get('id') or ''
    nid = norm_id(raw)
    if not nid or not ID_RE.match(nid):
        errs.append(f'task id {raw!r} cannot be normalized to a loop id')
        continue
    id_map[raw] = nid

for t in tasks:
    raw = t.get('id') or ''
    nid = id_map.get(raw)
    if nid is None:
        continue
    verify = (t.get('verifyCommand') or '').strip()
    if not verify:
        errs.append(f'{raw}: missing verifyCommand — every task needs a mechanical done-condition')
        continue

    brief = t.get('brief') or t.get('subject') or raw
    criteria = t.get('acceptanceCriteria') or []
    files = t.get('files') or []
    read_first = t.get('readFirst') or []
    spec_path = t.get('specPath')

    # Design gate (canonical: skills/shared/implementer-contract.md). A SessionStart
    # hook does not reach this loop-runner worker, so the prompt names the contract and the
    # probes rather than pasting the essay.
    three_questions = (
        'THREE QUESTIONS (design gate — on by default). Before implementing and again '
        'before DONE, ask of the change: can I make it more modular? can I make it more '
        'extensible? is this the least amount of code that makes it happen? Full contract: '
        f'{lib_dir}/../skills/shared/implementer-contract.md.'
    )

    ladder = (
        'SIMPLICITY (ponytail laziness ladder — on by default). Read '
        f'{lib_dir}/../skills/shared/laziness-ladder.md before writing code — do not paste '
        'it. YAGNI, then DRY: reuse what is already here. Before DONE run bash '
        f'{lib_dir}/indirection-scan.sh scan <files you touched> and bash '
        f'{lib_dir}/duplication-scan.sh scan <files you touched> '
        '(duplicate= same lines, similar= names-changed; both count).'
    )

    # Design-for-change directive (canonical: skills/shared/design-for-change.md).
    # Travels with the ladder: the loop-runner worker sees only its prompt.
    design = (
        'DESIGN FOR CHANGE (seams, not speculation — on by default). Read '
        f'{lib_dir}/../skills/shared/design-for-change.md — do not paste it. Design to an '
        'interface; one unit, one reason to change; receive collaborators.'
    )

    # Code-for-humans directive (canonical: skills/shared/human-code.md).
    # Travels with the ladder: the loop-runner worker sees only its prompt.
    human = (
        'CODE FOR HUMANS (house style over habit — on by default). Read '
        f'{lib_dir}/../skills/shared/human-code.md before writing code — do not paste it. '
        'Read the neighbors. Comments carry WHY, never what. NEVER cut simplicity: markers. '
        f'Before DONE run bash {lib_dir}/house-style.sh probe <files>; bash '
        f'{lib_dir}/house-style.sh compare <files you touched>; bash '
        f'{lib_dir}/comment-tells.sh scan <files>; bash {lib_dir}/failure-tells.sh scan '
        '<files you touched>. CODE A HUMAN CAN OPERATE: fail loudly, or say why you did not.'
    )

    # Docs-for-humans directive (canonical: skills/shared/human-docs.md).
    # Travels with the ladder: the loop-runner worker sees only its prompt.
    docs = (
        'DOCS FOR HUMANS (the markdown is a deliverable too — on by default). Read '
        f'{lib_dir}/../skills/shared/human-docs.md — do not paste it. One job per document. '
        'Cite, never copy. If your change makes a document false, fix it IN THIS DIFF; a '
        'follow-up documentation task is deferred scope. Before DONE run bash '
        f'{lib_dir}/doc-tells.sh scan <the markdown you touched>. NEVER cut frontmatter, '
        'machine-read contract sections, required artifact headings, EVID citation lines, '
        'or license blocks.'
    )

    tests_catalog = (
        'WRITING GOOD TESTS. Read '
        f'{lib_dir}/../skills/shared/writing-good-tests.md before adding or changing a '
        'test — do not paste it. Name the break; no string-presence traps; no change '
        'detectors. TDD: code-producing tasks write the failing test FIRST, confirm '
        'red, then implement, confirm green. Skill/config/docs tasks are excluded. '
        'Omitting a TDD label does not exempt this step.'
    )

    no_nested = (
        'NO NESTED SUBAGENTS. Do this task yourself. Never dispatch a helper or a '
        'reviewer. Review arrives from the lead after your report.'
    )

    # Execution-discipline directive (canonical: skills/shared/execution-discipline.md).
    # Travels with the ladder: the loop-runner worker sees only its prompt.
    discipline = (
        'EXECUTION DISCIPLINE (evidence over recall — on by default). You execute a brief a '
        'stronger reasoning pass produced; your job is fidelity, not improvisation. Verify, '
        'do not recall: never assert what a file/command does from memory — read it, run it, '
        'paste the actual output. Surprise is signal: output contradicting expectation means '
        'stop and revise, never explain away. Re-read the acceptance criteria before DONE and '
        'check each against actual output. \"Should work\" / \"probably fine\" / \"tests likely '
        'pass\" each mean run it now. Scope is closed: the acceptance criteria are the whole '
        'job — never skip, trim, or defer an item, and never write follow-up/deferred/'
        'future-work notes; a criterion you cannot meet is a loud failure with evidence, '
        'never a note.'
    )
    lines = [f'You are implementing one task of feature \"{slug}\".', '', three_questions, '', ladder, '', design, '', human, '', docs, '', tests_catalog, '', no_nested, '', discipline, '', f'TASK {raw}: {brief}', '']
    if global_constraints:
        lines.append('Global constraints (from the plan, verbatim; every one binds):')
        lines += [f'{c}' for c in global_constraints]
        lines.append('')
    if criteria:
        lines.append('Acceptance criteria (ALL must hold; the verify command is the contract):')
        lines += [f'- {c}' for c in criteria]
        lines.append('')
    if read_first:
        lines.append('Read these files FIRST before changing anything:')
        lines += [f'- {p}' for p in read_first]
        lines.append('')
    if files:
        lines.append('Modify ONLY these files (plus new test files your verify command runs):')
        lines += [f'- {p}' for p in files]
        lines.append('')
    lines.append(f'The authoritative spec is {spec_path or spec}. Follow it exactly; '
                 f'if the spec and this brief conflict, the spec wins.')
    lines.append(f'Do NOT modify {spec}, {plan}, or the verify command targets — '
                 f'they are integrity-protected and touching them halts the run.')
    lines.append('Do not touch unrelated files. Commit-worthy work only.')

    protected = [spec, plan]
    if spec_path:
        protected.append(spec_path)

    out_tasks.append({
        'id': nid,
        'prompt': '\n'.join(lines),
        'verify': verify,
        'protected': protected,
        'max_iterations': int(max_iter),
        'deps': [id_map[d] for d in (t.get('blockedBy') or []) if d in id_map],
        'mode': 'fresh',
    })

if errs:
    print('plan-to-loop: tasks rejected:', file=sys.stderr)
    for e in errs:
        print(f'  - {e}', file=sys.stderr)
    sys.exit(1)

json.dump({
    'spec': spec,
    'tasks': out_tasks,
}, sys.stdout, indent=2)
print()
" "$SLUG" "$SPEC" "$PLAN" "$MAX_ITER" "$LIB_DIR"
