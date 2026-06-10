"""planlib.py — shared plan (tasks.json) validation and ordering.

A plan is the contract between the spec compiler (layer 2) and the supervisor
(layer 3). Keeping validation in one place means a plan that compiles is a plan
that runs.

Plan schema:
{
  "spec": "SPEC.md",                # provenance (optional)
  "fleet_budget_usd": 20.0,
  "base_branch": "main",            # optional; supervisor defaults to current
  "tasks": [
    {
      "id": "short-slug",           # unique, [a-z0-9-]
      "prompt": "...",              # scoped task prompt (goal, files in scope, don'ts)
      "verify": "pytest tests/x -q",# exits 0 only when this task is truly done
      "protected": ["tests/"],      # paths the agent must not modify (verifier integrity)
      "budget_usd": 4.0,
      "max_iterations": 10,
      "deps": ["other-task-id"],
      "mode": "fresh",              # or "continue"
      "allowed_tools": "Read,Edit,Bash"
    }
  ]
}
"""

from __future__ import annotations

import re
from collections import deque

ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{1,63}$")


def validate_plan(plan: dict) -> list[str]:
    """Return a list of human-readable problems. Empty list == valid."""
    errs: list[str] = []
    tasks = plan.get("tasks")
    if not isinstance(tasks, list) or not tasks:
        return ["plan has no 'tasks' list (or it is empty)"]
    if not isinstance(plan.get("fleet_budget_usd", 1.0), (int, float)) or plan.get("fleet_budget_usd", 1.0) <= 0:
        errs.append("fleet_budget_usd must be a positive number")

    ids = set()
    for i, t in enumerate(tasks):
        where = f"task[{i}]({t.get('id', '?')})"
        tid = t.get("id", "")
        if not isinstance(tid, str) or not ID_RE.match(tid):
            errs.append(f"{where}: id must match {ID_RE.pattern}")
        elif tid in ids:
            errs.append(f"{where}: duplicate id '{tid}'")
        ids.add(tid)
        if not isinstance(t.get("prompt"), str) or len(t.get("prompt", "")) < 20:
            errs.append(f"{where}: prompt missing or too thin to run unattended")
        if not isinstance(t.get("verify"), str) or not t.get("verify", "").strip():
            errs.append(f"{where}: verify command is required — a task without a "
                        f"done-condition cannot be looped safely")
        b = t.get("budget_usd", 0)
        if not isinstance(b, (int, float)) or b <= 0:
            errs.append(f"{where}: budget_usd must be > 0")
        if t.get("mode", "fresh") not in ("fresh", "continue"):
            errs.append(f"{where}: mode must be 'fresh' or 'continue'")
        if not isinstance(t.get("deps", []), list):
            errs.append(f"{where}: deps must be a list")
        if not isinstance(t.get("protected", []), list):
            errs.append(f"{where}: protected must be a list of paths")

    for t in tasks:
        for d in t.get("deps", []) or []:
            if d not in ids:
                errs.append(f"task '{t.get('id')}': unknown dep '{d}'")
            if d == t.get("id"):
                errs.append(f"task '{t.get('id')}': depends on itself")

    order, cycle = topo_order(tasks)
    if cycle:
        errs.append(f"dependency cycle involving: {', '.join(sorted(cycle))}")
    return errs


def topo_order(tasks: list[dict]) -> tuple[list[str], set[str]]:
    """Kahn's algorithm. Returns (ordered ids, ids stuck in a cycle)."""
    ids = [t["id"] for t in tasks if "id" in t]
    deps = {t["id"]: set(d for d in (t.get("deps") or []) if d in ids) for t in tasks if "id" in t}
    indeg = {i: len(deps[i]) for i in ids}
    rdeps: dict[str, set] = {i: set() for i in ids}
    for i in ids:
        for d in deps[i]:
            rdeps[d].add(i)
    q = deque(sorted(i for i in ids if indeg[i] == 0))
    order = []
    while q:
        n = q.popleft()
        order.append(n)
        for m in sorted(rdeps[n]):
            indeg[m] -= 1
            if indeg[m] == 0:
                q.append(m)
    return order, {i for i in ids if i not in order}
