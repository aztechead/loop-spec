#!/usr/bin/env bash
# Check that every SPEC "### Good Enough" success criterion has real coverage in PLAN.
#
# VERIFY's deterministic acceptance gate runs the criteria recorded in PLAN.md --
# a criterion that SPEC promises but PLAN drops is therefore invisible to every
# downstream gate (VERIFY passes green, ITERATE's judge sees a green floor). This
# check closes the SPEC -> PLAN handoff the same way decision-coverage.sh closes
# the <decisions> handoff.
#
# Two dispatch formats, selected by the feature's persisted requirementsContract
# (never guessed from the artifact -- docs/loop-spec/features/release-7-0/SPEC.md,
# "Coverage is a relation to the actual dispatch plan"):
#
#   legacy (no --feature-dir, or a contract whose format is not "v1")
#     A criterion is covered by a `- <criterion text> -> task-NNN` bullet anywhere in
#     PLAN.md (reflowed across lines like today); plain narrative mentioning the same
#     words is not a mapping and does not count (a "notes-only" copy). When PLAN.md
#     also declares a task registry (`### task-NNN:` headings or `| task-NNN |` DAG
#     rows), a mapping bullet naming a task outside that registry is a dangling
#     reference and fails the gate even though the bullet's own text matches SPEC.
#
#   v1 (--feature-dir DIR --tasks TASKS.json, contract format "v1")
#     The `## Spec coverage` bullets above are a derived explanation, never the
#     source: real coverage comes from each task's `requirements`/`obligations`
#     (lib/plan-tasks.sh extract), checked against the live SPEC inventory
#     (lib/requirements.py load_inventory) -- every requirement reference must name
#     a current requirement/scenario at its current revision, every obligation
#     reference must be declared under SPEC `## Constraints`, and every task must
#     name at least one of the two (no free-text exemption). A `## Spec coverage`
#     bullet that still names a task absent from tasks.json is flagged the same way
#     as the legacy dangling case, because the summary must stay regenerable.
#
# Usage: criteria-coverage.sh <spec-path> <plan-path> [--feature-dir DIR --tasks TASKS.json]
#
# Exit codes:
#   0  all Good Enough criteria covered, no dangling reference (or no section -- skipped)
#   1  a criterion is uncovered, a mapping is dangling, or a v1 relation check fails
#
# Prints `FLAG <file>:<line>: <message>` lines (v1 mode) or a plain uncovered/dangling
# list (legacy mode, unchanged shape) on exit 1.
# Prints "skipped: ..." to stderr and exits 0 when SPEC has no Good Enough section.
# Fail-open: if SPEC cannot be read, exits 0 with a warning to stderr.
set -uo pipefail

usage() { echo "usage: criteria-coverage.sh <spec-path> <plan-path> [--feature-dir DIR --tasks TASKS.json]" >&2; }

spec_path="${1:-}"
plan_path="${2:-}"
[[ -n "$spec_path" && -n "$plan_path" ]] || { usage; exit 1; }
shift 2

feature_dir=""
tasks_path=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --feature-dir) feature_dir="${2:-}"; shift ;;
    --tasks) tasks_path="${2:-}"; shift ;;
    *) usage; exit 1 ;;
  esac
  shift
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHONPATH="$SCRIPT_DIR${PYTHONPATH:+:$PYTHONPATH}" python3 - "$spec_path" "$plan_path" "$feature_dir" "$tasks_path" <<'PY'
import json
import re
import sys

spec_path, plan_path, feature_dir, tasks_path = sys.argv[1:5]


def norm(text):
    return " ".join(text.split())


try:
    with open(spec_path, encoding="utf-8", errors="replace") as stream:
        spec_content = stream.read()
except OSError:
    print("skipped: spec file not readable: %s" % spec_path, file=sys.stderr)
    sys.exit(0)

