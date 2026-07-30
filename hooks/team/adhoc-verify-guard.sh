#!/usr/bin/env bash
# Stop hook: evidence-before-done for ad-hoc (micro-cycle) work.
#
# Claude Code contract:
#   exit 0  = allow
#   exit 2  = block (with stderr message shown to user)
#
# The enforcement half of micro mode (skills/micro/SKILL.md invariant 5): a session
# that edited files must have completed a post-change grounding review AND run a
# verification command AFTER the last edit before it is allowed to stop. One python
# pass over the Stop payload does all the work: Write/Edit/NotebookEdit mark edits; a
# content review (`git diff` or `git show`, never a `--stat`/`-s` summary) grounds every
# path its pathspec covers, and an exact Read grounds that one path -- either form
# grounds a given file, and at least one content review must follow the final edit; a
# Bash command matching the verification pattern or the project's declared VERIFY_CMD
# marks validation.
#
# Stands down (exit 0) when:
#   - LOOP_SPEC_MICRO_GUARD=0 (kill switch), or micro.conf pins ENABLED=0
#   - the project has no .loop-spec/ dir (never hijack unrelated projects)
#   - a cycle feature is in flight in this checkout or a registered linked worktree
#     (logical completion comes from delivery.json.nextPhase=completed), or this
#     transcript invoked a full cycle whose terminal result was written after its
#     final edit. The cycle's VERIFY phase owns evidence at feature scale, and
#     blocking between phases or immediately after completion would fight the
#     orchestrator. A later ad-hoc edit re-arms this guard.
#     Trade-off: a paused feature also disarms the guard; guards here are
#     accelerators, never blockers, so we err on allow.
#   - no edits in the transcript, or every edited path is gone from disk by Stop time
#     (a deleted path can be neither re-read nor diffed, so requiring evidence for it
#     would strand the session with no way to satisfy the gate)
#
# Fail-open: missing/malformed payload, no python3, empty transcript -> exit 0.
#
# Environment variables (all optional):
#   LOOP_SPEC_MICRO_GUARD        Set to "0" to disable. Default: 1 (active).
#   LOOP_SPEC_MICRO_GUARD_TRACE_LOG  Path for trace log.
#                                Default: /tmp/claude-hooks/loop-spec-micro-guard-trace.log
#
# micro.conf keys (beyond ENABLED):
#   VERIFY_CMD=<command>         The project's real verification command when its
#                                runner is not in the built-in pattern (e.g.
#                                VERIFY_CMD=rake spec). A Bash command containing
#                                this string counts as evidence.
set -euo pipefail

# Kill switch.
if [[ "${LOOP_SPEC_MICRO_GUARD:-1}" == "0" ]]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTIVE_CYCLE_BIN="${LOOP_SPEC_ACTIVE_CYCLE_BIN:-$SCRIPT_DIR/../../lib/active-cycle.sh}"
CYCLE_RESULT_BIN="${LOOP_SPEC_CYCLE_RESULT_BIN:-$SCRIPT_DIR/../../lib/cycle-result.sh}"

# Scope: only active in projects that use loop-spec.
if [[ ! -d "${PROJECT_DIR}/.loop-spec" && ! -d "$PWD/.loop-spec" ]]; then
  exit 0
fi
[[ -d "${PROJECT_DIR}/.loop-spec" ]] || PROJECT_DIR="$PWD"

# Fail-open: any unexpected error must not block the session.
trap 'exit 0' ERR

# Micro mode off (conf ENABLED=0) disarms the guard with it.
CONF_FILE="${PROJECT_DIR}/.loop-spec/micro.conf"
if [[ -f "$CONF_FILE" ]] && grep -q "ENABLED=0" "$CONF_FILE" 2>/dev/null; then
  exit 0
fi

# Project-declared verification command (optional micro.conf key).
PROJ_VERIFY_CMD=""
if [[ -f "$CONF_FILE" ]]; then
  PROJ_VERIFY_CMD="$(grep -m1 '^VERIFY_CMD=' "$CONF_FILE" 2>/dev/null | cut -d= -f2- || true)"
