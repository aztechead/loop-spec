#!/usr/bin/env bash
# Stop hook: evidence-before-done for ad-hoc (micro-cycle) work.
#
# Claude Code contract:
#   exit 0  = allow
#   exit 2  = block (with stderr message shown to user)
#
# The enforcement half of micro mode (skills/micro/SKILL.md invariant 5): a session
# that edited code files must have run a verification command AFTER the last edit
# before it is allowed to stop. One python pass over the Stop payload does all the
# work: Write/Edit/NotebookEdit tool_use items mark edits (non-code paths — docs
# and config — are exempt); a Bash command matching the verification pattern
# (tests, lint, build, run-all.sh, adhoc-ledger.sh) or containing the project's
# declared VERIFY_CMD (from .loop-spec/micro.conf) marks evidence.
#
# Stands down (exit 0) when:
#   - LOOP_SPEC_MICRO_GUARD=0 (kill switch), or micro.conf pins ENABLED=0
#   - the project has no .loop-spec/ dir (never hijack unrelated projects)
#   - stop_hook_active (never re-block; CC force-overrides after 8 anyway)
#   - a cycle feature is in flight (any .loop-spec/features/*/feature.json with
#     currentPhase != "completed") - the cycle's VERIFY phase owns evidence at
#     feature scale, and blocking between phases would fight the orchestrator.
#     Trade-off: a paused feature also disarms the guard; guards here are
#     accelerators, never blockers, so we err on allow.
#   - no edits in the transcript, or every edited path is non-code (docs/config)
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

# One python pass: stop_hook_active short-circuit, then scan the transcript for
# the position of the last edit, the last verification Bash command, and whether
# any edited path is a code (non-doc, non-config) file. Output is a single
# pipe-delimited line: verdict|reason|edit_count.
VERDICT=$(printf '%s' "$INPUT" | LOOP_SPEC_PROJ_VERIFY_CMD="$PROJ_VERIFY_CMD" python3 -c "
import json, os, re, sys

VERIFY_RE = re.compile(
    r'(\btests?\b|pytest|unittest|jest|vitest|mocha|go test|cargo (test|check|build)'
    r'|npm (test|run)|pnpm|yarn|make\b|tox|rspec|phpunit|gradle|mvn'
    r'|lint|ruff|eslint|flake8|mypy|tsc\b|typecheck|shellcheck'
    r'|build|compile|run-all\.sh|adhoc-ledger\.sh)', re.I)
NONCODE_RE = re.compile(r'\.(md|markdown|txt|rst|adoc|json|ya?ml|toml|ini|cfg|conf|env|example)$', re.I)
EDIT_TOOLS = {'Write', 'Edit', 'NotebookEdit'}

def out(verdict, reason, edits=0):
    print('%s|%s|%s' % (verdict, reason, edits))
    sys.exit(0)

try:
    d = json.load(sys.stdin)
except Exception:
    out('allow', 'unparseable payload')

if d.get('stop_hook_active'):
    out('allow', 'stop_hook_active')

proj_cmd = (os.environ.get('LOOP_SPEC_PROJ_VERIFY_CMD') or '').strip()
idx = 0
last_edit = -1
last_verify = -1
edit_count = 0
code_edit = False
for entry in (d.get('transcript') or []):
    if not isinstance(entry, dict):
        continue
    for item in (entry.get('content') or []):
        if not isinstance(item, dict) or item.get('type') != 'tool_use':
            continue
        idx += 1
        name = item.get('name', '')
        inp = item.get('input') or {}
        if name in EDIT_TOOLS:
            path = str(inp.get('file_path', '') or inp.get('notebook_path', ''))
            if not path:
                continue  # malformed/rejected call in history; never count as an edit
            last_edit = idx
            edit_count += 1
            if not NONCODE_RE.search(path):
                code_edit = True
        elif name == 'Bash':
            cmd = str(inp.get('command', ''))
            if VERIFY_RE.search(cmd) or (proj_cmd and proj_cmd in cmd):
                last_verify = idx

if edit_count == 0:
    out('allow', 'no edits')
if not code_edit:
    out('allow', 'noncode-only edits')
if last_verify > last_edit:
    out('allow', 'verification after last edit')
out('block',
    'no verification command ran' if last_verify < 0 else 'last verification predates last edit',
    edit_count)
" 2>/dev/null || echo "")

# Fail-open when python produced nothing.
[[ -z "$VERDICT" ]] && { trace "fail-open" "empty python output"; exit 0; }

IFS='|' read -r DECISION REASON EDITS <<<"$VERDICT"

if [[ "$DECISION" == "block" ]]; then
  trace "deny" "$REASON edits=${EDITS:-?}"
  echo "DENY: ${EDITS:-?} file edit(s) this session but ${REASON}. Micro-cycle invariant 5: run the project's real verification command (tests/lint/build), show the output, and record the entry with lib/adhoc-ledger.sh add --title ... --criteria ... --verify \"<command>\" --result pass|fail|partial. A 'fail' result with the output shown is a valid ending." >&2
  echo "(If this project's verification command isn't recognized, declare it: add VERIFY_CMD=<command> to .loop-spec/micro.conf. To disable this check: /loop-spec:micro off, or LOOP_SPEC_MICRO_GUARD=0.)" >&2
  exit 2
fi

trace "allow" "$REASON"
exit 0
