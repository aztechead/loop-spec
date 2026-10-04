"""The `loop-spec` command line: one function per subcommand.

Output goes to `log.stdout` as plain lines a model or a person reads. Two lines are
machine-readable: `LOOP_SPEC_RUN {...}` after `start` and `status`, naming the run and
its paths, and `LOOP_SPEC_RESULT {...}` when a run ends.
"""
import argparse
import json
import os
from pathlib import Path

from loop_spec import VERSION, checks, dag, deliver, git, log
from loop_spec.errors import LoopSpecError
from loop_spec.runs import KINDS, RESULT_STATUSES, Run, all_runs, find, now, read_json, slugify

PROGRAM = Path(__file__).resolve().parents[1] / "loop-spec"
CONFIG = Path(".loop-spec") / "config.json"


def out(line: str = "") -> None:
    log.stdout.info(line)


def marker(name: str, data: dict) -> None:
    out(f"{name} {json.dumps(data)}")


# --- start ------------------------------------------------------------------------


def cmd_start(args, project: Path, cwd: Path) -> int:
    request = args.request or (Path(args.request_file).read_text() if args.request_file else "")
    if not request.strip() and not args.pr:
        if args.slug and Run(project, args.slug).exists():
            return show_status(Run(project, args.slug))
        raise LoopSpecError("nothing to start: pass --request, --request-file, or --pr", "say what the run should do")
    kind = "revise" if args.pr else args.kind
    slug = args.slug or slugify(request if request.strip() else f"pr {args.pr}")
    run = Run(project, slug)
    if run.exists():
        if args.slug or run.state.get("request") == request:
            out(f"loop-spec: resuming {slug}")
            return show_status(run)
        n = 2
        while Run(project, f"{slug}-{n}").exists():
            n += 1
        run = Run(project, f"{slug}-{n}")

    config = read_json(project / CONFIG, "config") or {}
    git.exclude(project, "/.loop-spec/runs/")
    pr = None
    if args.pr:
        pr = deliver.adopt_pr(project, args.pr)
        base_branch, branch = pr["baseRefName"], pr["headRefName"]
        base_sha = git.resolve_base(project, base_branch)
        _checkout_pr_branch(project, run.work, branch)
    else:
        base_branch = args.base or config.get("base") or git.default_branch(project)
        base_sha = git.resolve_base(project, base_branch)
        prefix = config.get("branchPrefix") or ("fix/" if kind == "debug" else "feat/")
        branch = git.free_branch(project, args.branch or config.get("branch") or prefix + run.slug)
        git.add_worktree(project, run.work, base_sha, new_branch=branch)

    run.state = {
        "schema": 8,
        "slug": run.slug,
        "kind": kind,
        "mode": "autonomous" if args.autonomous else "interactive",
        "request": request.strip(),
        "createdAt": now(),
        "base": {"branch": base_branch, "sha": base_sha},
        "branch": branch,
        "pr": {"number": pr["number"], "url": pr["url"]} if pr else None,
        "config": {k: config[k] for k in ("reviewers", "labels") if config.get(k)},
        "tasks": {},
    }
    run.save()
    out(f"loop-spec: started {run.slug} ({kind}, {run.state['mode']})")
    return show_status(run)


def _checkout_pr_branch(project: Path, dest: Path, branch: str) -> None:
    fetched = git.git(project, "fetch", "--no-tags", "origin", f"+refs/heads/{branch}:refs/remotes/origin/{branch}")
    if fetched.returncode != 0:
        raise LoopSpecError(f"could not fetch the PR branch {branch}: {fetched.stderr.strip()}", "check the origin remote and access")
    remote = git.head(project, f"refs/remotes/origin/{branch}")
    if not git.branch_exists(project, branch):
        git.run_git(project, "branch", branch, remote)
    elif git.head(project, f"refs/heads/{branch}") != remote:
        if git.git(project, "merge-base", "--is-ancestor", branch, remote).returncode != 0:
            raise LoopSpecError(f"local branch {branch} has commits the PR does not",
                                f"push or drop them first (git log {remote[:12]}..{branch})")
        if git.git(project, "branch", "-f", branch, remote).returncode != 0:
            raise LoopSpecError(f"branch {branch} is checked out and behind the PR",
                                f"pull it where it is checked out, or check out another branch there")
    proc = git.git(project, "worktree", "add", "--quiet", str(dest), branch)
    if proc.returncode != 0:
        raise LoopSpecError(f"could not check out {branch} for this run: {proc.stderr.strip()}",
                            f"if {branch} is checked out elsewhere, switch that checkout to another branch")


