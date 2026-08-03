#!/usr/bin/env bash
# Stop hook: block completion claims that carry an explicit unresolved
# self-authored deferred-scope declaration.
#
# loop-spec's contract: once the design exists, the model runs it to completion.
# "Done — Deferred scope: ..." is not a valid successful conclusion. The only
# legitimate deferral writers are the bounded gates, whose lines carry their own markers
# (iterate-budget-spent: / iterate-terminal: / verify-deferred) and are exempt
# in lib/deferral-lint.sh — the single home of the structured declaration rules this
# hook applies.
#
# Claude Code contract:
#   exit 0 = allow
#   exit 2 = block (stderr shown to the model)
#
# Blocks the first stop (exit 2) when BOTH hold in the final assistant text:
#   1. a completion claim is present (converged / ready for review / PR opened /
#      "<phase|work|cycle...> complete" / all acceptance criteria pass), AND
#   2. lib/deferral-lint.sh flags an explicit self-authored scope declaration.
# That denial creates a transcript-scoped obligation record. Rewording the next
# completion message does not clear it. A later completion is allowed only after:
#   1. repository state changed after the denial,
#   2. the transcript shows implementation activity followed by verification, and
#   3. the completion report contains `Resolved scope: <item> — <evidence>`.
# This is deliberately evidence-based: the forbidden vocabulary is only the symptom;
# the omitted spec work is the defect.
#
# `stop_hook_active` is NOT an override. Claude Code sets it on the continuation
# after a Stop hook blocks; treating it as an unconditional allow turns every Stop
# guard into a one-retry wording gate.
#
# Ignoring it is safe because the host already bounds the loop: Claude Code counts
# consecutive Stop-hook blocks and force-completes the turn once the count reaches
# CLAUDE_CODE_STOP_HOOK_BLOCK_CAP (default 8), warning the user rather than looping
# forever. So the worst case here is a bounded push-back, not a wedged session --
# and the operator kill switch below is always available.
#
# Ordinary conversation (including design discussion of scope) never matches
# condition 1, so the guard cannot fire outside a completion report.
#
# Fail-open: missing payload, malformed JSON, unreadable transcript, or a
# missing lint binary always exit 0. Errors never cascade into the session.
#
# Environment variables (all optional):
#   LOOP_SPEC_DEFERRAL_GUARD       Set to "0" to disable. Default: 1 (active).
#   LOOP_SPEC_DEFERRAL_TRACE_LOG   Path for trace log.
#                                  Default: /tmp/claude-hooks/loop-spec-deferral-trace.log
#   LOOP_SPEC_DEFERRAL_STATE_DIR   Transcript-scoped obligation records.
#                                  Default: /tmp/claude-hooks/loop-spec-deferral-state
set -euo pipefail

# Kill switch.
if [[ "${LOOP_SPEC_DEFERRAL_GUARD:-1}" == "0" ]]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"

# Scope: only active in projects that use loop-spec.
if [[ ! -d "$PROJECT_DIR/.loop-spec" && ! -d "$PWD/.loop-spec" ]]; then
  exit 0
fi
[[ -d "$PROJECT_DIR/.loop-spec" ]] || PROJECT_DIR="$PWD"

# Fail-open: any unexpected error must not block the session.
trap 'exit 0' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFERRAL_LINT="${LOOP_SPEC_DEFERRAL_LINT_BIN:-$SCRIPT_DIR/../../lib/deferral-lint.sh}"
TRACE_LOG="${LOOP_SPEC_DEFERRAL_TRACE_LOG:-/tmp/claude-hooks/loop-spec-deferral-trace.log}"
STATE_DIR="${LOOP_SPEC_DEFERRAL_STATE_DIR:-/tmp/claude-hooks/loop-spec-deferral-state}"

trace() {
  local event="$1"
  local reason="$2"
  mkdir -p "$(dirname "$TRACE_LOG")" 2>/dev/null || true
  printf '%s|deferral-guard|%s|%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$event" "$reason" \
    >> "$TRACE_LOG" 2>/dev/null || true
}

[[ -f "$DEFERRAL_LINT" ]] || { trace "fail-open" "deferral-lint.sh not found"; exit 0; }
command -v python3 &>/dev/null || { trace "fail-open" "python3 not found"; exit 0; }

INPUT=$(cat)

