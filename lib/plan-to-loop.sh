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

    # Ponytail laziness ladder (canonical: skills/shared/laziness-ladder.md). A SessionStart
    # hook does not reach this loop-runner worker, so the directive is inlined here so the
    # simplicity discipline applies on the loop-fleet rung every time, like the other rungs.
    ladder = (
        'SIMPLICITY (ponytail laziness ladder — on by default). Write the shortest solution '
        'that actually works; the best code is the code never written. BEFORE writing code, '
        'stop at the first rung that holds: (1) does it need to exist at all? speculative = '
        'skip it (YAGNI); (2) DRY — already in this codebase? reuse the existing helper/util/'
        'type/pattern, do not re-implement it; (3) stdlib does it? use it; (4) native platform '
        'feature covers it? use it; (5) an already-installed dependency solves it? use it, '
        'never add a new one for what a few lines do; (6) can it be one line? one line; '
        '(7) only then, the minimum code that works. The ladder runs AFTER you understand '
        'the problem. Bug fix = root cause, not symptom. NEVER cut input validation at trust '
        'boundaries, error handling that prevents data loss, security, accessibility, or '
        'anything the spec requires. Non-trivial logic leaves ONE runnable check behind. '
        'Mark deliberate shortcuts with a simplicity: comment. '
        'Rung 1 is measured too: before DONE run bash '
        f'{lib_dir}/indirection-scan.sh scan <files you touched> — it names each small '
        'private helper you added that is called exactly once; inline it or say why the '
        'name earns its hop. It stays silent on long single-caller functions '
        '(decomposition), exported symbols, and dead code. '
        'Rung 2 is measured, not recalled — you cannot find a helper in a file you never '
        f'opened, so before DONE run bash {lib_dir}/duplication-scan.sh scan <files you '
        'touched>. It names each block you duplicated and the file that block already lives '
        'in: duplicate= is the same lines, similar= is the same lines with every name '
        'changed, which is what writing one module beside a similar one produces, so both '
        'count. Resolve every finding: call the existing thing, or lift the shared part into one '
        'place both callers use, never a second copy that drifts. A coincidental resemblance '
        '(two blocks that change for different reasons) is the one exception — report it '
        'rather than merging them, because that merge is a coupling bug.'
    )

    # Design-for-change directive (canonical: skills/shared/design-for-change.md).
    # Travels with the ladder: the loop-runner worker sees only its prompt.
    design = (
        'DESIGN FOR CHANGE (seams, not speculation — on by default). Design to the task\'s '
        'stated interface, not an implementation detail; one unit, one reason to change. '
        'New units receive their collaborators (params/args/env), never construct them deep '
        'inside. Never cut a seam to save lines, and never build speculation behind one '
        '(YAGNI cuts artifacts, not seams). Bug-fix tasks: after the root cause is fixed, '
        'sweep callers, copy-pasted patterns, and parallel paths for the same mechanism; '
        'fix same-cause siblings within the task files scope, report the rest.'
    )

    # Code-for-humans directive (canonical: skills/shared/human-code.md).
    # Travels with the ladder: the loop-runner worker sees only its prompt.
    human = (
        'CODE FOR HUMANS (house style over habit — on by default). Code is read far more '
        'than it is written; your diff must read like the code around it. Read the '
        'neighbors of every file in the task files list FIRST and match them: naming, '
        'error idiom, test structure, layout, import order. The house convention outranks '
        'your defaults even where you would have chosen differently — disagreeing with it '
        'is a self-review finding, never a licence to deviate. Where the convention is '
        f'unclear, measure it: run bash {lib_dir}/house-style.sh probe <files> for comment '
        'density, doc-comment usage, indentation, and naming case from the actual '
        'neighbors, and before DONE run bash '
        f'{lib_dir}/house-style.sh compare <files you touched> to see where your own work '
        'deviates from its same-language neighbors (indent, naming, quotes, semicolons, '
        'module system); probe pools your file into the sample and so can never show you a '
        'deviation. Comments carry WHY, never what: a constraint not visible locally, a '
        'decision and the alternative it beat, a workaround and its reason. Never narrate '
        'the code, announce the edit ("Added...", "Updated..."), or narrate history '
        f'("previously..."); bash {lib_dir}/comment-tells.sh scan <files> catches those three. '
        'Comment density matches the file, not an absolute. A good name deletes a comment. '
        'No drive-by reformatting or renames that bury the change. NEVER cut simplicity: '
        'markers, file-header purpose blocks the codebase uses, TODO/FIXME/NOTE/HACK/'
        'SAFETY markers, or any comment encoding a non-obvious why.'
    )

    # Docs-for-humans directive (canonical: skills/shared/human-docs.md).
    # Travels with the ladder: the loop-runner worker sees only its prompt.
    docs = (
        'DOCS FOR HUMANS (the markdown is a deliverable too — on by default). A person '
        'maintains and operates every document you write, long after this run ends. Name '
        'its reader in the first line — someone about to CHANGE this system, or someone '
        'about to RUN it — and hold one job per document: a how-to gets a task done, a '
        'reference states facts, an explanation says why. A procedure states its '
        'prerequisites, then the exact copy-pasteable command, then what success looks '
        'like, then what to do when the step fails. Cite, never copy: point at file:line '
        'instead of restating what the code says — stale prose is worse than none, because '
        'it is wrong with authority. If your change makes a document false (README, help '
        'text, runbook, config table), fix it IN THIS DIFF; a follow-up documentation task '
        'is deferred scope. Never invent a documentation convention this repository does '
        f'not already have. Before DONE run bash {lib_dir}/doc-tells.sh scan <the markdown '
        'you touched>: it flags a relative link with no target, an inline-code path the '
        'tree no longer holds, and a command holding a placeholder your prose never '
        'explains. NEVER cut frontmatter, machine-read contract sections, required artifact '
        'headings, EVID citation lines, or license blocks.'
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
    lines = [f'You are implementing one task of feature \"{slug}\".', '', ladder, '', design, '', human, '', docs, '', discipline, '', f'TASK {raw}: {brief}', '']
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
