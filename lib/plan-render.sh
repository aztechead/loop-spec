#!/usr/bin/env bash
# plan-render.sh - Render PLAN.md's `## Task DAG` and `## Tasks` sections from tasks.json.
#
# Why: those two sections are the structured half of the plan, and until now the planner
# hand-wrote them as markdown while also emitting the same tasks as JSON. On a live run
# (evals/findings-2026-09-07-tf-meldn.md) that meant a full re-dispatch when the prose
# shape missed the template, and every later fix applied twice, once per file. Rendering
# makes tasks.json the single source: the shape the artifact lint parses is produced,
# not checked, and a fix to a task is one edit.
#
# Usage:
#   plan-render.sh render --tasks <tasks.json> --plan <PLAN.md>
#     Replaces the two sections in place (appends them before `## Test strategy`, or at
#     the end, when absent). Every other section is preserved byte-for-byte.
#   plan-render.sh render --tasks <tasks.json>          prints the two sections to stdout
#   plan-render.sh prose-lines --plan <PLAN.md>         prints how many non-blank lines lie
#     OUTSIDE the rendered span, so the prose-pruning pass can be skipped on a plan whose
#     bulk is rendered task blocks (a live 377-line plan paid a pruner for all of it).
#
# Task fields read: id, subject|title, goal, files[], read_first[], interfaces{consumes,
# produces}, blockedBy[], verifyCommand, expected, acceptanceCriteria[], steps[], scope.
# Exit: 0 rendered, 1 unreadable or non-array tasks.json, 2 usage.
set -uo pipefail

tasks=""; plan=""; mode=render
while [[ $# -gt 0 ]]; do
  case "$1" in
    render) ;;
    prose-lines) mode=prose ;;
    --tasks) tasks="${2:-}"; shift ;;
    --plan) plan="${2:-}"; shift ;;
    *) echo "usage: plan-render.sh render --tasks <tasks.json> [--plan <PLAN.md>]" >&2; exit 2 ;;
  esac
  shift
done
if [[ "$mode" == "prose" ]]; then
  [[ -n "$plan" ]] || { echo "usage: plan-render.sh prose-lines --plan <PLAN.md>" >&2; exit 2; }
  [[ -f "$plan" ]] || { echo "plan-render: plan file not found: $plan" >&2; exit 1; }
  awk 'BEGIN{r=0} /^## (Task DAG|Tasks)[[:space:]]*$/{r=1; next} r && /^## /{r=0} !r && NF{n++} END{print n+0}' "$plan"
  exit 0
fi
[[ -n "$tasks" ]] || { echo "usage: plan-render.sh render --tasks <tasks.json> [--plan <PLAN.md>]" >&2; exit 2; }
[[ -f "$tasks" ]] || { echo "plan-render: tasks file not found: $tasks" >&2; exit 1; }

python3 - "$tasks" "$plan" <<'PY'
import json
import re
import sys

tasks_path, plan_path = sys.argv[1], sys.argv[2]
try:
    with open(tasks_path, encoding="utf-8") as fh:
        data = json.load(fh)
except (OSError, ValueError) as exc:
    print("plan-render: cannot read %s: %s" % (tasks_path, exc), file=sys.stderr)
    raise SystemExit(1)
if isinstance(data, dict) and isinstance(data.get("tasks"), list):
    data = data["tasks"]
if not isinstance(data, list):
    print("plan-render: %s is not a JSON array of tasks" % tasks_path, file=sys.stderr)
    raise SystemExit(1)


def strs(value):
    if isinstance(value, str):
        return [value] if value.strip() else []
    if isinstance(value, list):
        return [str(v) for v in value if str(v).strip()]
    return []


def subject(t):
    return str(t.get("subject") or t.get("title") or t.get("brief") or "").strip()


out = ["## Task DAG", "", "| ID | Subject | BlockedBy | Files | Est scope |",
       "|----|---------|-----------|-------|-----------|"]
for t in data:
    blocked = ", ".join(strs(t.get("blockedBy"))) or "-"
    files = ", ".join("`%s`" % f for f in strs(t.get("files"))) or "-"
    scope = str(t.get("scope") or t.get("estScope") or "small")
    out.append("| %s | %s | %s | %s | %s |" % (t.get("id", ""), subject(t).replace("|", "/"), blocked, files, scope))
out += ["", "## Tasks", ""]
for t in data:
    tid = t.get("id", "")
    out.append("### %s: %s" % (tid, subject(t)))
    out.append("")
    goal = str(t.get("goal") or "").strip()
    if goal:
        out += ["**Goal:** " + goal, ""]
    out.append("**Files:**")
    out += ["- " + f for f in strs(t.get("files"))] or ["- none"]
    out.append("")
    rf = strs(t.get("read_first") or t.get("readFirst"))
    if rf:
        out += ["**read_first:**"] + ["- " + r for r in rf] + [""]
    iface = t.get("interfaces") if isinstance(t.get("interfaces"), dict) else {}
    out += ["**Interfaces:**",
            "- consumes: " + str(iface.get("consumes") or "none"),
            "- produces: " + str(iface.get("produces") or "none"), ""]
    blocked = strs(t.get("blockedBy"))
    if blocked:
        out += ["**blockedBy:** " + ", ".join(blocked), ""]
    cmd = str(t.get("verifyCommand") or "").strip()
    expected = str(t.get("expected") or "exit 0").strip()
    out += ["**Verify:** `%s` -> %s" % (cmd or "true", expected), ""]
    out.append("**Acceptance criteria:**")
    out += ["- [ ] " + c for c in strs(t.get("acceptanceCriteria"))] or ["- [ ] " + (cmd or "true") + " exits 0"]
    out.append("")
    steps = strs(t.get("steps"))
    if steps:
        out += ["**Steps (TDD where applicable):**", ""]
        out += ["- [ ] Step %d: %s" % (i + 1, s) for i, s in enumerate(steps)]
        out.append("")
rendered = "\n".join(out).rstrip("\n") + "\n"

if not plan_path:
    sys.stdout.write(rendered)
    raise SystemExit(0)

try:
    with open(plan_path, encoding="utf-8") as fh:
        text = fh.read()
except OSError as exc:
    print("plan-render: cannot read %s: %s" % (plan_path, exc), file=sys.stderr)
    raise SystemExit(1)

# The rendered span runs from `## Task DAG` (or `## Tasks` when the table is absent) to
# the next `## ` heading that is neither of them.
lines = text.split("\n")
start = end = None
for i, line in enumerate(lines):
    if start is None and line.rstrip() in ("## Task DAG", "## Tasks"):
        start = i
    elif start is not None and line.startswith("## ") and line.rstrip() not in ("## Task DAG", "## Tasks"):
        end = i
        break
if start is None:
    anchor = next((i for i, l in enumerate(lines) if l.rstrip() == "## Test strategy"), None)
    if anchor is None:
        new_text = text.rstrip("\n") + "\n\n" + rendered
    else:
        new_text = "\n".join(lines[:anchor]).rstrip("\n") + "\n\n" + rendered + "\n" + "\n".join(lines[anchor:])
else:
    tail = lines[end:] if end is not None else []
    new_text = "\n".join(lines[:start]).rstrip("\n") + "\n\n" + rendered + ("\n" + "\n".join(tail) if tail else "")
with open(plan_path, "w", encoding="utf-8") as fh:
    fh.write(new_text)
print("plan-render: rendered %d task(s) into %s" % (len(data), plan_path))
PY
