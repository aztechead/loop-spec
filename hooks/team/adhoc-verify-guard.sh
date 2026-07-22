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
# pass over the Stop payload does all the work: Write/Edit/NotebookEdit mark edits;
# an exact Read of every edited file plus a final `git diff` mark repository grounding; a Bash command matching
# the verification pattern or the project's declared VERIFY_CMD marks validation.
#
# Stands down (exit 0) when:
#   - LOOP_SPEC_MICRO_GUARD=0 (kill switch), or micro.conf pins ENABLED=0
#   - the project has no .loop-spec/ dir (never hijack unrelated projects)
#   - a cycle feature is in flight (any .loop-spec/features/*/feature.json with
#     currentPhase != "completed") - the cycle's VERIFY phase owns evidence at
#     feature scale, and blocking between phases would fight the orchestrator.
#     Trade-off: a paused feature also disarms the guard; guards here are
#     accelerators, never blockers, so we err on allow.
#   - no edits in the transcript
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

# Cycle stand-down: any in-flight feature means the cycle owns verification.
# Single jq pass over every feature.json (they accumulate; one spawn, not N).
FEATURES_DIR="${PROJECT_DIR}/.loop-spec/features"
if [[ -d "$FEATURES_DIR" ]]; then
  phases="$(jq -r '.currentPhase // "completed"' "$FEATURES_DIR"/*/feature.json 2>/dev/null || true)"
  if printf '%s\n' "$phases" | grep -qv -e '^completed$' -e '^$'; then
    trace "skip" "in-flight feature present"
    exit 0
  fi
fi

INPUT=$(cat)

# One python pass scans Claude Code's transcript_path JSONL for final edits,
# path-correlated grounding reads, content diffs, and validation commands. The
# legacy inline transcript shape remains a fail-open compatibility fallback.
# Output is a single
# pipe-delimited line: verdict|reason|edit_count.
VERDICT=$(printf '%s' "$INPUT" | LOOP_SPEC_PROJ_VERIFY_CMD="$PROJ_VERIFY_CMD" LOOP_SPEC_PROJECT_DIR="$PROJECT_DIR" python3 -c "
import json, os, re, shlex, sys

EDIT_TOOLS = {'Write', 'Edit', 'NotebookEdit'}
SUMMARY_FLAGS = {'--check', '--stat', '--shortstat', '--numstat', '--name-only', '--name-status', '--quiet'}
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

def contains(scope, path):
    try:
        return os.path.commonpath([scope, path]) == scope
    except Exception:
        return False

def command_parts(command):
    return [p.strip() for p in re.split(r'\s*(?:&&|\|\||;)\s*', command) if p.strip()]

def diff_targets(part, project):
    try:
        tokens = shlex.split(part)
    except Exception:
        return None
    try:
        git_i = next(i for i, t in enumerate(tokens) if os.path.basename(t) == 'git')
        diff_i = tokens.index('diff', git_i + 1)
    except (StopIteration, ValueError):
        return None
    if any(flag in tokens for flag in SUMMARY_FLAGS):
        return None
    base = project
    if '-C' in tokens[git_i + 1:diff_i]:
        ci = tokens.index('-C', git_i + 1, diff_i)
        if ci + 1 < diff_i:
            base = norm(tokens[ci + 1], project)
    if '--' not in tokens[diff_i + 1:]:
        return []  # no pathspec means the content diff covers every edited path
    sep = tokens.index('--', diff_i + 1)
    return [norm(t, base) for t in tokens[sep + 1:] if t]

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
transcript_path = str(payload.get('transcript_path') or '')
if transcript_path and os.path.isfile(transcript_path):
    try:
        with open(transcript_path) as transcript:
            for line in transcript:
                try:
                    entry = json.loads(line)
                except Exception:
                    continue
                if entry.get('type') == 'assistant':
                    entries.append((entry.get('message') or {}).get('content') or [])
    except Exception:
        out('allow', 'unreadable transcript')
else:
    for entry in (payload.get('transcript') or []):
        if isinstance(entry, dict) and entry.get('role') == 'assistant':
            entries.append(entry.get('content') or [])
    if not entries:
        out('allow', 'no transcript')

project = os.path.abspath(os.environ.get('LOOP_SPEC_PROJECT_DIR') or '.')
project_cmd = (os.environ.get('LOOP_SPEC_PROJ_VERIFY_CMD') or '').strip()
idx = 0
edits = {}
contexts = []
diffs = []
verifies = []
edit_count = 0

for content in entries:
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
                edit_count += 1
        elif name == 'Read':
            path = norm(inp.get('file_path'), project)
            if path:
                contexts.append((idx, path))
        elif name == 'Bash':
            command = str(inp.get('command', ''))
            for part in command_parts(command):
                targets = diff_targets(part, project)
                if targets is not None:
                    diffs.append((idx, targets))
                if is_verify(part, project_cmd):
                    verifies.append(idx)

if edit_count == 0:
    out('allow', 'no edits')

last_edit = max(edits.values())
context_indexes = []
for path, edit_idx in edits.items():
    matches = [i for i, read_path in contexts if i > last_edit and read_path == path]
    if not matches:
        out('block', 'post-change grounding review did not re-read every edited path', edit_count)
    context_indexes.append(max(matches))

covering_diffs = []
for diff_idx, targets in diffs:
    if diff_idx <= last_edit:
        continue
    if not targets or all(any(t == path or contains(t, path) for t in targets) for path in edits):
        covering_diffs.append(diff_idx)
if not covering_diffs:
    out('block', 'post-change grounding review did not inspect a content diff covering every edited path', edit_count)

grounded_at = max(context_indexes + [max(covering_diffs)])
if not any(i > grounded_at for i in verifies):
    out('block', 'no verification command ran after the post-change grounding review', edit_count)
out('allow', 'grounding and verification completed after final edit', edit_count)
" 2>/dev/null || echo "")

# Fail-open when python produced nothing.
[[ -z "$VERDICT" ]] && { trace "fail-open" "empty python output"; exit 0; }

IFS='|' read -r DECISION REASON EDITS <<<"$VERDICT"

if [[ "$DECISION" == "block" ]]; then
  trace "deny" "$REASON edits=${EDITS:-?}"
  echo "DENY: ${EDITS:-?} file edit(s) this session but ${REASON}. Micro VERIFY requires both a post-change grounding review (re-read changed files and relevant callers/tests/contracts, then inspect the final git diff) and the project's real verification command after the final edit. For a pass, copy each --criteria value byte-for-byte into exactly one grounding: lib/adhoc-ledger.sh add --title ... --criteria \"<criterion>\" --grounding \"<criterion> | repo: <file>:<positive line> | integration: <file>:<positive line>\" --verify \"<command>\" --result pass. With no integration site use \"integration: none - <reason of at least 10 characters>\". A fail/partial result may omit grounding." >&2
  echo "(If this project's verification command isn't recognized, declare it: add VERIFY_CMD=<command> to .loop-spec/micro.conf. To disable this check: /loop-spec:micro off, or LOOP_SPEC_MICRO_GUARD=0.)" >&2
  exit 2
fi

trace "allow" "$REASON"
exit 0
