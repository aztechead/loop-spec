#!/usr/bin/env bash
# lib/plan-to-loop.sh — convert EXECUTE tasks[] JSON into a loop-runner plan.
#
# Usage:
#   plan-to-loop.sh --slug <slug> --spec <SPEC.md path> --plan <PLAN.md path> \
#                   [--fleet-budget <usd>] [--task-budget <usd>] \
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

SLUG="" SPEC="" PLAN="" FLEET_BUDGET="20" TASK_BUDGET="4" MAX_ITER="10" TASKS_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --slug)           SLUG="$2"; shift 2 ;;
    --spec)           SPEC="$2"; shift 2 ;;
    --plan)           PLAN="$2"; shift 2 ;;
    --fleet-budget)   FLEET_BUDGET="$2"; shift 2 ;;
    --task-budget)    TASK_BUDGET="$2"; shift 2 ;;
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

slug, spec, plan, fleet_budget, task_budget, max_iter = sys.argv[1:7]

try:
    tasks = json.load(sys.stdin)
except Exception as e:
    print(f'plan-to-loop: invalid tasks JSON: {e}', file=sys.stderr)
    sys.exit(1)

if not isinstance(tasks, list) or not tasks:
    print('plan-to-loop: tasks[] is empty or not a list', file=sys.stderr)
    sys.exit(1)

ID_RE = re.compile(r'^[a-z0-9][a-z0-9-]{1,63}$')

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

    # Ponytail laziness ladder (canonical: skills/shared/laziness-ladder.md). A SessionStart
    # hook does not reach this loop-runner worker, so the directive is inlined here so the
    # simplicity discipline applies on the loop-fleet rung every time, like the other rungs.
    ladder = (
        'SIMPLICITY (ponytail laziness ladder — on by default). Write the shortest solution '
        'that actually works; the best code is the code never written. BEFORE writing code, '
        'stop at the first rung that holds: (1) does it need to exist at all? speculative = '
        'skip it (YAGNI); (2) already in this codebase? reuse the existing helper/util/type/'
        'pattern, do not re-implement it; (3) stdlib does it? use it; (4) native platform '
        'feature covers it? use it; (5) an already-installed dependency solves it? use it, '
        'never add a new one for what a few lines do; (6) can it be one line? one line; '
        '(7) only then, the minimum code that works. The ladder runs AFTER you understand '
        'the problem. Bug fix = root cause, not symptom. NEVER cut input validation at trust '
        'boundaries, error handling that prevents data loss, security, accessibility, or '
        'anything the spec requires. Non-trivial logic leaves ONE runnable check behind. '
        'Mark deliberate shortcuts with a simplicity: comment.'
    )
    lines = [f'You are implementing one task of feature \"{slug}\".', '', ladder, '', f'TASK {raw}: {brief}', '']
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
        'budget_usd': float(task_budget),
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
    'fleet_budget_usd': float(fleet_budget),
    'tasks': out_tasks,
}, sys.stdout, indent=2)
print()
" "$SLUG" "$SPEC" "$PLAN" "$FLEET_BUDGET" "$TASK_BUDGET" "$MAX_ITER"
