#!/usr/bin/env bash
# PreToolUse hook: enforce one durable loop-spec phase per main-agent invocation.
#
# When phase handoff is enabled, cycle may invoke one phase skill. A second, different
# phase skill in the same transcript means a phase tried to chain directly instead of
# returning to cycle. This hook writes the paused machine result itself and denies the
# second phase invocation, so the outer SDK process receives a deterministic handoff
# even if the model ignored the routing prose.
set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
if [[ ! -d "$PROJECT_DIR/.loop-spec" && ! -d "$PWD/.loop-spec" ]]; then
  exit 0
fi

trap 'exit 0' ERR
command -v python3 &>/dev/null || exit 0

INPUT=$(cat)
PARSED=$(printf '%s' "$INPUT" | python3 -c '
import json
import os
import re
import sys

phase_re = re.compile(
    r"(?:^|/|:)loop-spec:(spec|discuss|plan|execute|verify|iterate|deliver)$"
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

if str(payload.get("tool_name") or "") != "Skill":
    print(json.dumps({"valid": True, "target": "", "prior": []}))
    raise SystemExit(0)

target = phase_name((payload.get("tool_input") or {}).get("skill"))
prior = []
transcript_path = str(payload.get("transcript_path") or "")
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
    except Exception:
        contents = []
else:
    contents = [
        entry.get("content") or []
        for entry in (payload.get("transcript") or [])
        if isinstance(entry, dict) and entry.get("role") == "assistant"
    ]

for content in contents:
    for item in content:
        if not isinstance(item, dict) or item.get("type") != "tool_use":
            continue
        if item.get("name") != "Skill":
            continue
        phase = phase_name((item.get("input") or {}).get("skill"))
        if phase:
            prior.append(phase)

print(json.dumps({"valid": True, "target": target, "prior": prior}))
' 2>/dev/null || echo "")

[[ -n "$PARSED" ]] || exit 0
TARGET=$(printf '%s' "$PARSED" | python3 -c \
  'import json,sys; print(json.load(sys.stdin).get("target",""))' 2>/dev/null || echo "")
[[ -n "$TARGET" ]] || exit 0

# Environment is authoritative. When unset, use the persisted feature policy so the
# inline `phase:fresh` token and later bare resume invocations remain enforced.
case "${LOOP_SPEC_PHASE_HANDOFF:-}" in
  0) exit 0 ;;
  1) enabled=true ;;
  "") enabled="" ;;
  *)
    echo "DENY: LOOP_SPEC_PHASE_HANDOFF must be 0 or 1." >&2
    exit 2
    ;;
esac

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
            bool(data.get("phaseHandoff")),
            str(data.get("currentPhase") or ""),
        ))

if not candidates:
    print("")
else:
    _, path, handoff, phase = max(candidates, key=lambda item: item[0])
    print(json.dumps({"path": str(path), "phaseHandoff": handoff, "phase": phase}))
' 2>/dev/null || echo "")

if [[ -z "$enabled" ]]; then
  enabled=$(printf '%s' "$FEATURE_DIR" | python3 -c \
    'import json,sys; print("true" if json.load(sys.stdin).get("phaseHandoff") else "false")' \
    2>/dev/null || echo "false")
fi
[[ "$enabled" == "true" ]] || exit 0

PRIOR=$(printf '%s' "$PARSED" | python3 -c \
  'import json,sys; p=json.load(sys.stdin).get("prior") or []; print(p[-1] if p else "")' \
  2>/dev/null || echo "")
[[ -n "$PRIOR" ]] || exit 0

# Re-entering the same phase for an internal retry is not a phase boundary.
[[ "$TARGET" != "$PRIOR" ]] || exit 0

FEATURE_PATH=$(printf '%s' "$FEATURE_DIR" | python3 -c \
  'import json,sys; print(json.load(sys.stdin).get("path",""))' 2>/dev/null || echo "")
CURRENT_PHASE=$(printf '%s' "$FEATURE_DIR" | python3 -c \
  'import json,sys; print(json.load(sys.stdin).get("phase",""))' 2>/dev/null || echo "")

# Only block the transition after durable state names the attempted next phase.
# This prevents an unrelated phase-skill call from being mistaken for cycle routing.
[[ -n "$FEATURE_PATH" && "$CURRENT_PHASE" == "$TARGET" ]] || exit 0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
summary="Phase ${PRIOR} completed; ${TARGET} is ready in durable state."
bash "$SCRIPT_DIR/../../lib/cycle-result.sh" write "$FEATURE_PATH" \
  --status paused --reason phase-handoff --summary "$summary" >/dev/null 2>&1 || true

echo "DENY: LOOP_SPEC_PHASE_HANDOFF=1 permits one loop-spec phase per main-agent invocation. Phase '$PRIOR' completed and '$TARGET' is persisted as next; the paused phase-handoff result has been written. Return immediately without invoking '$TARGET'." >&2
exit 2
