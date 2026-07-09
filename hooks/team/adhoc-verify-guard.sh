#!/usr/bin/env bash
# Stop hook: evidence-before-done for ad-hoc (micro-cycle) work.
#
# Claude Code contract:
#   exit 0  = allow
#   exit 2  = block (with stderr message shown to user)
#
# The enforcement half of micro mode (skills/micro/SKILL.md invariant 5): a session
# that edited files must have run a verification command AFTER the last edit before
# it is allowed to stop. Scans the Stop payload's transcript for tool_use items:
# Write/Edit/NotebookEdit mark edits; a Bash command matching the verification
# pattern (tests, lint, build, run-all.sh, adhoc-ledger.sh) marks evidence.
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
#   - no edits in the transcript, or every edited path is prose (.md/.txt/.rst)
#
# Fail-open: missing/malformed payload, no python3, empty transcript -> exit 0.
#
# Environment variables (all optional):
#   LOOP_SPEC_MICRO_GUARD        Set to "0" to disable. Default: 1 (active).
#   LOOP_SPEC_MICRO_GUARD_TRACE_LOG  Path for trace log.
#                                Default: /tmp/claude-hooks/loop-spec-micro-guard-trace.log
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

TRACE_LOG="${LOOP_SPEC_MICRO_GUARD_TRACE_LOG:-/tmp/claude-hooks/loop-spec-micro-guard-trace.log}"
trace() {
  mkdir -p "$(dirname "$TRACE_LOG")" 2>/dev/null || true
  printf '%s|adhoc-verify-guard|%s|%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >> "$TRACE_LOG" 2>/dev/null || true
}

command -v python3 &>/dev/null || { trace "fail-open" "no python3"; exit 0; }

# Cycle stand-down: any in-flight feature means the cycle owns verification.
FEATURES_DIR="${PROJECT_DIR}/.loop-spec/features"
if [[ -d "$FEATURES_DIR" ]]; then
  for fj in "$FEATURES_DIR"/*/feature.json; do
    [[ -f "$fj" ]] || continue
    phase="$(jq -r '.currentPhase // "completed"' "$fj" 2>/dev/null || echo "completed")"
    if [[ "$phase" != "completed" ]]; then
      trace "skip" "in-flight feature $(basename "$(dirname "$fj")") phase=$phase"
      exit 0
    fi
  done
fi

INPUT=$(cat)

# stop_hook_active guard: never re-block a continuation we already forced.
if printf '%s' "$INPUT" | python3 -c "import json,sys; sys.exit(0 if json.load(sys.stdin).get('stop_hook_active') else 1)" 2>/dev/null; then
  trace "skip" "stop_hook_active"
  exit 0
fi

# Scan the transcript: position of the last edit, positions of Bash verification
# commands, and whether any edited path is a code (non-prose) file.
VERDICT=$(printf '%s' "$INPUT" | python3 -c "
import json, re, sys

VERIFY_RE = re.compile(
    r'(\btests?\b|pytest|unittest|jest|vitest|mocha|go test|cargo (test|check|build)'
    r'|npm (test|run)|pnpm|yarn|make\b|tox|rspec|phpunit|gradle|mvn'
    r'|lint|ruff|eslint|flake8|mypy|tsc\b|typecheck|shellcheck'
    r'|build|compile|run-all\.sh|adhoc-ledger\.sh)', re.I)
PROSE_RE = re.compile(r'\.(md|txt|rst)$', re.I)
EDIT_TOOLS = {'Write', 'Edit', 'NotebookEdit'}

try:
    d = json.load(sys.stdin)
    transcript = d.get('transcript') or []
except Exception:
    print(json.dumps({'verdict': 'allow', 'reason': 'unparseable payload'}))
    sys.exit(0)

idx = 0
last_edit = -1
last_verify = -1
edit_count = 0
code_edit = False
for entry in transcript:
    if not isinstance(entry, dict):
        continue
    for item in (entry.get('content') or []):
        if not isinstance(item, dict) or item.get('type') != 'tool_use':
            continue
        idx += 1
        name = item.get('name', '')
        inp = item.get('input') or {}
        if name in EDIT_TOOLS:
            last_edit = idx
            edit_count += 1
            path = str(inp.get('file_path', '') or inp.get('notebook_path', ''))
            if not PROSE_RE.search(path):
                code_edit = True
        elif name == 'Bash':
            if VERIFY_RE.search(str(inp.get('command', ''))):
                last_verify = idx

if edit_count == 0:
    print(json.dumps({'verdict': 'allow', 'reason': 'no edits'}))
elif not code_edit:
    print(json.dumps({'verdict': 'allow', 'reason': 'prose-only edits'}))
elif last_verify > last_edit:
    print(json.dumps({'verdict': 'allow', 'reason': 'verification after last edit'}))
else:
    reason = 'no verification command ran' if last_verify < 0 else 'last verification predates last edit'
    print(json.dumps({'verdict': 'block', 'reason': reason, 'edits': edit_count}))
" 2>/dev/null || echo "")

# Fail-open when python produced nothing.
[[ -z "$VERDICT" ]] && { trace "fail-open" "empty python output"; exit 0; }

DECISION=$(printf '%s' "$VERDICT" | jq -r '.verdict // "allow"' 2>/dev/null || echo "allow")
REASON=$(printf '%s' "$VERDICT" | jq -r '.reason // ""' 2>/dev/null || echo "")

if [[ "$DECISION" == "block" ]]; then
  EDITS=$(printf '%s' "$VERDICT" | jq -r '.edits // "?"' 2>/dev/null || echo "?")
  trace "deny" "$REASON edits=$EDITS"
  echo "DENY: ${EDITS} file edit(s) this session but ${REASON}. Micro-cycle invariant 5: run the project's real verification command (tests/lint/build), show the output, and record the entry with lib/adhoc-ledger.sh add --title ... --criteria ... --verify \"<command>\" --result pass|fail|partial. A 'fail' result with the output shown is a valid ending." >&2
  echo "(To disable this check: /loop-spec:micro off, or LOOP_SPEC_MICRO_GUARD=0.)" >&2
  exit 2
fi

trace "allow" "$REASON"
exit 0
