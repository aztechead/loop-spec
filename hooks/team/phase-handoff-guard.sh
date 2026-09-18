#!/usr/bin/env bash
# PreToolUse hook: enforce one durable loop-spec phase per main-agent invocation.
#
# Every phase hands off (the port plan, WP4): cycle invokes one phase skill,
# the driver answers HANDOFF, and the next phase starts in a fresh session. A second,
# different phase skill in the same transcript means a phase tried to chain directly
# instead of returning to cycle. The one exception is graph data: an edge carrying
# `sameSession` (`lib/graph/phases.sh same-session`), today spec -> oneshot. This hook
# writes the paused machine result itself and denies the second phase invocation, so
# the outer process receives a deterministic handoff even if the model ignored the
# routing prose.
set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
if [[ ! -d "$PROJECT_DIR/.loop-spec" && ! -d "$PWD/.loop-spec" ]]; then
  exit 0
fi

trap 'exit 0' ERR
command -v python3 &>/dev/null || exit 0

INPUT=$(cat)
# The phase ids come from the graph (lib/graph/phases.sh); an unreadable graph leaves
# the alternation empty and the guard matches nothing, which is the fail-open side.
# Only a Skill call can enter a phase; the one thing any other tool call can trip is
# the durable-handoff denial below, and that needs an open feature that recorded a
# handoff. jq answers both before the python launches: on the `.*` matcher they ran
# on every call of a live cycle (about 0.6 s behind a version-manager shim).
tool="$(printf '%s' "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null || true)"
# An empty answer (no jq, or a payload jq refuses) falls through to the python path
# below rather than reading as "not a Skill call".
if [[ -n "$tool" && "$tool" != "Skill" ]]; then
  pending=0
  for f in "$PROJECT_DIR"/.loop-spec/features/*/feature.json "$PWD"/.loop-spec/features/*/feature.json; do
    [[ -f "$f" ]] || continue
    if jq -e '(.currentPhase != "completed") and (.handoffSession | type == "object")' "$f" >/dev/null 2>&1; then
      pending=1; break
    fi
  done
  (( pending )) || exit 0
fi
# Every python3 launch below skips the version-manager shim (lib/python-path.sh).
py_dir="$(bash "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/python-path.sh" 2>/dev/null || true)"
[[ -z "$py_dir" ]] || export PATH="$py_dir:$PATH"
LOOP_SPEC_PHASE_ALT=""
if [[ -z "$tool" || "$tool" == "Skill" ]]; then
  LOOP_SPEC_PHASE_ALT="$(bash "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/graph/phases.sh" regex 2>/dev/null || true)"