# Parse the final assistant text and retain the ordered assistant content stream.
# The content cursor is persisted at denial time so a retry can prove that work and
# verification happened AFTER the guard raised the scope obligation.
PARSE_RESULT=$(printf '%s' "$INPUT" | LOOP_SPEC_PROJECT_DIR="$PROJECT_DIR" python3 -c "
import hashlib, json, os, sys

try:
    d = json.load(sys.stdin)
except Exception:
    print(json.dumps({'valid': False}))
    sys.exit(0)

assistant_contents = []
transcript_path = str(d.get('transcript_path') or '')
if transcript_path and os.path.isfile(transcript_path):
    try:
        with open(transcript_path) as transcript:
            for line in transcript:
                try:
                    entry = json.loads(line)
                except Exception:
                    continue
                if entry.get('type') == 'assistant':
                    assistant_contents.append((entry.get('message') or {}).get('content') or [])
    except Exception:
        pass
else:
    for entry in d.get('transcript') or []:
        if isinstance(entry, dict) and entry.get('role') == 'assistant':
            assistant_contents.append(entry.get('content') or [])

text = ''
for content in reversed(assistant_contents):
    parts = [c.get('text', '') for c in content
             if isinstance(c, dict) and c.get('type') == 'text']
    if parts:
        text = '\n'.join(parts)
        break

cursor = 0
tools = []
for content in assistant_contents:
    for item in content:
        cursor += 1
        if not isinstance(item, dict) or item.get('type') != 'tool_use':
            continue
        inp = item.get('input') or {}
        tools.append({
            'cursor': cursor,
            'name': str(item.get('name') or ''),
            'command': str(inp.get('command') or ''),
        })

identity = str(d.get('session_id') or transcript_path or '')
state_key = ''
if identity:
    project = os.path.realpath(os.environ.get('LOOP_SPEC_PROJECT_DIR') or '.')
    state_key = hashlib.sha256((project + '\0' + identity).encode()).hexdigest()

print(json.dumps({
    'valid': True,
    'text': text,
    'cursor': cursor,
    'tools': tools,
    'stateKey': state_key,
    'stopHookActive': bool(d.get('stop_hook_active')),
}))
" 2>/dev/null || echo "")

if [[ -z "$PARSE_RESULT" ]] || \
   [[ "$(printf '%s' "$PARSE_RESULT" | python3 -c "import json,sys; print('yes' if json.load(sys.stdin).get('valid') else 'no')" 2>/dev/null || echo no)" != "yes" ]]; then
  trace "fail-open" "malformed or unreadable payload"
  exit 0
fi

TEXT=$(printf '%s' "$PARSE_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('text',''))" 2>/dev/null || echo "")
CURSOR=$(printf '%s' "$PARSE_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('cursor',0))" 2>/dev/null || echo "0")
STATE_KEY=$(printf '%s' "$PARSE_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('stateKey',''))" 2>/dev/null || echo "")
STOP_ACTIVE=$(printf '%s' "$PARSE_RESULT" | python3 -c "import json,sys; print('yes' if json.load(sys.stdin).get('stopHookActive') else 'no')" 2>/dev/null || echo "no")

STATE_FILE=""
if [[ -n "$STATE_KEY" ]]; then
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  STATE_FILE="$STATE_DIR/$STATE_KEY.json"
fi

# A fingerprint binds remediation to material repository state, not rewritten
# completion prose. It includes HEAD, tracked changes, and untracked file contents.
repo_fingerprint() {
  LOOP_SPEC_PROJECT_DIR="$PROJECT_DIR" python3 -c "
import hashlib, os, subprocess

project = os.environ.get('LOOP_SPEC_PROJECT_DIR') or '.'
try:
    root = subprocess.check_output(
        ['git', '-C', project, 'rev-parse', '--show-toplevel'],
        stderr=subprocess.DEVNULL, text=True).strip()
    head = subprocess.check_output(
        ['git', '-C', root, 'rev-parse', 'HEAD'],
        stderr=subprocess.DEVNULL)
    status = subprocess.check_output(
        ['git', '-C', root, 'status', '--porcelain=v1', '-z', '--untracked-files=all'],
        stderr=subprocess.DEVNULL)
    diff = subprocess.check_output(
        ['git', '-C', root, 'diff', '--binary', 'HEAD', '--'],
        stderr=subprocess.DEVNULL)
except Exception:
    print('')
    raise SystemExit(0)

h = hashlib.sha256()
for value in (head, status, diff):
    h.update(len(value).to_bytes(8, 'big'))
    h.update(value)

for record in status.split(b'\0'):
    if not record.startswith(b'?? '):
        continue
    relative = os.fsdecode(record[3:])
    path = os.path.join(root, relative)
    try:
        if os.path.isfile(path):
            with open(path, 'rb') as stream:
                content = stream.read()
            h.update(relative.encode(errors='surrogateescape'))
            h.update(len(content).to_bytes(8, 'big'))
            h.update(content)
    except OSError:
        pass

print(h.hexdigest())
" 2>/dev/null || echo ""
}

write_obligation() {
  local fingerprint="$1"
  [[ -n "$STATE_FILE" && ! -e "$STATE_FILE" ]] || return 0
  LOOP_SPEC_STATE_CURSOR="$CURSOR" \
  LOOP_SPEC_STATE_FINGERPRINT="$fingerprint" \
  LOOP_SPEC_STATE_FLAGS="$FLAGS" \
  LOOP_SPEC_STATE_REPORT="$TEXT" \
  python3 - "$STATE_FILE" <<'PY' 2>/dev/null || true
import datetime
import json
import os
import sys
import tempfile

path = sys.argv[1]
record = {
    "schema": 1,
    "cursor": int(os.environ.get("LOOP_SPEC_STATE_CURSOR") or 0),
    "fingerprint": os.environ.get("LOOP_SPEC_STATE_FINGERPRINT") or "",
    "flags": (os.environ.get("LOOP_SPEC_STATE_FLAGS") or "").splitlines(),
    "reportExcerpt": (os.environ.get("LOOP_SPEC_STATE_REPORT") or "")[-4000:],
    "deniedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
}
os.makedirs(os.path.dirname(path), exist_ok=True)
fd, tmp = tempfile.mkstemp(prefix=".deferral-", suffix=".tmp", dir=os.path.dirname(path))
try:
    with os.fdopen(fd, "w") as stream:
        json.dump(record, stream, sort_keys=True)
        stream.write("\n")
    os.replace(tmp, path)
finally:
    try:
        os.unlink(tmp)
    except FileNotFoundError:
        pass
PY
}

deny_direct() {
  trace "deny" "completion claim with self-authored deferral"
  {
    echo "DENY: this completion report creates an unresolved scope obligation. loop-spec has no valid successful conclusion with model-chosen deferred/follow-up work — everything in the spec/design ships."
    printf '%s\n' "$FLAGS"
    echo "Implement the flagged item now. Rewording or deleting the trigger phrase will not clear this guard: it recorded the repository state and transcript position."
    echo "After the implementation changes, run verification and report: Resolved scope: <item> — <files and verification evidence>."
    echo "If a line was written by a bounded gate, restore its gate marker (iterate-budget-spent: / iterate-terminal: / verify-deferred)."
    echo "(To disable this check, set LOOP_SPEC_DEFERRAL_GUARD=0.)"
  } >&2
  exit 2
}

deny_unresolved() {
  local reasons="$1"
  trace "deny" "completion claim rewrites unresolved scope obligation: $reasons"
  {
    echo "DENY: changing the wording did not resolve the scope obligation raised by the previous deferral guard."
    echo "Still required: $reasons."
    echo "Implement the omitted item, make a material repository change, run verification after that work, and include:"
    echo "Resolved scope: <item> — <files and verification evidence>"
    echo "(To disable this check, set LOOP_SPEC_DEFERRAL_GUARD=0.)"
  } >&2
  exit 2
}

if [[ -z "$TEXT" ]]; then
  trace "allow" "no assistant text"
  exit 0
fi

# Without a completion claim this is ordinary conversation. Keep any outstanding
# obligation record so it is enforced if this transcript later claims completion.
if ! printf '%s' "$TEXT" | grep -qiE \
  'converged|ready for review|all (acceptance )?criteria (pass|met)|pr (opened|created|is ready)|opened a pr|(cycle|implementation|work|feature|task|micro-cycle|delivery|verification) (is |now )?complete|shipped'; then
  trace "allow" "no completion claim"
  exit 0
fi

FLAGS=$(printf '%s' "$TEXT" | bash "$DEFERRAL_LINT" text - 2>/dev/null | grep '^FLAG' || true)

# A direct violation always blocks, including on a stop_hook_active continuation.
# Preserve the first snapshot: repeated rewording must not move the evidence goalpost.
if [[ -n "$FLAGS" ]]; then
  if [[ -n "$STATE_FILE" && ! -e "$STATE_FILE" ]]; then
    write_obligation "$(repo_fingerprint)"
  fi
  deny_direct
fi

# A prior denial in this transcript remains binding even though the new final text
# is vocabulary-clean. Clearing it requires material work plus ordered evidence.
if [[ -n "$STATE_FILE" && -f "$STATE_FILE" ]]; then
  BASE_CURSOR="$(
    python3 - "$STATE_FILE" 2>/dev/null <<'PY' || true
import json
import sys
with open(sys.argv[1]) as stream:
    print(int(json.load(stream).get("cursor", 0)))
PY
  )"
  BASE_FINGERPRINT="$(
    python3 - "$STATE_FILE" 2>/dev/null <<'PY' || true