# --- status and next ---------------------------------------------------------------


def cmd_status(args, project: Path, cwd: Path) -> int:
    if args.slug or _in_a_run(project, cwd):
        return show_status(find(project, args.slug, cwd))
    runs = all_runs(project)
    if not runs:
        out("loop-spec: no runs in this repository")
        return 0
    for run in runs:
        result = run.state.get("result")
        where = f"done: {result['status']}" if result else run.state.get("kind", "")
        out(f"{run.slug:42} {where:22} updated {run.state.get('updatedAt', '?')}")
    return 0


def _in_a_run(project: Path, cwd: Path) -> bool:
    try:
        find(project, None, cwd)
        return True
    except LoopSpecError:
        return False


def show_status(run: Run) -> int:
    s = run.state
    head = git.head(run.work) if run.work.exists() else None
    try:
        phase, problem = run.phase(head), None
    except LoopSpecError as exc:
        phase, problem = "plan", exc.message
    out(f"{run.slug}: {s['kind']}, {s['mode']}, phase {phase}")
    out(f"  request  {_first_line(s.get('request', ''))}")
    out(f"  branch   {s['branch']} from {s['base']['branch']} @ {s['base']['sha'][:12]}" + (f", head {head[:12]}" if head else ""))
    out(f"  work     {_rel(run, run.work)}")
    if s.get("pr"):
        out(f"  pr       {s['pr']['url']}")
    spec = run.spec()
    out(f"  spec     {len(spec.get('criteria', []))} criteria in {_rel(run, run.spec_path)}" if spec else f"  spec     not written yet ({_rel(run, run.spec_path)})")
    if problem:
        out(f"  plan     {problem}")
    elif run.plan() is None:
        out(f"  plan     not written yet ({_rel(run, run.plan_path)})")
    else:
        _print_tasks(run)
        missing = dag.uncovered((spec or {}).get("criteria", []), run.tasks())
        if missing:
            out(f"  note     no task names criteria {', '.join(missing)}")
    verify = s.get("verify")
    if verify:
        state = "passed" if verify["passed"] else "FAILED"
        stale = "" if verify["sha"] == head else f" (branch has moved to {head[:12] if head else '?'} since)"
        out(f"  verify   {state} at {verify['sha'][:12]}{stale}")
    if s.get("result"):
        out(f"  result   {s['result']['status']}: {s['result']['summary']}")
    out(f"  next     {_next_step(run, phase, problem)}")
    marker("LOOP_SPEC_RUN", {"slug": run.slug, "kind": s["kind"], "mode": s["mode"], "phase": phase,
                             "runDir": str(run.dir), "work": str(run.work), "program": str(PROGRAM)})
    return 0


def _rel(run: Run, path: Path) -> Path:
    return path.relative_to(run.project) if path.is_relative_to(run.project) else path


def _first_line(text: str) -> str:
    line = text.strip().splitlines()[0] if text.strip() else ""
    return line if len(line) <= 100 else line[:97] + "..."


def _next_step(run: Run, phase: str, problem: str | None) -> str:
    if problem:
        return f"fix {run.plan_path.name}"
    if phase == "spec":
        return f"write {_rel(run, run.spec_path)}"
    if phase == "plan":
        return f"write {_rel(run, run.plan_path)}"
    if phase == "execute":
        ready = dag.ready(run.tasks(), run.statuses())
        if ready:
            return "start ready tasks: loop-spec task start " + " ".join(t["id"] for t in ready)
        return "finish the tasks in progress (loop-spec task done <id>), or unblock a blocked one"
    if phase == "verify":
        return "loop-spec verify"
    if phase == "deliver":
        return "loop-spec deliver"
    return "nothing; the run is finished"


