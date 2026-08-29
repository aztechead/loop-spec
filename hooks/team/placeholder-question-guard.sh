#!/usr/bin/env bash
# PreToolUse hook: block AskUserQuestion used as a wait or keep-alive.
#
# A live /cycle run invented dummy questions (header `wait`, options `n/a` /
# "Type something", question "not a real question") so the lead had something to
# show while a background Agent or a long DELIVER bash call ran. Instruction-only
# forbids did not stop it. This hook is the tool-boundary backstop.
#
# Claude Code contract:
#   exit 0  = allow
#   exit 2  = deny (stderr shown to the model)
#
# Denies when any of these hold:
#   1. dummy/placeholder tells (the live strings, plus close variants)
#   2. an Agent tool_use is still open in the transcript (in-flight subagent)
#   3. currentPhase is verify or deliver (those phases have no user questions)
#   4. currentPhase is iterate and the header is not the spec-rewind gate
#
# Real questions (grill, SPEC interview, specifying-gates, plan-adherence
# re-queue/abort, iterate Re-open SPEC) pass when no Agent is in flight.
#
# Kill switch: LOOP_SPEC_PLACEHOLDER_QUESTION_GUARD=0 -> exit 0.
# Fail-open: missing payload, malformed JSON, or python3 failure -> exit 0.
set -euo pipefail

trap 'exit 0' ERR

if [[ "${LOOP_SPEC_PLACEHOLDER_QUESTION_GUARD:-1}" == "0" ]]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
if [[ ! -d "$PROJECT_DIR/.loop-spec" && ! -d "$PWD/.loop-spec" ]]; then
  exit 0
fi
[[ -d "$PROJECT_DIR/.loop-spec" ]] || PROJECT_DIR="$PWD"

command -v python3 &>/dev/null || exit 0

INPUT=$(cat 2>/dev/null) || true
[[ -z "$INPUT" ]] && exit 0

RESULT=$(printf '%s' "$INPUT" | python3 -c "$(cat <<'PY'
import json
import os
import re
import sys

project_dir = sys.argv[1]
DUMMY_HEADER = re.compile(
    r"^(wait|waiting|ping|idle|keepalive|keep-alive|n/?a\d*)$", re.I
)
DUMMY_QUESTION = re.compile(
    r"not a real question|placeholder question|keep.?alive|"
    r"this is not (an? )?question|just wait(ing)?",
    re.I,
)
DUMMY_LABEL = re.compile(r"^(n/?a\d*|type something|dummy|placeholder)$", re.I)
REOPEN_SPEC = re.compile(r"^re-?open spec$", re.I)
LATE_PHASES = {"verify", "deliver"}

def load_payload():
    try:
        return json.load(sys.stdin)
    except Exception:
        return None

def flatten_questions(tool_input):
    if not isinstance(tool_input, dict):
        return []
    raw = tool_input.get("questions")
    if isinstance(raw, list):
        items = raw
    elif tool_input.get("question") or tool_input.get("header"):
        items = [tool_input]
    else:
        return []
    out = []
    for item in items:
        if not isinstance(item, dict):
            continue
        labels = []
        options = item.get("options") or []
        if not isinstance(options, list):
            options = []
        for opt in options:
            if isinstance(opt, dict):
                labels.append(str(opt.get("label") or ""))
            else:
                labels.append(str(opt))
        out.append({
            "header": str(item.get("header") or ""),
            "question": str(item.get("question") or ""),
            "labels": labels,
        })
    return out

def is_dummy(q):
    header = q["header"].strip()
    question = q["question"].strip()
    if not question and not header:
        return True
    if DUMMY_HEADER.match(header):
        return True
    if DUMMY_QUESTION.search(question):
        return True
    for label in q["labels"]:
        if DUMMY_LABEL.match(label.strip()):
            return True
    return False

def open_agent(transcript_path):
    if not transcript_path or not os.path.isfile(transcript_path):
        return False
    dispatches = []
    result_ids = set()
    try:
        with open(transcript_path) as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                message = entry.get("message") or {}
                if not isinstance(message, dict):
                    continue
                content = message.get("content") or []
                if not isinstance(content, list):
                    continue
                if entry.get("type") == "assistant":
                    for part in content:
                        if not isinstance(part, dict):
                            continue
                        if part.get("type") == "tool_use" and part.get("name") == "Agent":
                            dispatches.append(part.get("id"))
                elif entry.get("type") == "user":
                    for part in content:
                        if not isinstance(part, dict):
                            continue
                        if part.get("type") == "tool_result" and part.get("tool_use_id"):
                            result_ids.add(part["tool_use_id"])
    except OSError:
        return False
    for tool_id in dispatches:
        if tool_id is None or tool_id not in result_ids:
            return True
    return False

def current_phase(root):
    features_dir = os.path.join(root, ".loop-spec", "features")
    if not os.path.isdir(features_dir):
        return ""
    newest = ("", "")
    try:
        names = os.listdir(features_dir)
    except OSError:
        return ""
    for name in names:
        path = os.path.join(features_dir, name, "feature.json")
        try:
            with open(path) as fh:
                data = json.load(fh)
        except Exception:
            continue
        phase = str(data.get("currentPhase") or "")
        if phase in ("", "completed"):
            continue
        updated = str(data.get("updatedAt") or "")
        if updated >= newest[0]:
            newest = (updated, phase)
    return newest[1]

payload = load_payload()
if not payload:
    print("ALLOW")
    raise SystemExit(0)
if str(payload.get("tool_name") or "") != "AskUserQuestion":
    print("ALLOW")
    raise SystemExit(0)

questions = flatten_questions(payload.get("tool_input") or {})
if any(is_dummy(q) for q in questions) or not questions:
    print("DENY:dummy")
    raise SystemExit(0)
if open_agent(str(payload.get("transcript_path") or "")):
    print("DENY:agent")
    raise SystemExit(0)

phase = current_phase(project_dir)
if phase in LATE_PHASES:
    print("DENY:phase")
    raise SystemExit(0)
if phase == "iterate":
    headers = [q["header"].strip() for q in questions]
    if not any(REOPEN_SPEC.match(h) for h in headers):
        print("DENY:phase")
        raise SystemExit(0)
print("ALLOW")
PY
)" "$PROJECT_DIR") || RESULT="ALLOW"

case "$RESULT" in
  DENY:dummy)
    echo "DENY: AskUserQuestion is not a wait. Dummy options (n/a, Type something) and a question that says it is not a real question are forbidden. Issue the Agent or Bash call, then stop; the harness resumes this turn. Do not occupy the wait with a question. (Disable: LOOP_SPEC_PLACEHOLDER_QUESTION_GUARD=0)" >&2
    exit 2
    ;;
  DENY:agent)
    echo "DENY: an Agent is still running. Stop; do not AskUserQuestion until it returns. The harness resumes this turn. Dummy wait questions are forbidden. (Disable: LOOP_SPEC_PLACEHOLDER_QUESTION_GUARD=0)" >&2
    exit 2
    ;;
  DENY:phase)
    echo "DENY: this phase has no wait-question. VERIFY and DELIVER never AskUserQuestion; ITERATE only asks the Re-open SPEC gate in step/interactive. The required-check wait is inside lib/deliver.sh. Stop; the harness resumes this turn. (Disable: LOOP_SPEC_PLACEHOLDER_QUESTION_GUARD=0)" >&2
    exit 2
    ;;
  *)
    exit 0
    ;;
esac