fi

TRACE_LOG="${LOOP_SPEC_MICRO_GUARD_TRACE_LOG:-/tmp/claude-hooks/loop-spec-micro-guard-trace.log}"
trace() {
  mkdir -p "$(dirname "$TRACE_LOG")" 2>/dev/null || true
  printf '%s|adhoc-verify-guard|%s|%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >> "$TRACE_LOG" 2>/dev/null || true
}

command -v python3 &>/dev/null || { trace "fail-open" "no python3"; exit 0; }

# Cycle stand-down: resolve both ambient roots and all linked worktrees. Resolver
# failures allow Stop because this hook is an accelerator, never a lifecycle blocker.
active_rc=0
bash "$ACTIVE_CYCLE_BIN" has-active "$PWD" "$PROJECT_DIR" >/dev/null 2>&1 || active_rc=$?
if [[ "$active_rc" -eq 0 ]]; then
  trace "skip" "in-flight feature present"
  exit 0
elif [[ "$active_rc" -ne 1 ]]; then
  trace "fail-open" "active cycle resolution failed"
  exit 0
fi

INPUT=$(cat)

# Completed-cycle stand-down is transcript-scoped rather than checkout-scoped. Resolve
# the stable control-root result pointer even when Stop fires from a linked worktree.
RESULT_ROOT="$(bash "$CYCLE_RESULT_BIN" resolve-root "$PROJECT_DIR" 2>/dev/null || true)"
LAST_RESULT_FILE=""
[[ -z "$RESULT_ROOT" ]] || LAST_RESULT_FILE="$RESULT_ROOT/.loop-spec/last-result.json"