import json
import sys
with open(sys.argv[1]) as stream:
    print(json.load(stream).get("fingerprint", ""))
PY
  )"
  if [[ -z "$BASE_CURSOR" || -z "$BASE_FINGERPRINT" ]]; then
    trace "fail-open" "unreadable obligation state"
    exit 0
  fi

  CURRENT_FINGERPRINT="$(repo_fingerprint)"
  EVIDENCE_SEQUENCE=$(printf '%s' "$PARSE_RESULT" | LOOP_SPEC_BASE_CURSOR="$BASE_CURSOR" python3 -c "
import json, os, re, sys

data = json.load(sys.stdin)
cursor = int(os.environ.get('LOOP_SPEC_BASE_CURSOR') or 0)
verify_re = re.compile(
    r'(pytest|unittest|jest|vitest|mocha|go\\s+test|cargo\\s+(test|check|build)'
    r'|npm\\s+(test|run)|pnpm\\s+(test|run|lint|build)|yarn\\s+(test|run|lint|build)'
    r'|make\\b|tox|rspec|phpunit|gradle|mvn|ruff|eslint|flake8|mypy|tsc\\b'
    r'|typecheck|shellcheck|\\blint\\b|\\bbuild\\b|\\bcompile\\b|run-all\\.sh'
    r'|git\\s+diff\\s+--check|(^|\\s)(bash\\s+)?[^\\s]*(tests?/[^\\s]+\\.sh|\\.test\\.sh)(\\s|$))',
    re.I)
work_tools = {'Edit', 'Write', 'NotebookEdit', 'MultiEdit', 'Agent', 'Task'}
work = []
verification = []
for item in data.get('tools') or []:
    position = int(item.get('cursor') or 0)
    if position <= cursor:
        continue
    name = item.get('name') or ''
    command = item.get('command') or ''
    is_verify = name == 'Bash' and bool(verify_re.search(command))
    if name in work_tools or (name == 'Bash' and not is_verify):
        work.append(position)
    if is_verify:
        verification.append(position)
print('yes' if any(w < v for w in work for v in verification) else 'no')
" 2>/dev/null || echo "no")

  reasons=()
  if [[ -z "$CURRENT_FINGERPRINT" || "$CURRENT_FINGERPRINT" == "$BASE_FINGERPRINT" ]]; then
    reasons+=("no material repository change after the denial")
  fi
  if [[ "$EVIDENCE_SEQUENCE" != "yes" ]]; then
    reasons+=("no implementation action followed by a verification command after the denial")
  fi
  if ! printf '%s' "$TEXT" | grep -qiE '^[[:space:]]*([-*][[:space:]]*)?resolved scope[[:space:]]*:'; then
    reasons+=("the completion report does not identify the resolved scope and its evidence")
  fi

  if [[ "${#reasons[@]}" -gt 0 ]]; then
    joined="$(IFS='; '; echo "${reasons[*]}")"
    deny_unresolved "$joined"
  fi

  rm -f "$STATE_FILE"
  trace "allow" "scope obligation resolved with repository change and ordered verification"
  exit 0
fi

if [[ "$STOP_ACTIVE" == "yes" ]]; then
  trace "allow" "stop_hook_active without this guard's obligation"
else
  trace "allow" "completion claim clean"
fi
exit 0
