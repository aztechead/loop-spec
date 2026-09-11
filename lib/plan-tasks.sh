#!/usr/bin/env bash
# plan-tasks.sh - Derive the EXECUTE tasks[] JSON from PLAN.md's task blocks.
#
# Why: tasks.json used to be copied from the planner's completion message, and a
# message is the one artifact that can arrive empty: a dropped SendMessage, a
# background launch stub, or a planner that wrote PLAN.md and then reported `tasks:
# []`. The lead saved the empty array, and EXECUTE, which reads only tasks.json,
# ended with nothing built. PLAN.md is the durable artifact and already carries every
# field the tasks lint requires, so it is the source and the message is not.
#
# One task per `### task-NNN: <subject>` block under `## Tasks`. Fields:
#   id, subject             the heading
#   files[]                 bullets under **Files:** (backticks stripped)
#   readFirst[]             bullets under **read_first:** (present only when listed)
#   verifyCommand           the first backtick span after **Verify:**
#   acceptanceCriteria[]    `- [ ]` / `- [x]` bullets under **Acceptance criteria:**
#   blockedBy[]             the block's **BlockedBy:** line ([], [a, b], a, b, -, none),
#                           else the task's row in the `## Task DAG` table
#   interfaces              {consumes, produces} from **Interfaces:** when either is
#                           listed and not `none`
#   repo, batchGroup, modelTier, specPath
#                           **Repo:**, **Batch group:**, **Model tier:**, **Spec path:**
#                           lines, present only when the block carries them
#   requirements[]          **Requirements:** bullets, each the parsed single-line JSON
#                           object {owner,requirement,revision,scenarios} (kept as the
#                           raw bullet string when it does not parse as JSON, so
#                           artifact-lint can flag the malformed shape instead of this
#                           extractor silently dropping it), present only when listed
#   obligations[]           **Obligations:** bullets, each the bare `OBL-...` id (or the
#                           raw bullet text when the line does not carry one), present
#                           only when listed
#   executionInputs         **Execution inputs:** single-line JSON object, parsed the
#                           same way (kept as the raw string when unparseable), present
#                           only when listed
# `lib/artifact-lint.sh tasks` validates the result; this script only reads the shape.
#
# Usage:
#   plan-tasks.sh extract <PLAN.md>      # tasks[] JSON on stdout
#
# Exit codes: 0 extracted; 1 no task blocks or unreadable file (fail safe: nothing
# to dispatch is a message, never an empty array); 2 bad invocation.
set -uo pipefail

