"""The `loop-spec` command line: one function per subcommand.

Output goes to `log.stdout` as plain lines a model or a person reads. Three lines are
machine-readable JSON: `LOOP_SPEC_RUN` after `start` and `status` (the run and its
paths), `LOOP_SPEC_TASK` per task from `task start` (a worker's brief), and
`LOOP_SPEC_RESULT` when a run ends.
"""
import argparse
import json
import os
from pathlib import Path

from loop_spec import VERSION, checks, dag, deliver, git, log
from loop_spec.errors import LoopSpecError
from loop_spec.runs import KINDS, RESULT_STATUSES, Run, all_runs, find, first_free, first_line, read_json, slugify

PROGRAM = Path(__file__).resolve().parents[1] / "loop-spec"


def out(line: str = "") -> None:
    log.stdout.info(line)


def marker(name: str, data: dict) -> None:
    out(f"{name} {json.dumps(data)}")


# --- start and status --------------------------------------------------------------


def cmd_start(args, project: Path, cwd: Path) -> int:
    if args.slug and Run(project, args.slug).exists():
        out(f"loop-spec: resuming {args.slug}")
        return show_status(Run(project, args.slug))
    request = (args.request or (Path(args.request_file).read_text() if args.request_file else "")).strip()
    if not request and not args.pr:
        raise LoopSpecError("nothing to start: pass --request, --request-file, or --pr", "say what the run should do")
    slug = args.slug or slugify(request or f"pr {args.pr}")
    existing = Run(project, slug)
    if existing.exists() and existing.state.get("request") == request:
        out(f"loop-spec: resuming {slug}")
        return show_status(existing)
    run = Run(project, first_free(slug, lambda s: Run(project, s).exists()))

    config = read_json(project / ".loop-spec" / "config.json", "config") or {}
    git.exclude(project, "/.loop-spec/runs/")
    pr = None
    if args.pr:
        kind = "revise"
        found = deliver.adopt_pr(project, args.pr)
        base_branch, branch = found["baseRefName"], found["headRefName"]
        base_sha = git.checkout_pr_branch(project, run.work, branch, base_branch)
        pr = {"number": found["number"], "url": found["url"], "adopted": True}
    else:
        kind = args.kind
        base_branch = args.base or config.get("base") or git.default_branch(project)
        base_sha = git.resolve_base(project, base_branch)
        prefix = config.get("branchPrefix") or ("fix/" if kind == "debug" else "feat/")
        branch = first_free(args.branch or config.get("branch") or prefix + run.slug,
                            lambda b: git.branch_exists(project, b))
        git.add_worktree(project, run.work, base_sha, new_branch=branch)

    run.state = {
        "kind": kind,
        "mode": "autonomous" if args.autonomous else "interactive",
        "request": request,
        "base": {"branch": base_branch, "sha": base_sha},
        "branch": branch,
        "pr": pr,
        "rootChanges": git.dirty(project),
        "tasks": {},
    }
    run.save()
    out(f"loop-spec: started {run.slug} ({kind}, {run.mode})")
    return show_status(run)


def cmd_status(args, project: Path, cwd: Path) -> int:
    try:
        run = find(project, args.slug, cwd)
    except LoopSpecError:
        if args.slug:
            raise
        runs = all_runs(project)
        for r in runs:
            result = r.result
            where = f"done: {result['status']}" if result else r.state.get("kind", "")
            out(f"{r.slug:42} {where:22} updated {r.state.get('updatedAt', '?')}")
        if not runs:
            out("loop-spec: no runs in this repository")
        return 0
    return show_status(run)


