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
#   3. the active skill is verify or deliver (those phases have no user questions)
#   4. the active skill is iterate and the header is not the spec-rewind gate
#   5. the active skill is execute and the header is not plan-adherence or
#      specifying-gates
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
if [[ -d "$PWD/.loop-spec" ]]; then
  PROJECT_DIR="$PWD"
elif [[ ! -d "$PROJECT_DIR/.loop-spec" ]]; then
  exit 0
fi

command -v python3 &>/dev/null || exit 0

INPUT=$(cat 2>/dev/null) || true
[[ -z "$INPUT" ]] && exit 0

RESULT=$(printf '%s' "$INPUT" | python3 -c "$(cat <<'PY'
import json
import os
import re
import sys

DUMMY_HEADER = re.compile(
    r"^(wait|waiting|n/?a\d*)$", re.I
)
DUMMY_QUESTION = re.compile(
    r"not a real question|placeholder question|"
    r"this is not (an? )?question|just wait(ing)?",
    re.I,
)
DUMMY_LABEL = re.compile(r"^(n/?a\d*|type something|dummy|placeholder)$", re.I)
LATE_PHASES = {"verify", "deliver"}
ACTIVE_SKILL = re.compile(
    r"(?:^|/|:)loop-spec:(cycle|spec|discuss|plan|execute|verify|iterate|deliver|specifying-gates)$"
)
EXECUTE_CONTRACTS = {
    "plan gap": (
        re.compile(r"Plan-adherence found PLAN\.md ids with no completed task: .+\. Re-queue the missing work, or abort EXECUTE\?", re.I),
        frozenset({"Re-queue missing tasks", "Abort EXECUTE"}),
    ),
    "gate outcome": (
        re.compile(r"Gate: .+\. Use Other to type 1-5 concrete observable criteria, or choose an existing source\. Each criterion must name the observable and its exact passing value, regex, or threshold\.", re.I),
        frozenset({"Copy from task's acceptanceCriteria", "Stop - revise task"}),
    ),
    "mechanism": (
        re.compile(r"Use Other to paste the exact shell command that captures proof, or choose an existing mechanism\. API and inspection checks must be expressed as executable commands\.", re.I),
        frozenset({"Use task verifyCommand", "Subagent with briefing", "Stop - revise task"}),
    ),
    "scope": (
        re.compile(r"Run this once, or over multiple targets\?", re.I),
        frozenset({"Once", "Per instance / target", "First on one, then on all", "Custom"}),
    ),
    "on failure": (
        re.compile(r"If the gate fails, what happens\?", re.I),
        frozenset({"Stop the plan (Recommended)", "Reopen this task, continue others", "Log and continue"}),
    ),
    "briefing": (
        re.compile(r"Use Other to paste the exact prompt / briefing the subagent should receive, or choose a source\. This becomes the dispatch contract -- the agent cannot substitute a shorter version at runtime\.", re.I),
        frozenset({"Use instances/<tag>/seed-briefing.md", "Generate from task description", "Stop - revise task"}),
    ),
}
ITERATE_CONTRACT = (
    re.compile(r"ITERATE judges the goal still unmet because of a SPEC-level gap: .+\. Re-open SPEC/DISCUSS, ship as-is, or stop\?", re.I),
    frozenset({"Re-open SPEC/DISCUSS", "Ship as-is", "Stop - hand back"}),
)

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
            "multi_select": item.get("multiSelect") is True,
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

def matches_contract(q, contracts):
    if q["multi_select"]:
        return False
    contract = contracts.get(q["header"].strip().lower())
    if not contract:
        return False
    question, labels = contract
    return bool(question.fullmatch(q["question"].strip())) and frozenset(q["labels"]) == labels

def transcript_context(transcript_path):
    if not transcript_path or not os.path.isfile(transcript_path):
        return False, ""
    dispatches = []
    result_ids = set()
    phase = ""
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
                        if part.get("type") != "tool_use":
                            continue
                        if part.get("name") == "Agent":
                            dispatches.append(part.get("id"))
                        elif part.get("name") == "Skill":
                            skill = str((part.get("input") or {}).get("skill") or "")
                            match = ACTIVE_SKILL.search(skill)
                            if match:
                                active = match.group(1)
                                if active in {"cycle", "spec", "discuss", "plan"}:
                                    phase = ""
                                elif active == "specifying-gates":
                                    phase = "execute"
                                else:
                                    phase = active
                elif entry.get("type") == "user":
                    for part in content:
                        if not isinstance(part, dict):
                            continue
                        if part.get("type") == "tool_result" and part.get("tool_use_id"):
                            result_ids.add(part["tool_use_id"])
    except OSError:
        return False, ""
    for tool_id in dispatches:
        if tool_id is None or tool_id not in result_ids:
            return True, phase
    return False, phase

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
agent_open, phase = transcript_context(str(payload.get("transcript_path") or ""))
if agent_open:
    print("DENY:agent")
    raise SystemExit(0)

if phase in LATE_PHASES:
    print("DENY:phase")
    raise SystemExit(0)
if phase == "iterate":
    if not all(matches_contract(q, {"re-open spec": ITERATE_CONTRACT}) for q in questions):
        print("DENY:phase")
        raise SystemExit(0)
if phase == "execute":
    if not all(matches_contract(q, EXECUTE_CONTRACTS) for q in questions):
        print("DENY:phase")
        raise SystemExit(0)
print("ALLOW")
PY
)") || RESULT="ALLOW"

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
    echo "DENY: this phase has no wait-question. VERIFY and DELIVER never AskUserQuestion; ITERATE only asks the Re-open SPEC gate in step/interactive; EXECUTE only asks Plan gap or specifying-gates. The required-check wait is inside lib/deliver.sh. Stop; the harness resumes this turn. (Disable: LOOP_SPEC_PLACEHOLDER_QUESTION_GUARD=0)" >&2
    exit 2
    ;;
  *)
    exit 0
    ;;
esac