heading = re.search(r"^###[ \t]+Good Enough[ \t]*$", spec_content, re.M)
if not heading:
    print("skipped: no Good Enough section in spec", file=sys.stderr)
    sys.exit(0)

# graph/cycle.graph.json's plan-node egress runs this exact 2-arg form on every
# cycle, legacy or v1, with no feature-dir to look up the persisted contract (task-005
# is scoped to lib/criteria-coverage.sh, lib/plan-exit-gate.sh and four other files --
# not the graph). A v1 SPEC still declares its own format explicitly in frontmatter,
# so that declaration -- not a guess -- is enough to know positional "-> task-NNN"
# coverage does not apply: a v1 PLAN's tasks name Requirements/Obligations JSON, not
# that bullet shape, and lib/plan-exit-gate.sh runs the real relation check below with
# the feature-dir this call does not have.
if not feature_dir and not tasks_path and re.search(r"^requirements_version:", spec_content, re.M):
    print("skipped: v1 SPEC -- coverage is the reviewed task relation "
          "(lib/plan-exit-gate.sh), not positional '-> task-NNN' bullets", file=sys.stderr)
    sys.exit(0)
tail = spec_content[heading.end():]
next_heading = re.search(r"^#{1,6}[ \t]", tail, re.M)
block = tail[:next_heading.start()] if next_heading else tail

criteria = []
for line in block.splitlines():
    stripped = line.strip()
    if not stripped.startswith("-"):
        continue
    entry = stripped[1:].strip()
    for prefix in ("[ ] ", "[x] ", "[X] "):
        if entry.startswith(prefix):
            entry = entry[len(prefix):]
            break
    if entry:
        criteria.append(entry)

try:
    with open(plan_path, encoding="utf-8", errors="replace") as stream:
        plan_lines = stream.read().splitlines()
except OSError:
    plan_lines = []

# Reflow: a bullet line ('- ...') absorbs the non-bullet, non-blank lines that follow
# it (a criterion a planner wraps across two lines, case R in the test suite) so a
# wrapped mapping still parses as one bullet.
bullets = []
current = None
for line in plan_lines:
    stripped = line.strip()
    if stripped.startswith("-"):
        if current is not None:
            bullets.append(current)
        current = stripped[1:].strip()
    elif not stripped:
        if current is not None:
            bullets.append(current)
        current = None
    elif current is not None:
        current += " " + stripped
if current is not None:
    bullets.append(current)

MAPPING = re.compile(r"^(.*?)\s*->\s*(task-[0-9]+)\s*$")
known_tasks = set(re.findall(r"^###[ \t]+(task-[0-9]+):", "\n".join(plan_lines), re.M))
known_tasks |= set(re.findall(r"^\|\s*(task-[0-9]+)\s*\|", "\n".join(plan_lines), re.M))

mapped_texts = []
dangling = []
for bullet in bullets:
    match = MAPPING.match(bullet)
    if not match:
        continue
    text, task_id = match.group(1), match.group(2)
    for prefix in ("[ ] ", "[x] ", "[X] "):
        if text.startswith(prefix):
            text = text[len(prefix):]
            break
    mapped_texts.append(norm(text))
    if known_tasks and task_id not in known_tasks:
        dangling.append((task_id, bullet))


def v1_contract():
    if not feature_dir or not tasks_path:
        return None
    from feature_read import load_state
    contract = load_state(feature_dir).get("requirementsContract")
    return contract if contract and contract.get("format") == "v1" else None


contract = v1_contract()
if contract is None:
    # --- legacy: today's positional coverage, now requiring a real mapping bullet ---
    uncovered = [c for c in criteria if not any(norm(c) in mt for mt in mapped_texts)]
    failed = False
    if uncovered:
        print("Uncovered Good Enough criteria:")
        for c in uncovered:
            print("  - %s" % c)
        failed = True
    if dangling:
        print("Dangling task references in PLAN coverage mapping:")
        for task_id, bullet in dangling:
            print("  - %s: %s" % (task_id, bullet))
        failed = True
    sys.exit(1 if failed else 0)

