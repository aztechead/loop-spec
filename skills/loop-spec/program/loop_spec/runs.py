"""Where a run's files live, and the one place that reads and writes them.

A run lives in `<project>/.loop-spec/runs/<slug>/`:

    state.json    what the program records: base, branch, task status, verify, PR, result
    spec.json     written by the agent: title, goal, criteria (each with an optional check)
    plan.json     written by the agent: prepare command and the task DAG
    work/         worktree on the feature branch, where finished tasks are merged
    tasks/<id>/   one worktree per started task
    result.json   the run's final result, mirrored to runs/last-result.json
"""
import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path

from loop_spec import dag
from loop_spec.errors import LoopSpecError

RUNS_DIR = Path(".loop-spec") / "runs"
KINDS = ("cycle", "micro", "debug", "revise")
RESULT_STATUSES = ("completed", "no-change", "escalated", "failed")


def now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def slugify(text: str) -> str:
    words = re.findall(r"[a-z0-9]+", text.lower())
    return "-".join(words)[:40].rstrip("-") or "run"


def write_json(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2) + "\n")
    os.replace(tmp, path)


def read_json(path: Path, what: str):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return None
    except json.JSONDecodeError as exc:
        raise LoopSpecError(f"{what} at {path} is not valid JSON: {exc}", f"fix {path.name} and run the command again")


class Run:
    def __init__(self, project: Path, slug: str) -> None:
        self.project = project
        self.slug = slug
        self.dir = project / RUNS_DIR / slug
        self.state_path = self.dir / "state.json"
        self.spec_path = self.dir / "spec.json"
        self.plan_path = self.dir / "plan.json"
        self.result_path = self.dir / "result.json"
        self.work = self.dir / "work"
        self.state: dict = read_json(self.state_path, "state") or {}

    def exists(self) -> bool:
        return self.state_path.is_file()

    def save(self) -> None:
        self.state["updatedAt"] = now()
        write_json(self.state_path, self.state)

    def task_dir(self, task_id: str) -> Path:
        return self.dir / "tasks" / task_id

    def task_branch(self, task_id: str) -> str:
        return f"loop-spec-task/{self.slug}/{task_id}"

    def spec(self) -> dict | None:
        return read_json(self.spec_path, "spec")

    def plan(self) -> dict | None:
        return read_json(self.plan_path, "plan")

    def tasks(self) -> list[dict]:
        """The plan's tasks, or [] before there is a plan. Raises when the plan is not a usable DAG."""
        plan = self.plan()
        if plan is None:
            return []
        tasks = plan.get("tasks") if isinstance(plan, dict) else None
        if not isinstance(tasks, list) or not all(isinstance(t, dict) for t in tasks):
            raise LoopSpecError(f"{self.plan_path} needs a `tasks` list of objects", "see the plan.json shape in the loop-spec skill")
        found = dag.problems(tasks)
        if found:
            raise LoopSpecError("plan.json is not a usable task graph: " + "; ".join(found), f"fix {self.plan_path}")
        return tasks

    def statuses(self) -> dict[str, str]:
        return {tid: t["status"] for tid, t in self.state.get("tasks", {}).items()}

    def task_record(self, task_id: str) -> dict:
        return self.state.setdefault("tasks", {}).setdefault(task_id, {"status": "todo"})

    def phase(self, feature_head: str | None) -> str:
        """Where the run is, derived from its files: spec, plan, execute, verify, deliver, or done."""
        if self.state.get("result"):
            return "done"
        if self.spec() is None:
            return "spec"
        tasks = self.tasks()
        if not tasks:
            return "plan"
        statuses = self.statuses()
        if any(dag.status_of(t["id"], statuses) != "done" for t in tasks):
            return "execute"
        verify = self.state.get("verify") or {}
        if not verify.get("passed") or verify.get("sha") != feature_head:
            return "verify"
        return "deliver"

    def finish(self, status: str, summary: str, extra: dict | None = None) -> dict:
        if status not in RESULT_STATUSES:
            raise LoopSpecError(f"unknown result status {status!r}", "use one of " + ", ".join(RESULT_STATUSES))
        verify = self.state.get("verify") or {}
        result = {
            "schema": 8,
            "slug": self.slug,
            "kind": self.state.get("kind"),
            "status": status,
            "summary": summary,
            "branch": self.state.get("branch"),
            "prUrl": (self.state.get("pr") or {}).get("url"),
            "verifiedSha": verify.get("sha") if verify.get("passed") else None,
            "finishedAt": now(),
            **(extra or {}),
        }
        self.state["result"] = result
        self.save()
        write_json(self.result_path, result)
        write_json(self.dir.parent / "last-result.json", result)
        return result


def all_runs(project: Path) -> list[Run]:
    root = project / RUNS_DIR
    if not root.is_dir():
        return []
    runs = [Run(project, d.name) for d in sorted(root.iterdir()) if (d / "state.json").is_file()]
    return sorted(runs, key=lambda r: r.state.get("updatedAt", ""), reverse=True)


def find(project: Path, slug: str | None, cwd: Path) -> Run:
    """The run a command means: --slug, else the run whose directory holds cwd, else the only open run."""
    if slug:
        run = Run(project, slug)
        if not run.exists():
            raise LoopSpecError(f"no run named {slug}", "run `loop-spec status` to list runs")
        return run
    runs_root = (project / RUNS_DIR).resolve()
    here = cwd.resolve()
    if runs_root in here.parents:
        return Run(project, here.relative_to(runs_root).parts[0])
    open_runs = [r for r in all_runs(project) if not r.state.get("result")]
    if len(open_runs) == 1:
        return open_runs[0]
    names = ", ".join(r.slug for r in open_runs) or "none"
    raise LoopSpecError(f"say which run with --slug (open runs: {names})", "run `loop-spec status` to list runs")