def _print_tasks(run: Run) -> None:
    tasks, statuses = run.tasks(), run.statuses()
    ready = {t["id"] for t in dag.ready(tasks, statuses)}
    out(f"  tasks    {len(tasks)} in {len(dag.waves(tasks))} waves")
    for t in tasks:
        status = dag.status_of(t["id"], statuses)
        label = "ready" if t["id"] in ready else status
        extra = ""
        if status == "doing":
            extra = f"  at {_rel(run, run.task_dir(t['id']))}"
        elif status == "todo" and label != "ready":
            extra = f"  waits on {', '.join(dag.waiting_on(t, statuses))}"
        note = run.state["tasks"].get(t["id"], {}).get("note")
        out(f"    [{label:7}] {t['id']:6} {t.get('title', '')}{extra}" + (f"  ({note})" if note else ""))


def cmd_next(args, project: Path, cwd: Path) -> int:
    run = find(project, args.slug, cwd)
    tasks, statuses = run.tasks(), run.statuses()
    if not tasks:
        out(f"no plan yet: write {run.plan_path}")
        return 0
    ready = dag.ready(tasks, statuses)
    for t in ready:
        files = ", ".join(t.get("files", []))
        out(f"{t['id']}  {t.get('title', '')}" + (f"  [{files}]" if files else ""))
    counts = {k: sum(1 for t in tasks if dag.status_of(t["id"], statuses) == k) for k in dag.STATUSES}
    waiting = counts["todo"] - len(ready)
    out(f"{counts['done']} done, {counts['doing']} doing, {len(ready)} ready, {waiting} waiting, {counts['blocked']} blocked")
    if counts["done"] == len(tasks):
        out("every task is done: run loop-spec verify")
    return 0


# --- tasks -------------------------------------------------------------------------


def _task(run: Run, task_id: str) -> dict:
    for t in run.tasks():
        if t["id"] == task_id:
            return t
    raise LoopSpecError(f"{task_id} is not a task in {run.plan_path.name}", "run `loop-spec status` for the task list")


def cmd_task_start(args, project: Path, cwd: Path) -> int:
    run = find(project, args.slug, cwd)
    statuses = run.statuses()
    feature_head = git.head(run.work)
    for task_id in args.ids:
        task, record = _task(run, task_id), run.task_record(task_id)
        if record["status"] == "done":
            out(f"{task_id}  already done")
            continue
        waits = dag.waiting_on(task, statuses)
        if waits:
            out(f"{task_id}  warning: {', '.join(waits)} not done yet, so this worktree will not have their changes")
        dest, branch = run.task_dir(task_id), run.task_branch(task_id)
        if not dest.exists():
            if git.branch_exists(project, branch):
                git.add_worktree(project, dest, branch)
            else:
                git.add_worktree(project, dest, feature_head, new_branch=branch)
        record.update(status="doing", branch=branch, startedAt=now())
        out(f"{task_id}  {dest}")
    run.save()
    return 0


def cmd_task_done(args, project: Path, cwd: Path) -> int:
    run = find(project, args.slug, cwd)
    task, record = _task(run, args.id), run.task_record(args.id)
    dest, branch = run.task_dir(args.id), run.task_branch(args.id)
    if not git.branch_exists(project, branch):
        raise LoopSpecError(f"{args.id} has no task branch", f"start it with `loop-spec task start {args.id}`")
    if dest.exists() and (dirty := git.dirty(dest)):
        raise LoopSpecError(f"{args.id}'s worktree has uncommitted changes: {', '.join(dirty[:5])}",
                            f"commit them in {dest} (or discard them), then run task done again")
    new = git.commits(run.work, f"HEAD..{branch}")
    if new:
        if dirty := git.dirty(run.work):
            raise LoopSpecError(f"the integration worktree has uncommitted changes: {', '.join(dirty[:5])}",
                                f"commit or discard them in {run.work}")
        merged = git.git(run.work, "merge", "--no-ff", "--no-edit", "-m", f"Merge {args.id}: {task.get('title', '')}", branch)
        if merged.returncode != 0:
            conflicts = git.run_git(run.work, "diff", "--name-only", "--diff-filter=U").split()
            git.git(run.work, "merge", "--abort")
            raise LoopSpecError(f"{args.id} conflicts with the feature branch in: {', '.join(conflicts) or merged.stderr.strip()}",
                                f"in {dest}: git merge {run.state['branch']}, resolve, commit, then run task done {args.id} again")
    if dest.exists():
        git.remove_worktree(project, dest)
    git.git(project, "branch", "-D", branch)
    record.update(status="done", commits=new, doneAt=now(), note=args.note or (None if new else "no changes"))
    run.save()
    out(f"{args.id} merged ({len(new)} commit{'s' if len(new) != 1 else ''})" if new else f"{args.id} done with no changes")
    ready = dag.ready(run.tasks(), run.statuses())
    if ready:
        out("now ready: " + ", ".join(t["id"] for t in ready))
    elif all(s == "done" for s in (dag.status_of(t["id"], run.statuses()) for t in run.tasks())):
        out("every task is done: run loop-spec verify")
    return 0


