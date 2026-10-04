"""Where a run's files live, and the one place that reads and writes them.

A run lives in `<project>/.loop-spec/runs/<slug>/`:

    state.json    what the program records: base, branch, task status, verify, PR
    spec.json     written by the lead: title, goal, criteria (each with an optional check)
    plan.json     written by the lead: prepare command and the task DAG
    work/         worktree on the feature branch, where finished tasks are merged
    tasks/<id>/   one worktree per started task
    verify/       the detached checkout verify runs in
    result.json   the run's final result, 7.x's schema-1 record; its presence means the run is over
    events.jsonl  the phase stream's records (phases.py)

A `Run` lives for one command, and no command writes spec.json or plan.json, so they
are read once.
"""
import json
import os
import re
import textwrap
from datetime import datetime, timezone
from functools import cached_property
from pathlib import Path
from typing import Callable

from loop_spec import dag
from loop_spec.errors import LoopSpecError

RUNS_DIR = Path(".loop-spec") / "runs"
KINDS = ("cycle", "micro", "debug", "revise")
RESULT_STATUSES = ("completed", "no-change", "escalated", "failed")


def slugify(text: str) -> str:
    words = re.findall(r"[a-z0-9]+", text.lower())
    return "-".join(words)[:40].rstrip("-") or "run"


def first_free(name: str, taken: Callable[[str], bool]) -> str:
    """`name`, or `name-2`, `name-3`, ... the first one `taken` says is free."""
    candidate, n = name, 1
    while taken(candidate):
        n += 1
        candidate = f"{name}-{n}"
    return candidate


def first_line(text: str, width: int) -> str:
    lines = text.strip().splitlines()
    return textwrap.shorten(lines[0], width, placeholder="...") if lines else ""


def write_json(path: Path, data) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True, ensure_ascii=False) + "\n")
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
        self.verify_dir = self.dir / "verify"
        self.state: dict = read_json(self.state_path, "state") or {}

    def exists(self) -> bool:
        return self.state_path.is_file()

    def save(self) -> None:
        self.state["updatedAt"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        write_json(self.state_path, self.state)

    @property
    def mode(self) -> str:
        """`autonomous` when the host says so (LOOP_SPEC_MODE) or the run was started so."""
        if os.environ.get("LOOP_SPEC_MODE") == "autonomous":
            return "autonomous"
        return self.state.get("mode", "interactive")

    @property
    def result(self) -> dict | None:
        return read_json(self.result_path, "result")

    def task_dir(self, task_id: str) -> Path:
        return self.dir / "tasks" / task_id

    def task_branch(self, task_id: str) -> str:
        return f"loop-spec-task/{self.slug}/{task_id}"

    @cached_property
    def spec(self) -> dict | None:
        return read_json(self.spec_path, "spec")

    @cached_property
    def plan(self) -> dict | None:
        return read_json(self.plan_path, "plan")

    @cached_property
    def tasks(self) -> list[dict]:
        """The plan's tasks, or [] before there is a plan. Raises when the plan is not a usable DAG."""
        if self.plan is None:
            return []
        tasks = self.plan.get("tasks") if isinstance(self.plan, dict) else None
        if not isinstance(tasks, list) or not all(isinstance(t, dict) for t in tasks):
            raise LoopSpecError(f"{self.plan_path} needs a `tasks` list of objects", "see the plan.json shape in the loop-spec skill")
        found = dag.problems(tasks)
        if found:
            raise LoopSpecError("plan.json is not a usable task graph: " + "; ".join(found), f"fix {self.plan_path}")
        return tasks

    def task(self, task_id: str) -> dict:
        for t in self.tasks:
            if t["id"] == task_id:
                return t
        raise LoopSpecError(f"{task_id} is not a task in {self.plan_path.name}", "run `loop-spec status` for the task list")

    def statuses(self) -> dict[str, str]:
        return {tid: t["status"] for tid, t in self.state.get("tasks", {}).items()}

    def set_task(self, task_id: str, status: str, note: str | None = None) -> None:
        self.state.setdefault("tasks", {})[task_id] = {"status": status, "note": note}

    def verified_at(self, head: str | None) -> bool:
        verify = self.state.get("verify") or {}
        return bool(verify.get("passed")) and head is not None and verify.get("sha") == head

    def phase(self, head: str | None) -> str:
        """Where the run is, derived from its files: spec, plan, execute, verify, iterate, deliver, or
        done, 7.x's phase names. Delivering covers the PR's CI and review feedback too."""
        if self.result_path.is_file():
            return "done"
        if self.spec is None:
            return "spec"
        if not self.tasks:
            return "plan"
        if not dag.all_done(self.tasks, self.statuses()):
            return "execute"
        if not self.verified_at(head):
            return "verify"
        return "deliver" if (self.state.get("iterate") or {}).get("sha") == head else "iterate"

    def finish(self, result: dict) -> None:
        """Record the run's result (legacy.record builds it); its presence ends the run."""
        write_json(self.result_path, result)

def all_runs(project: Path) -> list[Run]:
    root = project / RUNS_DIR
    runs = [Run(project, d.name) for d in root.iterdir() if (d / "state.json").is_file()] if root.is_dir() else []
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
    open_runs = [r for r in all_runs(project) if not r.result_path.is_file()]
    if len(open_runs) == 1:
        return open_runs[0]
    names = ", ".join(r.slug for r in open_runs) or "none"
    raise LoopSpecError(f"say which run with --slug (open runs: {names})", "run `loop-spec status` to list runs")