# --- v1: the reviewed task relation is the source; the coverage bullets above (if
# present) are a derived explanation checked only for dangling task references. ---
from requirements import load_inventory
from feature_read import load_state

state = load_state(feature_dir)
try:
    inventory = load_inventory(spec_path, state)
except (OSError, ValueError) as exc:
    print("FLAG %s:1: cannot read requirements inventory: %s" % (spec_path, exc))
    sys.exit(1)

try:
    with open(tasks_path, encoding="utf-8") as stream:
        tasks = json.load(stream)
except (OSError, ValueError) as exc:
    print("FLAG %s:0: cannot read tasks: %s" % (tasks_path, exc))
    sys.exit(1)
if not isinstance(tasks, list):
    print("FLAG %s:0: tasks must be a JSON array" % tasks_path)
    sys.exit(1)

task_ids = {t.get("id") for t in tasks if isinstance(t, dict)}
inventory_by_id = {r["id"]: r for r in inventory["requirements"]}
obligation_ids = {o["id"] for o in inventory["obligations"]}


def line_for(needle, task_id):
    """Best-effort file/line for a FLAG: the line naming `needle`, else the task's
    own heading line, else 0 -- there is no parsed location once a task is only in
    tasks.json, so this re-scans PLAN.md text the way plan-adherence.sh already does."""
    for i, text in enumerate(plan_lines):
        if needle and needle in text:
            return i + 1
    for i, text in enumerate(plan_lines):
        if re.match(r"^###[ \t]+" + re.escape(task_id) + r"\b", text.strip()):
            return i + 1
    return 0


failed = False
covered = set()
for task in tasks:
    if not isinstance(task, dict):
        continue
    tid = task.get("id", "?")
    requirements = [r for r in (task.get("requirements") or []) if isinstance(r, dict)]
    obligations = [o for o in (task.get("obligations") or []) if isinstance(o, str)]
    if not requirements and not obligations:
        print("FLAG %s:%d: %s carries no requirements or obligations -- a v1 cycle "
              "has no free-text coverage exemption" % (plan_path, line_for(tid, tid), tid))
        failed = True
    for ref in requirements:
        gid = ref.get("requirement")
        entry = inventory_by_id.get(gid)
        line = line_for(gid or "", tid)
        if entry is None:
            print("FLAG %s:%d: %s references unknown requirement %s" % (plan_path, line, tid, gid))
            failed = True
            continue
        if ref.get("revision") != entry["revision"]:
            print("FLAG %s:%d: %s carries a stale revision for %s" % (plan_path, line, tid, gid))
            failed = True
        scenario_ids = {s["id"] for s in entry["scenarios"]}
        for sid in ref.get("scenarios") or []:
            if sid not in scenario_ids:
                print("FLAG %s:%d: %s references %s/%s, a scenario the SPEC inventory lacks"
                      % (plan_path, line, tid, gid, sid))
                failed = True
            else:
                covered.add((gid, sid))
    for oid in obligations:
        if oid not in obligation_ids:
            print("FLAG %s:%d: %s references obligation %s not declared under SPEC '## Constraints'"
                  % (plan_path, line_for(oid, tid), tid, oid))
            failed = True

for task_id, bullet in dangling:
    if task_id not in task_ids:
        print("FLAG %s:0: dangling task reference %s in '## Spec coverage' mapping: %s"
              % (plan_path, task_id, bullet))
        failed = True

for requirement in inventory["requirements"]:
    for scenario in requirement["scenarios"]:
        if (requirement["id"], scenario["id"]) not in covered:
            line = scenario["location"]["line"]
            print("FLAG %s:%d: %s/%s has no task Requirements coverage"
                  % (spec_path, line, requirement["id"], scenario["id"]))
            failed = True

sys.exit(1 if failed else 0)
PY