def cmd_task_set(args, project: Path, cwd: Path) -> int:
    run = find(project, args.slug, cwd)
    _task(run, args.id)
    record = run.task_record(args.id)
    record.update(status=args.status, note=args.note)
    run.save()
    out(f"{args.id} is {args.status}" + (f": {args.note}" if args.note else ""))
    return 0


# --- verify, deliver, finish -------------------------------------------------------


def cmd_verify(args, project: Path, cwd: Path) -> int:
    run = find(project, args.slug, cwd)
    spec, plan = run.spec(), run.plan()
    run.tasks()  # refuse a broken plan before running anything
    items = checks.planned(spec, plan)
    if not items:
        raise LoopSpecError("there is nothing to verify: no spec criteria and no task verify commands",
                            f"write {run.spec_path.name} with criteria that name a check")
    head = git.head(run.work)
    at = run.state["base"]["sha"] if args.at == "base" else args.at
    sha = git.head(run.work, at) if at else head
    if not at and (dirty := git.dirty(run.work)):
        out(f"note: uncommitted changes in {run.work} are not part of this verify: {', '.join(dirty[:5])}")
    dest = run.dir / "verify"
    if dest.exists():
        git.run_git(project, "worktree", "remove", "--force", str(dest))
    git.add_worktree(project, dest, sha, detach=True)
    out(f"verifying {sha[:12]} in a clean checkout")
    results, passed = [], True
    try:
        prepare = (plan or {}).get("prepare")
        if prepare:
            r = checks.run(prepare, dest, args.timeout)
            _report("prepare", r)
            if r["exit"] != 0:
                passed = False
                results.append({"name": "prepare", **r})
                items = []
        for item in items:
            if item["command"] is None:
                out(f"  -     {item['name']:8} no check; needs evidence from review: {item['text']}")
                results.append({"name": item["name"], "command": None})
                continue
            r = checks.run(item["command"], dest, args.timeout)
            _report(item["name"], r)
            passed = passed and r["exit"] == 0
            results.append({"name": item["name"], **r})
    finally:
        if not args.keep:
            git.run_git(project, "worktree", "remove", "--force", str(dest))
    if not at:
        run.state["verify"] = {"sha": sha, "passed": passed, "at": now(), "results": results}
        run.save()
        out(("PASSED" if passed else "FAILED") + f": verify of {sha[:12]} recorded")
    else:
        out(("passed" if passed else "failed") + f" at {args.at} ({sha[:12]}); not recorded, since only the feature head is delivered")
    return 0 if passed else 1


def _report(name: str, r: dict) -> None:
    ok = r["exit"] == 0
    out(f"  {'pass' if ok else 'FAIL':5} {name:8} {r['command']}  ({r['seconds']}s, exit {r['exit']})")
    if not ok and r["tail"]:
        out("\n".join("        " + line for line in r["tail"].splitlines()))