# One python pass scans Claude Code's transcript_path JSONL for final edits,
# path-correlated grounding reads, content diffs, and validation commands. The
# legacy inline transcript shape remains a fail-open compatibility fallback.
# Output is a single
# pipe-delimited line: verdict|reason|edit_count.
VERDICT=$(printf '%s' "$INPUT" | LOOP_SPEC_PROJ_VERIFY_CMD="$PROJ_VERIFY_CMD" \
  LOOP_SPEC_PROJECT_DIR="$PROJECT_DIR" LOOP_SPEC_LAST_RESULT_FILE="$LAST_RESULT_FILE" python3 -c "
import datetime, json, os, re, shlex, subprocess, sys

EDIT_TOOLS = {'Write', 'Edit', 'NotebookEdit'}
REVIEW_SUBCOMMANDS = {'diff', 'show'}
SUMMARY_FLAGS = {'--check', '--stat', '--shortstat', '--numstat', '--name-only', '--name-status',
                 '--quiet', '--no-patch', '-s'}
VERIFY_RE = re.compile(
    r'(pytest|unittest|jest|vitest|mocha|go\s+test|cargo\s+(test|check|build)'
    r'|npm\s+(test|run)|pnpm\s+(test|run|lint|build)|yarn\s+(test|run|lint|build)'
    r'|make\b|tox|rspec|phpunit|gradle|mvn|ruff|eslint|flake8|mypy|tsc\b'
    r'|typecheck|shellcheck|\blint\b|\bbuild\b|\bcompile\b|run-all\.sh'
    r'|(^|\s)(bash\s+)?[^\s]*(tests?/[^\s]+\.sh|\.test\.sh)(\s|$)'
    r'|git\s+diff\s+--check)', re.I)

def out(verdict, reason, edits=0):
    print('%s|%s|%s' % (verdict, reason, edits))
    sys.exit(0)

def norm(path, base):
    path = str(path or '').strip()
    if not path:
        return ''
    return os.path.normpath(path if os.path.isabs(path) else os.path.join(base, path))

repo_cache = {}

def logical_path(path):
    '''Stable identity for one path across a repository's linked worktrees.'''
    # Git reports physical roots. Resolve aliases such as macOS /var -> /private/var
    # before deriving a repository-relative identity.
    path = os.path.realpath(os.path.abspath(path))
    probe = path if os.path.isdir(path) else os.path.dirname(path)
    while probe and not os.path.isdir(probe):
        parent = os.path.dirname(probe)
        if parent == probe:
            break
        probe = parent
    if probe in repo_cache:
        root, common = repo_cache[probe]
    else:
        try:
            root = subprocess.check_output(
                ['git', '-C', probe, 'rev-parse', '--show-toplevel'],
                stderr=subprocess.DEVNULL, text=True).strip()
            common = subprocess.check_output(
                ['git', '-C', root, 'rev-parse', '--git-common-dir'],
                stderr=subprocess.DEVNULL, text=True).strip()
            if not os.path.isabs(common):
                common = os.path.join(root, common)
            common = os.path.realpath(common)
        except Exception:
            root, common = '', ''
        repo_cache[probe] = (root, common)
    if root:
        try:
            relative = os.path.normpath(os.path.relpath(path, root))
            if relative != '..' and not relative.startswith('..' + os.sep):
                return ('git', common, relative)
        except Exception:
            pass
    return ('fs', '', path)

def contains(scope, path):
    if scope[:2] != path[:2]:
        return False
    try:
        return os.path.commonpath([scope[2], path[2]]) == scope[2]
    except Exception:
        return False

def parse_time(value):
    if isinstance(value, (int, float)):
        return float(value)
    value = str(value or '').strip()
    if not value:
        return None
    try:
        return datetime.datetime.fromisoformat(
            value.replace('Z', '+00:00')).timestamp()
    except Exception:
        return None

def contains_cycle_invocation(value):
    if isinstance(value, str):
        return bool(re.search(r'(^|[\\s>\"\\x27])/?loop-spec:cycle(?=\\s|$|[<\"\\x27])', value))
    if isinstance(value, list):
        return any(contains_cycle_invocation(item) for item in value)
    if isinstance(value, dict):
        return any(contains_cycle_invocation(item) for item in value.values())
    return False

def terminal_cycle_finished_at(project, stable_result):
    '''Newest trustworthy full-cycle terminal time in this repository/worktree set.'''
    roots = {os.path.realpath(project)}
    try:
        listing = subprocess.check_output(
            ['git', '-C', project, '-c', 'core.quotePath=false',
             'worktree', 'list', '--porcelain'],
            stderr=subprocess.DEVNULL, text=True)
        for line in listing.splitlines():
            if line.startswith('worktree '):
                roots.add(os.path.realpath(line[len('worktree '):]))
    except Exception:
        pass

    candidates = []
    if stable_result:
        candidates.append(('result', stable_result))
    for root in roots:
        candidates.append(('result', os.path.join(root, '.loop-spec', 'last-result.json')))
        features = os.path.join(root, '.loop-spec', 'features')
        try:
            feature_names = os.listdir(features)
        except Exception:
            continue
        for name in feature_names:
            feature_dir = os.path.join(features, name)
            candidates.append(('result', os.path.join(feature_dir, 'result.json')))
            candidates.append(('delivery', os.path.join(feature_dir, 'delivery.json')))

    newest = None
    seen = set()
    for kind, candidate in candidates:
        candidate = os.path.realpath(candidate)
        if candidate in seen or not os.path.isfile(candidate):
            continue
        seen.add(candidate)
        try:
            with open(candidate) as stream:
                record = json.load(stream)
            if kind == 'result':
                if (record.get('cycleType') != 'full'
                        or record.get('status') not in
                        {'completed', 'paused', 'escalated', 'terminal', 'failed'}):
                    continue
                finished = parse_time(record.get('finishedAt'))
            else:
                if record.get('nextPhase') != 'completed':
                    continue
                finished = parse_time(
                    record.get('finishedAt') or record.get('updatedAt')
                    or record.get('observedAt') or record.get('attemptedAt'))
            if finished is not None and (newest is None or finished > newest):
                newest = finished
        except Exception:
            continue
    return newest

def command_parts(command):
    return [p.strip() for p in re.split(r'\s*(?:&&|\|\||;)\s*', command) if p.strip()]

def review_targets(part, project):
    '''Paths a content-review command shows: [] = the whole change, None = not a review.

    Both git diff (uncommitted work) and git show (work already committed) print the
    content of a change; summary forms (--stat, -s, --name-only) print no content.'''
    try:
        tokens = shlex.split(part)
    except Exception:
        return None
    try:
        git_i = next(i for i, t in enumerate(tokens) if os.path.basename(t) == 'git')
    except StopIteration:
        return None
    base = project
    sub_i = git_i + 1
    while sub_i < len(tokens):  # skip git's global options to reach the subcommand
        token = tokens[sub_i]
        if token in ('-C', '-c') and sub_i + 1 < len(tokens):
            if token == '-C':
                base = norm(tokens[sub_i + 1], project)
            sub_i += 2
            continue
        if token.startswith('-'):
            sub_i += 1
            continue
        break
    if sub_i >= len(tokens) or tokens[sub_i] not in REVIEW_SUBCOMMANDS:
        return None
    if any(flag in tokens for flag in SUMMARY_FLAGS):
        return None
    if '--' not in tokens[sub_i + 1:]:
        return []  # no pathspec means the content review covers every edited path
    sep = tokens.index('--', sub_i + 1)
    return [logical_path(norm(t, base)) for t in tokens[sep + 1:] if t]

def covers(targets, path):
    return not targets or any(t == path or contains(t, path) for t in targets)

def is_verify(part, project_cmd):
    if 'adhoc-ledger.sh' in part:
        return False
    if project_cmd and project_cmd in part:
        return True
    return bool(VERIFY_RE.search(part))

try:
    payload = json.load(sys.stdin)
except Exception:
    out('allow', 'unparseable payload')

entries = []
cycle_invoked = False
transcript_path = str(payload.get('transcript_path') or '')
if transcript_path and os.path.isfile(transcript_path):
    try:
        with open(transcript_path) as transcript:
            for line in transcript:
                try:
                    entry = json.loads(line)
                except Exception:
                    continue
                if entry.get('type') == 'user' and contains_cycle_invocation(
                        (entry.get('message') or {}).get('content')):
                    cycle_invoked = True
                if entry.get('type') == 'assistant':
                    entries.append((
                        (entry.get('message') or {}).get('content') or [],
                        parse_time(entry.get('timestamp'))))
    except Exception:
        out('allow', 'unreadable transcript')
else:
    for entry in (payload.get('transcript') or []):
        if isinstance(entry, dict) and entry.get('role') == 'user' and contains_cycle_invocation(
                entry.get('content')):
            cycle_invoked = True
        if isinstance(entry, dict) and entry.get('role') == 'assistant':
            entries.append((entry.get('content') or [], parse_time(entry.get('timestamp'))))
    if not entries:
        out('allow', 'no transcript')

project = os.path.abspath(os.environ.get('LOOP_SPEC_PROJECT_DIR') or '.')
project_cmd = (os.environ.get('LOOP_SPEC_PROJ_VERIFY_CMD') or '').strip()
idx = 0
edits = {}
edit_times = {}
contexts = []
diffs = []
verifies = []
edit_count = 0

for content, entry_time in entries:
    for item in content:
        if not isinstance(item, dict) or item.get('type') != 'tool_use':
            continue
        idx += 1
        name = item.get('name', '')
        inp = item.get('input') or {}
        if name in EDIT_TOOLS:
            path = norm(inp.get('file_path') or inp.get('notebook_path'), project)
            if path:
                edits[path] = idx
                edit_times[path] = entry_time
                edit_count += 1
        elif name == 'Read':
            path = norm(inp.get('file_path'), project)
            if path:
                contexts.append((idx, logical_path(path)))
        elif name == 'Skill':
            if contains_cycle_invocation(inp.get('skill')):
                cycle_invoked = True
        elif name == 'Bash':
            command = str(inp.get('command', ''))
            for part in command_parts(command):
                targets = review_targets(part, project)
                if targets is not None:
                    diffs.append((idx, targets))
                if is_verify(part, project_cmd):
                    verifies.append(idx)

if edit_count == 0:
    out('allow', 'no edits')

# A path that is gone cannot be re-read, and an untracked one never reaches a diff
# either: demanding evidence for it strands the session with no way to satisfy the
# gate. Exempt it, and order the gate by the last edit that survived to Stop.
live_edits = {path: i for path, i in edits.items() if os.path.exists(path)}
if not live_edits:
    out('allow', 'every edited path was removed before stop', edit_count)

# A terminal full-cycle result exempts only the transcript that produced it. The
# invocation marker prevents an old or concurrent cycle from excusing unrelated
# work, and the timestamp comparison re-arms the guard for edits made after delivery.
last_edit_time = max(
    (edit_times.get(path) for path in live_edits if edit_times.get(path) is not None),
    default=None)
result_file = os.environ.get('LOOP_SPEC_LAST_RESULT_FILE') or ''
if cycle_invoked and last_edit_time is not None:
    finished_at = terminal_cycle_finished_at(project, result_file)
    if finished_at is not None and finished_at >= last_edit_time:
        out('allow', 'terminal full cycle owns verification for this transcript', edit_count)

last_edit = max(live_edits.values())
reviews = [(i, targets) for i, targets in diffs if i > last_edit]
if not reviews:
    out('block', 'no content diff was inspected after the final edit', edit_count)

# Either form of content evidence grounds a path: an exact re-read of it, or a content
# review whose pathspec covers it. Requiring both made a wide diff-reviewed change
# (docs sweeps, generated files) pay a per-file re-read that showed nothing new.
grounded_indexes = []
for path in live_edits:
    logical_edit = logical_path(path)
    evidence = [i for i, read_path in contexts if i > last_edit and read_path == logical_edit]
    evidence += [i for i, targets in reviews if covers(targets, logical_edit)]
    if not evidence:
        out('block', 'an edited path was neither re-read nor covered by a content diff after the final edit', edit_count)
    grounded_indexes.append(min(evidence))

# Earliest point at which every path was grounded: evidence only accumulates, so
# repeating a diff while summarizing the work must not retract the verification that
# already followed a complete grounding.
grounded_at = max(grounded_indexes)
if not any(i > grounded_at for i in verifies):
    out('block', 'no verification command ran after the post-change grounding review', edit_count)
out('allow', 'grounding and verification completed after final edit', edit_count)
" 2>/dev/null || echo "")

# Fail-open when python produced nothing.
[[ -z "$VERDICT" ]] && { trace "fail-open" "empty python output"; exit 0; }

IFS='|' read -r DECISION REASON EDITS <<<"$VERDICT"

if [[ "$DECISION" == "block" ]]; then
  trace "deny" "$REASON edits=${EDITS:-?}"
  echo "DENY: ${EDITS:-?} file edit(s) this session but ${REASON}. Micro VERIFY requires both a post-change grounding review and the project's real verification command after the final edit. Grounding: inspect the final content diff -- \`git diff\` for uncommitted work, \`git show HEAD\` once it is committed (a --stat/-s summary does not count) -- and re-read any edited path that diff does not cover, plus the relevant callers/tests/contracts. For a pass, copy each --criteria value byte-for-byte into exactly one grounding: lib/adhoc-ledger.sh add --title ... --criteria \"<criterion>\" --grounding \"<criterion> | repo: <file>:<positive line> | integration: <file>:<positive line>\" --verify \"<command>\" --result pass. With no integration site use \"integration: none - <reason of at least 10 characters>\". A fail/partial result may omit grounding." >&2
  echo "(If this project's verification command isn't recognized, declare it: add VERIFY_CMD=<command> to .loop-spec/micro.conf. To disable this check: /loop-spec:micro off, or LOOP_SPEC_MICRO_GUARD=0.)" >&2
  exit 2
fi

trace "allow" "$REASON"
exit 0