[[ "${1:-}" == "extract" && $# -eq 2 ]] || { echo "usage: plan-tasks.sh extract <PLAN.md>" >&2; exit 2; }
plan="$2"
[[ -r "$plan" ]] || { echo "plan-tasks: cannot read $plan" >&2; exit 1; }

python3 - "$plan" <<'PY'
import json
import re
import sys

plan = sys.argv[1]
lines = open(plan, encoding="utf-8", errors="replace").read().splitlines()

HEADING = re.compile(r"^### (task-\d+):\s*(.+?)\s*$")
MARKER = re.compile(r"^\*\*([^*]+?)(?::\*\*|\*\*:)\s*(.*)$")
LISTS = ("Files", "read_first", "Acceptance criteria", "Interfaces", "Requirements", "Obligations")
PLAIN_LIST_KEY = {"Files": "files", "read_first": "readFirst", "Acceptance criteria": "acceptanceCriteria"}
BULLET = re.compile(r"^[-*+]\s+(?:\[[ xX]\]\s+)?(.*\S)\s*$")
CODE = re.compile(r"`([^`]+)`")
ROW = re.compile(r"^\|\s*(task-\d+)\s*\|([^|]*)\|([^|]*)\|")
OBLIGATION_ID = re.compile(r"OBL-[A-Za-z0-9][A-Za-z0-9-]*")

def strip_code(text):
    return CODE.sub(r"\1", text).strip()

def parsed_or_raw(text):
    """A Requirements bullet / Execution inputs value is single-line JSON per the
    grammar (docs/loop-spec/features/release-7-0/PLAN.md, Exact artifact grammar);
    keep the raw text when it fails to parse so artifact-lint's structural check is
    the one place that reports the malformed shape, not a silent drop here."""
    try:
        return json.loads(text)
    except ValueError:
        return text

def ids_from(text):
    text = text.strip().strip("[]")
    return [t.strip().strip("`") for t in re.split(r"[,\s]+", text)
            if t.strip().strip("`") and t.strip().strip("`") not in ("-", "none")]

# The DAG table is the fallback for blockedBy: | ID | Subject | BlockedBy | ...
table = {}
for line in lines:
    m = ROW.match(line.strip())
    if m:
        table[m.group(1)] = ids_from(m.group(3))

tasks = []
task = None
section = None
for raw in lines:
    line = raw.strip()
    head = HEADING.match(line)
    if head:
        task = {"id": head.group(1), "subject": head.group(2), "files": [], "blockedBy": None,
                "verifyCommand": "", "acceptanceCriteria": [], "readFirst": [], "interfaces": {}}
        tasks.append(task)
        section = None
        continue
    if task is None:
        continue
    if line.startswith("## ") or line.startswith("---"):
        task = None
        continue
    marker = MARKER.match(line)
    if marker:
        name, rest = marker.group(1).strip(), marker.group(2).strip()
        section = None
        if name == "Verify":
            code = CODE.search(rest)
            task["verifyCommand"] = code.group(1).strip() if code else rest
        elif name == "BlockedBy":
            task["blockedBy"] = ids_from(rest)
        elif name == "Repo":
            task["repo"] = strip_code(rest)
        elif name == "Batch group":
            task["batchGroup"] = strip_code(rest)
        elif name == "Model tier":
            task["modelTier"] = strip_code(rest)
        elif name == "Spec path":
            task["specPath"] = strip_code(rest)
        elif name == "Execution inputs":
            task["executionInputs"] = parsed_or_raw(rest)
        elif name in LISTS:
            section = name
        continue
    bullet = BULLET.match(line)
    if section is None:
        continue
    if not bullet:
        # A plain-prose bullet a planner wrapped across lines (an acceptance criterion
        # is the case that lost text before this fix): join it onto the last item of
        # the current plain-text list. Requirements/Obligations/Interfaces hold
        # structured values, not prose, so a stray continuation line there is left
        # alone rather than corrupted into their JSON/key:value shape.
        key = PLAIN_LIST_KEY.get(section)
        if line and key and task.get(key):
            task[key][-1] += " " + line
        continue
    item = bullet.group(1)
    if section == "Files":
        task["files"].append(strip_code(item))
    elif section == "read_first":
        task["readFirst"].append(strip_code(item))
    elif section == "Acceptance criteria":
        task["acceptanceCriteria"].append(item)
    elif section == "Requirements":
        task.setdefault("requirements", []).append(parsed_or_raw(item))
    elif section == "Obligations":
        found = OBLIGATION_ID.search(item)
        task.setdefault("obligations", []).append(found.group(0) if found else item)
    elif section == "Interfaces":
        key, _, value = item.partition(":")
        if key.strip() in ("consumes", "produces") and value.strip() and value.strip() != "none":
            task["interfaces"][key.strip()] = value.strip()

if not tasks:
    print("plan-tasks: no '### task-NNN:' blocks in %s" % plan, file=sys.stderr)
    sys.exit(1)

for t in tasks:
    if t["blockedBy"] is None:
        t["blockedBy"] = table.get(t["id"], [])
    if not t["readFirst"]:
        del t["readFirst"]
    if not t["interfaces"]:
        del t["interfaces"]

print(json.dumps(tasks, indent=2))
PY