def cmd_deliver(args, project: Path, cwd: Path) -> int:
    run = find(project, args.slug, cwd)
    pr = deliver.publish(run, draft=args.draft, unverified=args.unverified)
    out(f"delivered {run.state['branch']} at {run.state['delivered']['sha'][:12]}: {pr['url']}")
    summary = args.summary or (run.spec() or {}).get("goal") or _first_line(run.state.get("request", ""))
    return _finish(run, "completed", summary)


def cmd_finish(args, project: Path, cwd: Path) -> int:
    return _finish(find(project, args.slug, cwd), args.status, args.summary)


def _finish(run: Run, status: str, summary: str) -> int:
    result = run.finish(status, summary)
    for dest in [*sorted((run.dir / "tasks").glob("*")), run.work]:
        if dest.is_dir() and not git.remove_worktree(run.project, dest):
            out(f"kept {dest}: it has uncommitted changes")
    marker("LOOP_SPEC_RESULT", {**result, "path": str(run.result_path)})
    return 0


# --- wiring ------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="loop-spec", description="Run state and task graph for a loop-spec run.")
    parser.add_argument("--version", action="version", version=VERSION)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--project-root", help="the repository; default: the one holding the current directory")
    common.add_argument("--slug", help="the run; default: the run holding the current directory, or the only open run")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("start", parents=[common], help="start a run, or resume it if it exists")
    p.add_argument("--request")
    p.add_argument("--request-file")
    p.add_argument("--kind", choices=[k for k in KINDS if k != "revise"], default="cycle")
    p.add_argument("--pr", help="revise this open pull request (number, URL, or branch)")
    p.add_argument("--autonomous", action="store_true", help="no one will answer questions during this run")
    p.add_argument("--base", help="branch to start from and target; default: origin's default branch")
    p.add_argument("--branch", help="feature branch name; default: feat/<slug> (fix/<slug> for debug)")
    p.set_defaults(func=cmd_start)

    sub.add_parser("status", parents=[common], help="show a run, or list runs").set_defaults(func=cmd_status)
    sub.add_parser("next", parents=[common], help="list the tasks ready to start").set_defaults(func=cmd_next)

    task = sub.add_parser("task", help="start, finish, or mark tasks").add_subparsers(dest="action", required=True)
    p = task.add_parser("start", parents=[common], help="create a worktree for each task, from the feature head")
    p.add_argument("ids", nargs="+")
    p.set_defaults(func=cmd_task_start)
    p = task.add_parser("done", parents=[common], help="merge a task's commits into the feature branch")
    p.add_argument("id")
    p.add_argument("--note")
    p.set_defaults(func=cmd_task_done)
    p = task.add_parser("set", parents=[common], help="set a task's status by hand")
    p.add_argument("id")
    p.add_argument("--status", required=True, choices=["todo", "blocked"])
    p.add_argument("--note")
    p.set_defaults(func=cmd_task_set)

    p = sub.add_parser("verify", parents=[common], help="run every check in a clean checkout of the feature head")
    p.add_argument("--at", help="check this ref instead; `base` is the run's start commit (to see a bug reproduce there). Not recorded")
    p.add_argument("--timeout", type=int, default=1200, help="seconds per command (default 1200)")
    p.add_argument("--keep", action="store_true", help="keep the verify checkout for inspection")
    p.set_defaults(func=cmd_verify)

    p = sub.add_parser("deliver", parents=[common], help="push the verified head and open or update its PR")
    p.add_argument("--draft", action="store_true")
    p.add_argument("--unverified", action="store_true", help="deliver without a passing verify, as a draft that says so")
    p.add_argument("--summary")
    p.set_defaults(func=cmd_deliver)

    p = sub.add_parser("finish", parents=[common], help="end a run without delivering")
    p.add_argument("--status", required=True, choices=RESULT_STATUSES)
    p.add_argument("--summary", required=True)
    p.set_defaults(func=cmd_finish)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    cwd = Path(os.getcwd())
    try:
        project = Path(args.project_root).resolve() if args.project_root else git.project_root(cwd)
        return args.func(args, project, cwd)
    except LoopSpecError as exc:
        log.stderr.error(f"loop-spec: {exc.message}")
        if exc.repair:
            log.stderr.error(f"  next: {exc.repair}")
        return 1
