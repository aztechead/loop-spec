#!/usr/bin/env bash
# Stop hook: block completion claims that carry self-authored deferred items.
#
# loop-spec's contract: once the design exists, the model runs it to completion.
# "Done — deferred items: ..." is not a valid successful conclusion; neither are
# model-chosen follow-ups or "future work" notes. The only legitimate deferral
# writers are the bounded gates, whose lines carry their own markers
# (iterate-budget-spent: / iterate-terminal: / verify-deferred) and are exempt
# in lib/deferral-lint.sh — the single home of the vocabulary this hook applies.
#
# Claude Code contract:
#   exit 0 = allow
#   exit 2 = block (stderr shown to the model)
#
# Blocks the stop (exit 2) only when BOTH hold in the final assistant text:
#   1. a completion claim is present (converged / ready for review / PR opened /
#      "<phase|work|cycle...> complete" / all acceptance criteria pass), AND
#   2. lib/deferral-lint.sh flags self-authored deferral language.
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
set -euo pipefail

# Kill switch.
if [[ "${LOOP_SPEC_DEFERRAL_GUARD:-1}" == "0" ]]; then
  exit 0
fi

# Scope: only active in projects that use loop-spec.
if [[ ! -d "${CLAUDE_PROJECT_DIR:-$PWD}/.loop-spec" && ! -d "$PWD/.loop-spec" ]]; then
  exit 0
fi

# Fail-open: any unexpected error must not block the session.
trap 'exit 0' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFERRAL_LINT="${LOOP_SPEC_DEFERRAL_LINT_BIN:-$SCRIPT_DIR/../../lib/deferral-lint.sh}"
TRACE_LOG="${LOOP_SPEC_DEFERRAL_TRACE_LOG:-/tmp/claude-hooks/loop-spec-deferral-trace.log}"

trace() {
  local event="$1"
  local reason="$2"
  mkdir -p "$(dirname "$TRACE_LOG")" 2>/dev/null || true
  printf '%s|deferral-guard|%s|%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$event" "$reason" \
    >> "$TRACE_LOG" 2>/dev/null || true
}

[[ -f "$DEFERRAL_LINT" ]] || { trace "fail-open" "deferral-lint.sh not found"; exit 0; }

INPUT=$(cat)

# stop_hook_active guard: when Claude Code is already continuing because of a
# previous Stop-hook block, do not block again (force-override after 8 blocks).
if printf '%s' "$INPUT" | python3 -c "import json,sys; sys.exit(0 if json.load(sys.stdin).get('stop_hook_active') else 1)" 2>/dev/null; then
  trace "skip" "stop_hook_active"
  exit 0
fi

# Last assistant text from production transcript_path JSONL, falling back to
# the legacy inline transcript payload (same contract as stop-deflection-guard).
TEXT=$(printf '%s' "$INPUT" | python3 -c "
import json, os, sys

try:
    d = json.load(sys.stdin)
except Exception:
    print('')
    sys.exit(0)

text = ''
transcript_path = str(d.get('transcript_path') or '')
if transcript_path and os.path.isfile(transcript_path):
    try:
        entries = []
        with open(transcript_path) as transcript:
            for line in transcript:
                try:
                    entry = json.loads(line)
                except Exception:
                    continue
                if entry.get('type') == 'assistant':
                    entries.append(entry)
        for entry in reversed(entries):
            message = entry.get('message') or {}
            parts = [c.get('text', '') for c in (message.get('content') or [])
                     if isinstance(c, dict) and c.get('type') == 'text']
            if parts:
                text = '\n'.join(parts)
                break
    except Exception:
        pass
else:
    for entry in reversed(d.get('transcript') or []):
        if not isinstance(entry, dict) or entry.get('role') != 'assistant':
            continue
        parts = [c.get('text', '') for c in (entry.get('content') or [])
                 if isinstance(c, dict) and c.get('type') == 'text']
        if parts:
            text = '\n'.join(parts)
            break

print(text)
" 2>/dev/null || echo "")

if [[ -z "$TEXT" ]]; then
  trace "allow" "no assistant text"
  exit 0
fi

# Condition 1: a completion claim. Without one, this is ordinary conversation
# (design discussion may legitimately weigh scope) and the guard stands down.
if ! printf '%s' "$TEXT" | grep -qiE \
  'converged|ready for review|all (acceptance )?criteria (pass|met)|pr (opened|created|is ready)|opened a pr|(cycle|implementation|work|feature|task|micro-cycle|delivery|verification) (is |now )?complete|shipped'; then
  trace "allow" "no completion claim"
  exit 0
fi

# Condition 2: deferral-lint flags the final text.
FLAGS=$(printf '%s' "$TEXT" | bash "$DEFERRAL_LINT" text - 2>/dev/null | grep '^FLAG' || true)

if [[ -z "$FLAGS" ]]; then
  trace "allow" "completion claim clean"
  exit 0
fi

trace "deny" "completion claim with self-authored deferral"
{
  echo "DENY: this completion report contains self-authored deferred/follow-up items. loop-spec has no valid successful conclusion with model-chosen deferrals — everything in the spec/design ships."
  printf '%s\n' "$FLAGS"
  echo "Implement the flagged items now (resume the cycle if needed). If a line was written by a bounded gate, restate it with its gate marker (iterate-budget-spent: / iterate-terminal: / verify-deferred)."
  echo "(To disable this check, set LOOP_SPEC_DEFERRAL_GUARD=0.)"
} >&2
exit 2