def show_status(run: Run) -> int:
    s = run.state
    head = git.head(run.work) if run.work.exists() else None
    try:
        phase, problem = run.phase(head), None
    except LoopSpecError as exc:
        phase, problem = "plan", exc.message
    out(f"{run.slug}: {s['kind']}, {run.mode}, phase {phase}")
    out(f"  request  {first_line(s.get('request', ''), 100)}")
    out(f"  branch   {s['branch']} from {s['base']['branch']} @ {s['base']['sha'][:12]}" + (f", head {head[:12]}" if head else ""))
    out(f"  work     {_rel(run, run.work)}")
    if s.get("pr"):
        out(f"  pr       {s['pr']['url']}")
    spec = run.spec
    out(f"  spec     {len(spec.get('criteria', []))} criteria in {_rel(run, run.spec_path)}" if spec
        else f"  spec     not written yet ({_rel(run, run.spec_path)})")
    if problem:
        out(f"  plan     {problem}")
    elif run.plan is None:
        out(f"  plan     not written yet ({_rel(run, run.plan_path)})")
    else:
        _print_tasks(run)
        missing = dag.uncovered((spec or {}).get("criteria", []), run.tasks)
        if missing:
            out(f"  note     no task names criteria {', '.join(missing)}")
    verify = s.get("verify")
    if verify:
        stale = "" if verify["sha"] == head else f" (the branch has moved to {head[:12] if head else '?'} since)"
        out(f"  verify   {'passed' if verify['passed'] else 'FAILED'} at {verify['sha'][:12]}{stale}")
    result = run.result
    if result:
        out(f"  result   {result['status']}: {result['summary']}")
    _warn_root_changes(run)
    out(f"  next     {_next_step(run, phase, problem)}")
    marker("LOOP_SPEC_RUN", {"slug": run.slug, "kind": s["kind"], "mode": run.mode, "phase": phase,
                             "base": s["base"]["sha"], "runDir": str(run.dir), "work": str(run.work),
                             "program": str(PROGRAM)})
    return 0


def _rel(run: Run, path: Path) -> Path:
    return path.relative_to(run.project) if path.is_relative_to(run.project) else path


def _next_step(run: Run, phase: str, problem: str | None = None) -> str:
    if problem:
        return f"fix {run.plan_path.name}"
    if phase == "spec":
        return f"write {_rel(run, run.spec_path)}"
    if phase == "plan":
        return f"write {_rel(run, run.plan_path)}"
    if phase == "execute":
        ready = dag.ready(run.tasks, run.statuses())
        if ready:
            return "loop-spec task start " + " ".join(t["id"] for t in ready)
        return "finish the tasks in progress (loop-spec task done <id>), or unblock a blocked one"
    if phase == "verify":
        return "review the whole change (base..HEAD in work), then loop-spec verify"
    if phase == "deliver":
        return "loop-spec deliver"
    return "nothing; the run is over"


def _print_tasks(run: Run) -> None:
    statuses = run.statuses()
    ready = {t["id"] for t in dag.ready(run.tasks, statuses)}
    out(f"  tasks    {len(run.tasks)}")
    for t in run.tasks:
        status = dag.status_of(t["id"], statuses)
        label = "ready" if t["id"] in ready else status
        extra = ""
        if status == "doing":
            extra = f"  at {_rel(run, run.task_dir(t['id']))}"
        elif label == "todo":
            extra = f"  waits on {', '.join(dag.waiting_on(t, statuses))}"
        note = run.state["tasks"].get(t["id"], {}).get("note")
        out(f"    [{label:7}] {t['id']:6} {t.get('title', '')}{extra}" + (f"  ({note})" if note else ""))


def _warn_root_changes(run: Run) -> None:
    """The user's own checkout should not change during a run; name anything new there."""
    new = sorted(set(git.dirty(run.project)) - set(run.state.get("rootChanges", [])))
    if new:
        out(f"  warning  files changed in your own checkout during this run, not in a worktree: {', '.join(new[:5])}")


# --- tasks -------------------------------------------------------------------------


