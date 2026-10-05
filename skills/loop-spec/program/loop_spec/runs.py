"""Where a run's files live, and the one place that reads and writes them.

A run lives in `<project>/.loop-spec/runs/<slug>/`:

    state.json    what the program records: base, branch, task status, verify, PR
    spec.json     written by the lead: title, goal, criteria (each with an optional check)
    plan.json     written by the lead: prepare command and the task DAG
    work/         worktree on the feature branch, where finished tasks are merged
    tasks/<id>/   one worktree per started task
    verify/       the detached checkout verify runs in
    pr.md         the PR description the lead writes
    result.json   the run's final result, 7.x's schema-1 record; its presence means the run is over
    events.jsonl  the phase stream's records (phases.py)
    stream.pending  stream markers not yet reported by the PostToolUse hook (phases.py, hook.py)

A workspace run, in a directory holding `.loop-spec/workspace.json`, is the same under that
directory (the run root): `work/<name>/`, `verify/<name>/`, `base/<name>/` and `pr/<name>.md` per
repository, one `Repo` view each (`Run.repos`). Its `state.json` keeps each repository's base,
branch, PR, and delivery under `repos`.

A `Run` lives for one command, and no command writes spec.json or plan.json, so they
are read once.
"""
import json
import os
import re
import textwrap
from collections import Counter
from dataclasses import dataclass
from datetime import datetime, timezone
from functools import cached_property
from pathlib import Path
from typing import Callable

from loop_spec import dag, git
from loop_spec.errors import LoopSpecError

RUNS_DIR = Path(".loop-spec") / "runs"
KINDS = ("cycle", "micro", "debug", "revise")
RESULT_STATUSES = ("completed", "no-change", "escalated", "failed")
WORKSPACE = Path(".loop-spec") / "workspace.json"
PENDING_STREAM = "stream.pending"
NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")


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


def spec_problems(spec) -> list[str]:
    """What makes spec.json unusable, in terms the lead can fix. Empty when it is sound."""
    if not isinstance(spec, dict):
        return ["spec.json must be a JSON object with `goal` and `criteria`"]
    found = []
    if not isinstance(spec.get("goal"), str) or not spec["goal"].strip():
        found.append("`goal` must be a one-sentence string")
    criteria = spec.get("criteria")
    if not isinstance(criteria, list) or not criteria:
        return found + ["`criteria` must be a list with at least one criterion"]
    ids = Counter()
    for n, c in enumerate(criteria, 1):
        if not isinstance(c, dict):
            found.append(f"criterion #{n} must be an object with `id`, `text`, and an optional `check`")
            continue
        name = c.get("id") or f"criterion #{n}"
        if not isinstance(c.get("id"), str) or not c["id"]:
            found.append(f"{name} has no `id`")
        else:
            ids[c["id"]] += 1
        if not isinstance(c.get("text"), str) or not c["text"].strip():
            found.append(f"{name} has no `text`")
        if c.get("check") is not None and not (isinstance(c["check"], str) and c["check"].strip()):
            found.append(f"{name}: `check` must be a command string, or left out when no command can show it")
    found += [f"criterion id {cid} is used more than once" for cid, n in ids.items() if n > 1]
    return found


def run_root(start: Path) -> Path:
    """The nearest of `start` and its parents holding workspace.json, else the repository's root."""
    start = start.resolve()
    for d in (start, *start.parents):
        if (d / WORKSPACE).is_file():
            return d
    try:
        return git.project_root(start)
    except LoopSpecError:
        clones = sorted(d.name for d in start.iterdir() if (d / ".git").exists()) if start.is_dir() else []
        if not clones:
            raise
        listed = ", ".join(f'{{"name": "{n}", "path": "{n}"}}' for n in clones)
        raise LoopSpecError(f"{start} is not a repository; it holds the clones {', '.join(clones)}",
                            f'list the ones this change spans in {start / WORKSPACE}: {{"repos": [{listed}]}}, then start again')


def workspace_repos(root: Path) -> list[dict] | None:
    """The repositories workspace.json declares, validated, as [{name, path}] sorted by name;
    None when `root` is not a workspace root."""
    file = root / WORKSPACE
    if not file.is_file():
        return None
    fix = f"fix {file}: {{\"repos\": [{{\"name\": \"api\", \"path\": \"api\"}}]}}"
    data = read_json(file, "workspace.json")
    repos = data.get("repos") if isinstance(data, dict) else None
    if not isinstance(repos, list) or not repos:
        raise LoopSpecError(f"{file} needs a non-empty `repos` list", fix)
    found, seen = [], set()
    for n, e in enumerate(repos, 1):
        if not isinstance(e, dict) or not isinstance(e.get("name"), str) or not isinstance(e.get("path"), str):
            raise LoopSpecError(f"workspace repo #{n} needs a string `name` and `path`", fix)
        name = e["name"]
        if not NAME.match(name):
            raise LoopSpecError(f"workspace repo {name!r}: the name must match {NAME.pattern}", fix)
        if name in seen:
            raise LoopSpecError(f"workspace repo {name} is listed twice", fix)
        seen.add(name)
        path = (root / e["path"]).resolve()
        if path == root.resolve():
            raise LoopSpecError(f"workspace repo {name}: path is the workspace root itself", fix)
        proc = git.git(path, "rev-parse", "--show-toplevel") if path.is_dir() else None
        if proc is None or proc.returncode != 0 or Path(proc.stdout.strip()).resolve() != path:
            raise LoopSpecError(f"workspace repo {name}: {e['path']} is not a git repository's top level", fix)
        found.append({"name": name, "path": path})
    return sorted(found, key=lambda e: e["name"])


