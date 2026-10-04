"""The plan's task graph: problems with it, which tasks are ready, and the waves it runs in.

Pure functions over the `tasks` list from plan.json and a {task id: status} map.
A status is `todo`, `doing`, `done`, or `blocked`; a task missing from the map is `todo`.
"""

STATUSES = ("todo", "doing", "done", "blocked")


def problems(tasks: list[dict]) -> list[str]:
    """What makes this list not a usable DAG: missing or duplicate ids, unknown
    dependencies, and cycles. Empty when the graph is sound."""
    found, ids = [], [t.get("id") for t in tasks]
    if not tasks:
        found.append("the plan has no tasks")
    for i, tid in enumerate(ids):
        if not tid:
            found.append(f"task #{i + 1} has no id")
        elif ids.count(tid) > 1 and ids.index(tid) == i:
            found.append(f"task id {tid} is used more than once")
    known = set(ids)
    for t in tasks:
        for dep in t.get("dependsOn", []):
            if dep not in known:
                found.append(f"{t.get('id')} depends on {dep}, which is not in the plan")
    cycle = _cycle(tasks)
    if cycle:
        found.append("dependency cycle: " + " -> ".join(cycle))
    return found


def _cycle(tasks: list[dict]) -> list[str]:
    deps = {t.get("id"): t.get("dependsOn", []) for t in tasks}
    finished: set[str] = set()

    def visit(node: str, path: list[str]) -> list[str]:
        if node in path:
            return path[path.index(node):] + [node]
        if node in finished or node not in deps:
            return []
        for dep in deps[node]:
            found = visit(dep, path + [node])
            if found:
                return found
        finished.add(node)
        return []

    for node in deps:
        found = visit(node, [])
        if found:
            return found
    return []


def status_of(task_id: str, statuses: dict[str, str]) -> str:
    return statuses.get(task_id, "todo")


def ready(tasks: list[dict], statuses: dict[str, str]) -> list[dict]:
    """Tasks still `todo` whose every dependency is `done`, in plan order."""
    return [t for t in tasks
            if status_of(t["id"], statuses) == "todo"
            and all(status_of(d, statuses) == "done" for d in t.get("dependsOn", []))]


def waiting_on(task: dict, statuses: dict[str, str]) -> list[str]:
    return [d for d in task.get("dependsOn", []) if status_of(d, statuses) != "done"]


def waves(tasks: list[dict]) -> list[list[str]]:
    """Task ids grouped so each group depends only on earlier groups. Assumes no cycle."""
    remaining = {t["id"]: set(t.get("dependsOn", [])) for t in tasks}
    done: set[str] = set()
    out = []
    while remaining:
        wave = [tid for tid, deps in remaining.items() if deps <= done]
        if not wave:
            break
        out.append(wave)
        done.update(wave)
        for tid in wave:
            del remaining[tid]
    return out


def uncovered(criteria: list[dict], tasks: list[dict]) -> list[str]:
    """Spec criterion ids no task names in its `criteria`."""
    covered = {c for t in tasks for c in t.get("criteria", [])}
    return [c["id"] for c in criteria if c.get("id") and c["id"] not in covered]