def cmd_task_start(args, project: Path, cwd: Path) -> int:
    run = find(project, args.slug, cwd)
    statuses = run.statuses()
    feature_head = git.head(run.work)
    criteria = {c.get("id"): c for c in (run.spec or {}).get("criteria", [])}
    prepare = (run.plan or {}).get("prepare")
    for task_id in args.ids:
        task = run.task(task_id)
        if dag.status_of(task_id, statuses) == "done":
            out(f"{task_id}: already done")
            continue
        waits = dag.waiting_on(task, statuses)
        if waits:
            out(f"{task_id}: warning: {', '.join(waits)} not done yet, so this worktree will not have their changes")
        dest, branch = run.task_dir(task_id), run.task_branch(task_id)
        note = None
        if not dest.exists():
            if git.branch_exists(project, branch):
                git.add_worktree(project, dest, branch)
            else:
                git.add_worktree(project, dest, feature_head, new_branch=branch)
            if prepare:
                r = checks.run(prepare, dest, args.timeout)
                if r["exit"] != 0:
                    note = f"prepare failed (exit {r['exit']})"
                    out(f"{task_id}: prepare failed in its worktree:\n" + _indent(r["tail"]))
        run.set_task(task_id, "doing", note)
        marker("LOOP_SPEC_TASK", {
            "id": task_id, "worktree": str(dest), "branch": branch, "from": git.head(dest),
            "task": task, "goal": (run.spec or {}).get("goal"),
            "criteria": [criteria[c] for c in task.get("criteria", []) if c in criteria],
            "prepared": prepare is not None and note is None,
        })
    run.save()
    return 0


def cmd_task_done(args, project: Path, cwd: Path) -> int:
    run = find(project, args.slug, cwd)
    task = run.task(args.id)
    dest, branch = run.task_dir(args.id), run.task_branch(args.id)
    if not git.branch_exists(project, branch):
        raise LoopSpecError(f"{args.id} has no task branch", f"start it with `loop-spec task start {args.id}`")
    if dest.exists():
        git.require_clean(dest, f"{args.id}'s worktree", f"commit them in {dest} (or discard them), then run task done again")
    new = git.commits(run.work, f"HEAD..{branch}")
    if new:
        git.require_clean(run.work, "the feature worktree", f"commit or discard them in {run.work}")
        merged = git.git(run.work, "merge", "--no-ff", "--no-edit", "-m", f"Merge {args.id}: {task.get('title', '')}", branch)
        if merged.returncode != 0:
            conflicts = git.run_git(run.work, "diff", "--name-only", "--diff-filter=U").split()
            git.git(run.work, "merge", "--abort")
            raise LoopSpecError(f"{args.id} conflicts with the feature branch in: {', '.join(conflicts) or merged.stderr.strip()}",
                                f"in {dest}: git merge {run.state['branch']}, resolve, commit, then run task done {args.id} again")
    if dest.exists():
        git.remove_worktree(project, dest, force=True)  # clean, checked above; --force only clears ignored files
    git.git(project, "branch", "-D", branch)
    run.set_task(args.id, "done", args.note or (None if new else "no changes"))
    run.save()
    out(f"{args.id} merged ({len(new)} commit{'s' if len(new) != 1 else ''})" if new else f"{args.id} done with no changes")
    _warn_root_changes(run)
    out("next: " + _next_step(run, run.phase(git.head(run.work))))
    return 0


def cmd_task_set(args, project: Path, cwd: Path) -> int:
    run = find(project, args.slug, cwd)
    run.task(args.id)
    run.set_task(args.id, args.status, args.note)
    run.save()
    out(f"{args.id} is {args.status}" + (f": {args.note}" if args.note else ""))
    return 0


# --- verify, deliver, finish -------------------------------------------------------


def cmd_verify(args, project: Path, cwd: Path) -> int:
    run = find(project, args.slug, cwd)
    run.tasks  # refuse a broken plan before running anything
    items = checks.planned(run.spec, run.plan)
    if not items:
        raise LoopSpecError("there is nothing to verify: no spec criteria and no task verify commands",
                            f"write {run.spec_path.name} with criteria that name a check")
    sha = run.state["base"]["sha"] if args.base else git.head(run.work)
    if not args.base and (dirty := git.dirty(run.work)):
        out(f"note: uncommitted changes in {run.work} are not part of this verify: {', '.join(dirty[:5])}")
    _checkout(project, run.verify_dir, sha)
    out(f"verifying {sha[:12]} in a clean checkout ({'the base' if args.base else 'the feature head'})")
    results, passed = [], True
    prepare = (run.plan or {}).get("prepare")
    if prepare:
        r = checks.run(prepare, run.verify_dir, args.timeout)
        _report("prepare", r)
        if r["exit"] != 0:
            passed, items = False, []
            results.append({"name": "prepare", **r})
    for item in items:
        if item["command"] is None:
            out(f"  -     {item['name']:8} no check; judge it in review: {item['text']}")
            results.append({"name": item["name"], "command": None})
            continue
        r = checks.run(item["command"], run.verify_dir, args.timeout)
        _report(item["name"], r)
        passed = passed and r["exit"] == 0
        results.append({"name": item["name"], **r})
    if args.base:
        out(("passed" if passed else "failed") + " at the base; not recorded, since only the feature head is delivered")
    else:
        run.state["verify"] = {"sha": sha, "passed": passed, "results": results}
        run.save()
        out(("PASSED" if passed else "FAILED") + f": verify of {sha[:12]} recorded")
    _warn_root_changes(run)
    return 0 if passed else 1