@dataclass
class Repo:
    """One repository of a run. A single-repo run has one, named "", whose `state` is the run's own."""
    name: str
    path: Path        # the user's clone
    work: Path        # the feature worktree
    verify_dir: Path  # the clean checkout verify uses
    base_dir: Path    # the base checkout a failing repository check is compared in
    pr_md: Path       # the PR description the lead writes
    state: dict       # this repository's slice of state.json


def sha_for(head, repo: Repo):
    return head[repo.name] if isinstance(head, dict) else head


def short(head) -> str:
    if head is None:
        return "?"
    if isinstance(head, dict):
        return ", ".join(f"{n} {s[:12]}" for n, s in sorted(head.items()))
    return head[:12]


def prepare_for(plan: dict | None, name: str) -> str | None:
    p = (plan or {}).get("prepare")
    return p.get(name) if isinstance(p, dict) else p


def workspace_problems(plan, names: list[str]) -> list[str]:
    """What a workspace plan lacks: every task and `checks` entry names one of the repositories."""
    plan, listed = plan or {}, ", ".join(names)
    found = [f"{t['id']} has no known `repo` (one of: {listed})" for t in plan.get("tasks", []) if t.get("repo") not in names]
    found += [f"`checks` entry #{n} must be an object with a `repo` (one of: {listed})"
              for n, c in enumerate(plan.get("checks") or [], 1) if not isinstance(c, dict) or c.get("repo") not in names]
    if isinstance(plan.get("prepare"), dict):
        found += [f"`prepare` names {k}, which is no repository (one of: {listed})" for k in plan["prepare"] if k not in names]
    return found


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

    @property
    def pending_stream(self) -> Path:
        return self.dir / PENDING_STREAM

    @property
    def workspace(self) -> bool:
        return "repos" in self.state

    @property
    def repos(self) -> list[Repo]:
        if not self.workspace:
            return [Repo("", self.project, self.work, self.verify_dir, self.dir / "base", self.dir / "pr.md", self.state)]
        return [Repo(n, self.project / e["path"], self.work / n, self.verify_dir / n, self.dir / "base" / n,
                     self.dir / "pr" / f"{n}.md", e) for n, e in sorted(self.state["repos"].items())]

    def repo(self, name: str | None) -> Repo:
        repos = self.repos
        if not self.workspace:
            return repos[0]
        for r in repos:
            if r.name == name:
                return r
        raise LoopSpecError(f"{name or 'no repo'} is not a repository of this run (one of: {', '.join(r.name for r in repos)})",
                            "name one in the task's `repo`")

    def head(self):
        """The feature head: a SHA, or {repo: SHA} in a workspace; None when a worktree is missing."""
        if not all(r.work.exists() for r in self.repos):
            return None
        heads = {r.name: git.head(r.work) for r in self.repos}
        return heads if self.workspace else heads[""]

    def exists(self) -> bool:
        return self.state_path.is_file()

    def save(self) -> None:
        self.state["updatedAt"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        write_json(self.state_path, self.state)

    @property
    def mode(self) -> str:
        """`autonomous` or `supervised` when the host says so (LOOP_SPEC_MODE) or the run was started so,
        else `interactive`."""
        env = os.environ.get("LOOP_SPEC_MODE")
        return env if env in ("autonomous", "supervised") else self.state.get("mode", "interactive")

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
        if not found and self.workspace:
            found = workspace_problems(self.plan, [r.name for r in self.repos])
        if not found and isinstance(self.spec, dict) and not spec_problems(self.spec):
            found = dag.unknown_criteria(tasks, [c["id"] for c in self.spec["criteria"]])
        if found:
            raise LoopSpecError("plan.json is not a usable task graph: " + "; ".join(found), f"fix {self.plan_path}")
        return tasks

    def checked_spec(self) -> dict:
        """spec.json, or a refusal naming what is missing or wrong in it."""
        if self.spec is None:
            raise LoopSpecError(f"there is no spec at {self.spec_path}", "write it; see the Spec section of the loop-spec skill")
        found = spec_problems(self.spec)
        if found:
            raise LoopSpecError(f"{self.spec_path.name} is not usable: " + "; ".join(found), f"fix {self.spec_path}")
        return self.spec

    def task(self, task_id: str) -> dict:
        for t in self.tasks:
            if t["id"] == task_id:
                return t
        raise LoopSpecError(f"{task_id} is not a task in {self.plan_path.name}", "run `loop-spec status` for the task list")

    def statuses(self) -> dict[str, str]:
        return {tid: t["status"] for tid, t in self.state.get("tasks", {}).items()}

    def set_task(self, task_id: str, status: str, note: str | None = None) -> None:
        self.state.setdefault("tasks", {})[task_id] = {"status": status, "note": note}

    def verified_at(self, head) -> bool:
        verify = self.state.get("verify") or {}
        return bool(verify.get("passed")) and head is not None and verify.get("sha") == head

    def phase(self, head) -> str:
        """Where the run is, derived from its files: spec, plan, execute, verify, iterate, deliver, or
        done, 7.x's phase names. Delivering covers the PR's CI and review feedback too."""
        if self.result_path.is_file():
            return "done"
        if self.spec is None or spec_problems(self.spec):
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