fi
export LOOP_SPEC_PHASE_ALT
IDENTITY_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/lib/session_identity.py"
SESSION_ID=$(LOOP_SPEC_IDENTITY_INPUT="$INPUT" python3 "$IDENTITY_HELPER" 2>/dev/null || echo "")
# simplicity: retain four-space Python indentation inside this shell boundary; extract
# a standalone reader only if the parser becomes shared by another hook.
PARSED=$(printf '%s' "$INPUT" | python3 -c '
import json
import os
import re
import sys

phase_re = re.compile(
    r"(?:^|/|:)loop-spec:(" + os.environ.get("LOOP_SPEC_PHASE_ALT", "") + r")$"
)

def phase_name(value):
    value = str(value or "").strip()
    match = phase_re.search(value)
    return match.group(1) if match else ""

try:
    payload = json.load(sys.stdin)
except Exception:
    print(json.dumps({"valid": False}))
    raise SystemExit(0)

target = phase_name((payload.get("tool_input") or {}).get("skill")) \
    if str(payload.get("tool_name") or "") == "Skill" else ""
prior = []
# Only a phase Skill call needs the prior-phase list; every other tool call
# skips the transcript parse, which grows with the session.
transcript_path = str(payload.get("transcript_path") or "") if target else ""
contents, results = [], []
if transcript_path and os.path.isfile(transcript_path):
    try:
        with open(transcript_path) as stream:
            entries = []
            for line in stream:
                try:
                    entries.append(json.loads(line))
                except Exception:
                    pass
        contents = [
            (entry.get("message") or {}).get("content") or []
            for entry in entries if entry.get("type") == "assistant"
        ]
        results = [
            (entry.get("message") or {}).get("content") or []
            for entry in entries if entry.get("type") == "user"
        ]
    except Exception:
        contents, results = [], []
elif target:
    contents = [
        entry.get("content") or []
        for entry in (payload.get("transcript") or [])
        if isinstance(entry, dict) and entry.get("role") == "assistant"
    ]
    results = [
        entry.get("content") or []
        for entry in (payload.get("transcript") or [])
        if isinstance(entry, dict) and entry.get("role") == "user"
    ]

# A denied attempt never ran the phase. Counting it made the retry rule below a
# loophole: a lead denied once for the next phase invoked it again, the denial was
# now the "prior" phase, and the second call passed as a same-phase retry.
denied = set()
for content in results:
    if not isinstance(content, list):
        continue
    for item in content:
        if not isinstance(item, dict) or item.get("type") != "tool_result":
            continue
        body = item.get("content")
        if isinstance(body, list):
            body = " ".join(str(b.get("text", "")) for b in body if isinstance(b, dict))
        if item.get("is_error") or "hook error" in str(body or ""):
            denied.add(item.get("tool_use_id"))

for content in contents:
    for item in content:
        if not isinstance(item, dict) or item.get("type") != "tool_use":
            continue
        if item.get("name") != "Skill" or item.get("id") in denied:
            continue
        phase = phase_name((item.get("input") or {}).get("skill"))
        if phase:
            prior.append(phase)

print(json.dumps({"valid": True, "target": target, "prior": prior}))
' 2>/dev/null || echo "")

[[ -n "$PARSED" ]] || exit 0
# Durable feature state, rather than model formatting, is the handoff authority.
TARGET=$(printf '%s' "$PARSED" | python3 -c \
  'import json,sys; print(json.load(sys.stdin).get("target",""))' 2>/dev/null || echo "")

FEATURE_DIR=$(LOOP_SPEC_PROJECT_DIR="$PROJECT_DIR" LOOP_SPEC_PWD="$PWD" python3 -c '
import json
import os
from pathlib import Path

roots = []
for raw in (os.environ.get("LOOP_SPEC_PWD"), os.environ.get("LOOP_SPEC_PROJECT_DIR")):
    if not raw:
        continue
    root = Path(raw).resolve()
    if root not in roots:
        roots.append(root)

candidates = []
for root in roots:
    features = root / ".loop-spec" / "features"
    if not features.is_dir():
        continue
    for path in features.glob("*/feature.json"):
        try:
            data = json.loads(path.read_text())
        except Exception:
            continue
        if data.get("currentPhase") == "completed":
            continue
        candidates.append((
            str(data.get("updatedAt") or ""),
            path.parent,
            str(data.get("currentPhase") or ""),
        ))

if not candidates:
    print("")
else:
    _, path, phase = max(candidates, key=lambda item: item[0])
    print(json.dumps({"path": str(path), "phase": phase}))
' 2>/dev/null || echo "")
[[ -n "$FEATURE_DIR" ]] || exit 0

if [[ -n "$SESSION_ID" ]]; then
  SAME_HANDOFF=$(LOOP_SPEC_SESSION="$SESSION_ID" python3 -c '
import json, os, sys
try:
    descriptor = json.load(sys.stdin)
    state = json.load(open(os.path.join(descriptor["path"], "feature.json")))
    record = state.get("handoffSession")
except (OSError, KeyError, TypeError, ValueError):
    record = None
print("1" if isinstance(record, dict) and record.get("id") == os.environ.get("LOOP_SPEC_SESSION") else "0")
' <<<"$FEATURE_DIR" 2>/dev/null || echo "0")
  if [[ "$SAME_HANDOFF" == "1" ]]; then
    echo "DENY: this session already answered a phase handoff; stop and let the caller start the next phase." >&2
    exit 2
  fi
fi

[[ -n "$TARGET" ]] || exit 0

PRIOR=$(printf '%s' "$PARSED" | python3 -c \
  'import json,sys; p=json.load(sys.stdin).get("prior") or []; print(p[-1] if p else "")' \
  2>/dev/null || echo "")
[[ -n "$PRIOR" ]] || exit 0

# Re-entering the same phase for an internal retry is not a phase boundary.
[[ "$TARGET" != "$PRIOR" ]] || exit 0

# The graph's one exception: an edge into the target that carries sameSession (the
# short route, spec -> oneshot). The driver answers NEXT across it, never HANDOFF.
# LOOP_SPEC_SAME_SESSION=1 makes every edge one, an operator's opt into one session
# end to end (#10, 6.6.4 live run); lib/graph/driver.py record_transition reads the
# same variable.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${LOOP_SPEC_SAME_SESSION:-}" == "1" ]] \
    || bash "$SCRIPT_DIR/../../lib/graph/phases.sh" same-session "$PRIOR" "$TARGET" 2>/dev/null; then
  exit 0
fi

FEATURE_PATH=$(printf '%s' "$FEATURE_DIR" | python3 -c \
  'import json,sys; print(json.load(sys.stdin).get("path",""))' 2>/dev/null || echo "")
CURRENT_PHASE=$(printf '%s' "$FEATURE_DIR" | python3 -c \
  'import json,sys; print(json.load(sys.stdin).get("phase",""))' 2>/dev/null || echo "")

# Only block the transition after durable state names the attempted next phase.
# This prevents an unrelated phase-skill call from being mistaken for cycle routing.
[[ -n "$FEATURE_PATH" && "$CURRENT_PHASE" == "$TARGET" ]] || exit 0

summary="Phase ${PRIOR} completed; ${TARGET} is ready in durable state."
bash "$SCRIPT_DIR/../../lib/cycle-result.sh" write "$FEATURE_PATH" \
  --status paused --reason phase-handoff --summary "$summary" >/dev/null 2>&1 || true

echo "DENY: loop-spec runs one phase per main-agent invocation. Phase '$PRIOR' completed and '$TARGET' is persisted as next; the paused phase-handoff result has been written. Return immediately without invoking '$TARGET'." >&2
exit 2