def _checkout(project: Path, dest: Path, sha: str) -> None:
    """A checkout of exactly `sha`'s tracked files. Reused between verifies: ignored files
    (installed dependencies, caches) are kept, so `prepare` can be incremental."""
    if dest.exists():
        git.run_git(dest, "checkout", "--quiet", "--detach", "--force", sha)
        git.run_git(dest, "clean", "-ffdq")
    else:
        git.add_worktree(project, dest, sha, detach=True)


def _indent(text: str) -> str:
    return "\n".join("        " + line for line in text.splitlines())


def _report(name: str, r: dict) -> None:
    ok = r["exit"] == 0
    out(f"  {'pass' if ok else 'FAIL':5} {name:8} {r['command']}  ({r['seconds']}s, exit {r['exit']})")
    if not ok and r["tail"]:
        out(_indent(r["tail"]))


def cmd_deliver(args, project: Path, cwd: Path) -> int:
    run = find(project, args.slug, cwd)
    head = deliver.publish(run, draft=args.draft, unverified=args.unverified,
                           comment_file=Path(args.comment_file).resolve() if args.comment_file else None)
    out(f"delivered {run.state['branch']} at {head[:12]}: {run.state['pr']['url']}")
    summary = (run.spec or {}).get("goal") or first_line(run.state.get("request", ""), 100)
    return _finish(run, "completed", summary, head)


def cmd_finish(args, project: Path, cwd: Path) -> int:
    run = find(project, args.slug, cwd)
    return _finish(run, args.status, args.summary, git.head(run.work) if run.work.exists() else None)


def _finish(run: Run, status: str, summary: str, head: str | None) -> int:
    result = run.finish(status, summary, head)
    git.remove_worktree(run.project, run.verify_dir, force=True)
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
    p.add_argument("--autonomous", action="store_true",
                   help="no one will answer questions (LOOP_SPEC_MODE=autonomous in the environment does the same)")
    p.add_argument("--base", help="branch to start from and target; default: origin's default branch")
    p.add_argument("--branch", help="feature branch name; default: feat/<slug> (fix/<slug> for debug)")
    p.set_defaults(func=cmd_start)

    sub.add_parser("status", parents=[common], help="show a run, or list runs").set_defaults(func=cmd_status)

    task = sub.add_parser("task", help="start, finish, or mark tasks").add_subparsers(dest="action", required=True)
    p = task.add_parser("start", parents=[common], help="a worktree per task from the feature head, prepared; prints each brief")
    p.add_argument("ids", nargs="+")
    p.add_argument("--timeout", type=int, default=1200, help="seconds for the prepare command (default 1200)")
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
    p.add_argument("--base", action="store_true", help="check the run's start commit instead, to see a bug reproduce; not recorded")
    p.add_argument("--timeout", type=int, default=1200, help="seconds per command (default 1200)")
    p.set_defaults(func=cmd_verify)

    p = sub.add_parser("deliver", parents=[common], help="push the verified head, open or update its PR, end the run")
    p.add_argument("--draft", action="store_true")
    p.add_argument("--unverified", action="store_true", help="deliver without a passing verify, as a draft that says so")
    p.add_argument("--comment-file", help="also post this file as a comment on the PR (e.g. replies to review comments)")
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
        project = git.project_root(Path(args.project_root).resolve() if args.project_root else cwd)
        return args.func(args, project, cwd)
    except LoopSpecError as exc:
        log.stderr.error(f"loop-spec: {exc.message}")
        if exc.repair:
            log.stderr.error(f"  next: {exc.repair}")
        return 1
