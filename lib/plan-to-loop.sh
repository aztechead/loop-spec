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

    # Engineering contract (canonical index: skills/shared/engineering-directives.md).
    # A SessionStart hook does not reach this loop-runner worker, so the prompt names the
    # contracts and the probes; the rules that must bind without a file read are inline.
    contract = (
        f'ENGINEERING CONTRACT (on by default; every directive binds). The index is '
        f'`{lib_dir}/../skills/shared/engineering-directives.md`. Read these before writing code, never paste them: '
        f'`{lib_dir}/../skills/shared/implementer-contract.md` (FOUR QUESTIONS (design gate): can I make it more modular? '
        f'more extensible? is this the least amount of code that makes it happen? '
        f'does this hold at production scale, memory and work bounded against deployment-sized '
        f'input, not the fixture?); `{lib_dir}/../skills/shared/laziness-ladder.md` (ponytail laziness ladder: YAGNI, then DRY, reuse '
        f'what is already here); `{lib_dir}/../skills/shared/design-for-change.md` (seams, not speculation); '
        f'`{lib_dir}/../skills/shared/human-code.md` (house style over habit: read the neighbors, comments carry WHY, '
        f'density matches the file, never cut `simplicity:` markers; CODE A HUMAN CAN OPERATE: fail '
        f'loudly, or say why not); `{lib_dir}/../skills/shared/human-docs.md` (DOCS FOR HUMANS: one job per document, '
        f'cite never copy, a document your change makes false is fixed IN THIS DIFF and never a '
        f'deferred follow-up; NEVER cut frontmatter, machine-read contract sections, artifact '
        f'headings, EVID lines, or licenses); `{lib_dir}/../skills/shared/writing-good-tests.md` (WRITING GOOD TESTS: '
        f'name the break; no string-presence traps; no change detectors).\n'
        f'\n'
        f'Rules that bind without a file read. TDD, red then green: code-producing tasks write the '
        f'failing test FIRST, run it, confirm red, implement, confirm green; skill/config/docs '
        f'tasks are excluded; Omitting a TDD label does not exempt this step. Simple over clever: '
        f'the construct the next reader decodes without a comment. Idiomatic for the version the '
        f'repo pins. Versions come from a tool (manifest, package manager, registry, advisory '
        f'check), never from recall; report `version: <name>@<v> source: <command>` or '
        f'`unverified`. Name the scaling input before writing code. Tests first; one test, one '
        f'break, smallest input.\n'
        f'\n'
        f'Before DONE, on <files you touched>: `bash {lib_dir}/indirection-scan.sh scan` (one-caller '
        f'helpers to inline); `bash {lib_dir}/duplication-scan.sh scan` (`duplicate=` same lines, '
        f'`similar=` names changed; both count); `bash {lib_dir}/house-style.sh compare`; '
        f'`bash {lib_dir}/comment-tells.sh scan`; `bash {lib_dir}/failure-tells.sh scan`; '
        f'`bash {lib_dir}/doc-tells.sh scan <markdown you touched>`.\n'
        f'\n'
        f'NO NESTED SUBAGENTS. Do this task yourself. Never dispatch a helper or a reviewer. '
        f'Review arrives from the lead after your report.\n'
        f'\n'
        f'EXECUTION DISCIPLINE (evidence over recall). Read `{lib_dir}/../skills/shared/execution-discipline.md`, do not '
        f'paste it. You execute a brief a stronger reasoning pass produced: fidelity, not '
        f'improvisation. Never assert what a file, command, or API does from memory; read it, run '
        f'it, paste the output. Output that contradicts your expectation is signal: stop, re-read, '
        f'revise. Re-read the acceptance criteria before DONE and check each against actual '
        f'output. Scope is closed: never skip, trim, or defer a criterion and never write '
        f'follow-up notes; a criterion you cannot meet is a loud failure with evidence. Leave '
        f'pre-existing bugs and unrelated behavior unchanged unless the requested behavior cannot '
        f'work without them; keep permanent tests to requested behavior or the repository\'s '
        f'convention; edit the needed lines instead of rewriting a file whose result is unchanged.'
    )

    lines = [f'You are implementing one task of feature \"{slug}\".', '', contract, '', f'TASK {raw}: {brief}', '']
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
