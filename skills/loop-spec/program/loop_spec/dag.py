"""The plan's task graph: what is wrong with it, and which tasks are ready.

Pure functions over the `tasks` list from plan.json and a {task id: status} map.
A status is `todo`, `doing`, `done`, or `blocked`; a task missing from the map is `todo`.
"""
from collections import Counter
from graphlib import CycleError, TopologicalSorter

STATUSES = ("todo", "doing", "done", "blocked")


def problems(tasks: list[dict]) -> list[str]:
    """What makes this list not a usable DAG: missing or duplicate ids, unknown
    dependencies, and cycles. Empty when the graph is sound."""
    if not tasks:
        return ["the plan has no tasks"]
    found = [f"task #{i + 1} has no id" for i, t in enumerate(tasks) if not t.get("id")]
    counts = Counter(t.get("id") for t in tasks if t.get("id"))
    found += [f"task id {tid} is used more than once" for tid, n in counts.items() if n > 1]
    found += [f"{t.get('id')} depends on {dep}, which is not in the plan"
              for t in tasks for dep in t.get("dependsOn", []) if dep not in counts]
    if not found:  # graphlib would add an unknown dependency as a new node, so check those first
        try:
            TopologicalSorter({t["id"]: t.get("dependsOn", []) for t in tasks}).prepare()
        except CycleError as exc:
            found.append("dependency cycle: " + " -> ".join(reversed(exc.args[1])))
    return found


def status_of(task_id: str, statuses: dict[str, str]) -> str:
    return statuses.get(task_id, "todo")


def ready(tasks: list[dict], statuses: dict[str, str]) -> list[dict]:
    """Tasks still `todo` whose every dependency is `done`, in plan order."""
    return [t for t in tasks
            if status_of(t["id"], statuses) == "todo"
            and all(status_of(d, statuses) == "done" for d in t.get("dependsOn", []))]


def all_done(tasks: list[dict], statuses: dict[str, str]) -> bool:
    return all(status_of(t["id"], statuses) == "done" for t in tasks)


def waiting_on(task: dict, statuses: dict[str, str]) -> list[str]:
    return [d for d in task.get("dependsOn", []) if status_of(d, statuses) != "done"]


def uncovered(criteria: list[dict], tasks: list[dict]) -> list[str]:
    """Spec criterion ids no task names in its `criteria`."""
    covered = {c for t in tasks for c in t.get("criteria", [])}
    return [c["id"] for c in criteria if c.get("id") and c["id"] not in covered]
