"""The `loop-spec` command line: one function per subcommand.

Output goes to `log.stdout` as plain lines a model or a person reads. Three lines are
machine-readable JSON: `LOOP_SPEC_RUN` after `start` and `status` (the run and its
paths), `LOOP_SPEC_TASK` per task from `task start` (a worker's brief), and, when a run
ends, `LOOP_SPEC_RESULT` (7.x's schema-1 record) then `LOOP_SPEC_NEXT` (where it is written).
"""
import argparse
import json
import os
from pathlib import Path

import sys
import time

from loop_spec import VERSION, checks, ci, dag, deliver, git, hook, legacy, log, phases, remote, review
from loop_spec.errors import LoopSpecError
from loop_spec.runs import (KINDS, RESULT_STATUSES, Run, all_runs, find, first_free, first_line, prepare_for, read_json,
                            run_root, sha_for, short, slugify, spec_problems, workspace_repos)

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
    slug = args.slug or slugify(args.title or request or f"pr {args.pr}")
    existing = Run(project, slug)
    if existing.exists() and existing.state.get("request") == request:
        out(f"loop-spec: resuming {slug}")
        return show_status(existing)
    run = Run(project, first_free(slug, lambda s: Run(project, s).exists()))

    config = read_json(project / ".loop-spec" / "config.json", "config") or {}
    mode = "supervised" if args.supervised else "autonomous" if args.autonomous else "interactive"
    entries = workspace_repos(project)
    if entries is not None:
        kind, run.state, so_far = _start_workspace(args, run, project, entries, config, request, mode)
    else:
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
                                lambda b: git.exists_anywhere(project, b))
            git.add_worktree(project, run.work, base_sha, new_branch=branch)

        run.state = {
            "kind": kind,
            "createdAt": legacy.now_iso(),
            "mode": mode,
            "request": request,
            "base": {"branch": base_branch, "sha": base_sha},
            "branch": branch,
            "title": args.title,
            "pr": pr,
            "instructions": git.instruction_files(project, base_sha),
            "rootChanges": git.dirty(project),
            "tasks": {},
        }
        so_far = review.read(run.work, pr["number"])[0] if pr else []
        if pr:  # the review so far is the spec's input; feedback reports only what comes after it
            run.state["feedback"] = {"seen": [i["id"] for i in so_far]}
    run.save()
    out(f"loop-spec: started {run.slug} ({kind}, {run.mode})")
    if so_far:
        out(f"the PR's review so far, {len(so_far)} item(s); change the code for each one this run should "
            "address, and answer every other one in the reply comment:")
        _show_items(so_far)
    return show_status(run)


def _start_workspace(args, run: Run, project: Path, entries: list[dict], config: dict, request: str, mode: str):
    """The state of a run across `entries`, with each repository's worktree made: (kind, state, review so far)."""
    if args.pr:
        kind = "revise"
        entry, found = deliver.adopt_workspace_pr(project, entries, args.pr)
        base_sha = git.checkout_pr_branch(entry["path"], run.work / entry["name"], found["headRefName"], found["baseRefName"])
        picks = [(entry, found["baseRefName"], base_sha, found["headRefName"],
                  {"number": found["number"], "url": found["url"], "adopted": True})]
    else:
        kind = args.kind
        prefix = config.get("branchPrefix") or ("fix/" if kind == "debug" else "feat/")
        picks = []
        for e in entries:  # resolve everything first, so a failure leaves no worktree behind
            base_branch = args.base or config.get("base") or git.default_branch(e["path"])
            branch = first_free(args.branch or config.get("branch") or prefix + run.slug,
                                lambda b, path=e["path"]: git.exists_anywhere(path, b))
            picks.append((e, base_branch, git.resolve_base(e["path"], base_branch), branch, None))
        for e, _, base_sha, branch, _ in picks:
            git.add_worktree(e["path"], run.work / e["name"], base_sha, new_branch=branch)
    repos, so_far = {}, []
    for e, base_branch, base_sha, branch, pr in picks:
        repos[e["name"]] = {"path": os.path.relpath(e["path"], project), "base": {"branch": base_branch, "sha": base_sha},
                            "branch": branch, "pr": pr, "instructions": git.instruction_files(e["path"], base_sha),
                            "rootChanges": git.dirty(e["path"])}
        if pr:  # the review so far is the spec's input; feedback reports only what comes after it
            so_far = review.read(run.work / e["name"], pr["number"])[0]
            repos[e["name"]]["feedback"] = {"seen": [i["id"] for i in so_far]}
    state = {"kind": kind, "createdAt": legacy.now_iso(), "mode": mode, "request": request, "title": args.title,
             "tasks": {}, "repos": repos}
    return kind, state, so_far


def cmd_status(args, project: Path, cwd: Path) -> int:
    try:
        run = find(project, args.slug, cwd)
    except LoopSpecError:
        if args.slug:
            raise
        runs = all_runs(project)
        for r in runs:
            result = r.result
            where = f"done: {result.get('outcome', result.get('status'))}" if result else r.state.get("kind", "")
            out(f"{r.slug:42} {where:22} updated {r.state.get('updatedAt', '?')}")
        if not runs:
            out("loop-spec: no runs in this repository")
        return 0
    _restore(run)
    return show_status(run)


def _rebuild(project: Path, dest: Path, branch: str) -> bool:
    """Check `branch` out at `dest` again, from the local branch, else origin's; False when neither exists."""
    if git.branch_exists(project, branch):
        git.add_worktree(project, dest, branch)
        return True
    if git.has_origin(project):
        git.fetch(project, git.tracking(branch))
        if git.remote_tip(project, branch):
            git.add_worktree(project, dest, f"origin/{branch}", new_branch=branch)
            return True
    return False


def _task_repo(run: Run, task_id: str):
    """The repository a task works in, from the raw plan; the only one in a single-repo run."""
    if not run.workspace:
        return run.repos[0]
    task = next((t for t in (run.plan or {}).get("tasks", []) if t.get("id") == task_id), {})
    try:
        return run.repo(task.get("repo"))
    except LoopSpecError:
        return run.repos[0]


def _restore(run: Run) -> None:
    """After a pause or a restored clone: rebuild the worktrees an open run lost, one line each."""
    if run.result_path.is_file():
        return
    finished = any(t.get("status") == "done" for t in run.state.get("tasks", {}).values())
    for r in run.repos:
        tag = f"[{r.name}] " if run.workspace else ""
        git.git(r.path, "worktree", "prune")  # a worktree deleted by hand is still registered until pruned
        if not run.workspace:
            git.exclude(r.path, "/.loop-spec/runs/")  # a fresh clone has not seen this run's directory
        if not r.work.exists():
            base = r.state["base"]["sha"]
            if _rebuild(r.path, r.work, r.state["branch"]):
                out(f"{tag}restored work from {r.state['branch']}")
            elif not finished and git.git(r.path, "cat-file", "-e", f"{base}^{{commit}}").returncode == 0:
                # checkpoint does not push a branch still at its base; with no task done, the base is all it held
                git.add_worktree(r.path, r.work, base, new_branch=r.state["branch"])
                out(f"{tag}restored work at its base {base[:12]} as {r.state['branch']}")
            else:
                out(f"{tag}cannot restore work: {r.state['branch']} is on neither this clone nor origin")
    for task_id, t in list(run.state.get("tasks", {}).items()):
        dest, branch = run.task_dir(task_id), run.task_branch(task_id)
        if t.get("status") != "doing" or dest.exists():
            continue
        if _rebuild(_task_repo(run, task_id).path, dest, branch):
            out(f"{task_id}: restored its worktree from {branch}")
        else:
            run.set_task(task_id, "todo", "worktree lost; start it again")
            out(f"{task_id}: worktree lost and its branch is gone; back to todo, start it again")
    run.save()


def _sync(run: Run) -> None:
    """Announce any phase change since the stream last spoke (see phases.py)."""
    try:
        phases.sync(run, run.head())
    except LoopSpecError:
        pass  # a plan that is not a DAG yet: the phase stays where it was


def show_status(run: Run) -> int:
    _sync(run)
    s = run.state
    head = run.head()
    try:
        run.tasks
        problem = None
    except LoopSpecError as exc:
        problem = exc.message
    phase = "spec" if run.spec is None or spec_problems(run.spec) else ("plan" if problem else run.phase(head))
    out(f"{run.slug}: {s['kind']}, {run.mode}, phase {phase}")
    out(f"  request  {first_line(s.get('request', ''), 100)}")
    if not run.workspace:
        out(f"  branch   {s['branch']} from {s['base']['branch']} @ {s['base']['sha'][:12]}" + (f", head {head[:12]}" if head else ""))
        out(f"  work     {_rel(run, run.work)}")
        if s.get("title"):
            out(f"  title    {s['title']}")
        if s.get("pr"):
            out(f"  pr       {s['pr']['url']}")
        if s.get("instructions"):
            out(f"  rules    {', '.join(s['instructions'])}")
        template = deliver.pr_template(run.work) if run.work.exists() else None
        if template and not (s.get("pr") or {}).get("adopted"):
            written = "written" if (run.dir / "pr.md").is_file() else "not written yet"
            out(f"  pr.md    {written}; follows {_rel(run, template)}")
    else:
        template = None
        out(f"  work     {_rel(run, run.work)}")
        for r in run.repos:
            rs = r.state
            out(f"    {r.name:8} {rs['branch']} from {rs['base']['branch']} @ {rs['base']['sha'][:12]}"
                + (f", head {sha_for(head, r)[:12]}" if head else "") + (f", pr {rs['pr']['url']}" if rs.get("pr") else "") + (f", title {rs['title']}" if rs.get("title") else ""))
        if s.get("title"):
            out(f"  title    {s['title']}")
        rules = [f"{r.name}/{f}" for r in run.repos for f in r.state.get("instructions", [])]
        if rules:
            out(f"  rules    {', '.join(rules)}")
        for r in deliver.changed(run, head):
            if not (r.state.get("pr") or {}).get("adopted"):
                written = "written" if r.pr_md.is_file() else "not written yet"
                out(f"    {r.name:8} pr.md {written} ({_rel(run, r.pr_md)}); follows {_rel(run, deliver.pr_template(r.work))}")
    spec = run.spec
    if spec is None:
        out(f"  spec     not written yet ({_rel(run, run.spec_path)})")
    elif found := spec_problems(spec):
        out(f"  spec     {_rel(run, run.spec_path)} is not usable: " + "; ".join(found))
    else:
        out(f"  spec     {len(spec['criteria'])} criteria in {_rel(run, run.spec_path)}")
    if problem:
        out(f"  plan     {problem}")
    elif run.plan is None:
        out(f"  plan     not written yet ({_rel(run, run.plan_path)})")
    else:
        _print_tasks(run)
        missing = dag.uncovered(spec["criteria"], run.tasks) if spec and not spec_problems(spec) else []
        if missing:
            out(f"  note     no task names criteria {', '.join(missing)}")
        for a, b, files in dag.shared_files(run.tasks):
            out(f"  warning  {a} and {b} can run at once but both list {', '.join(files)}: expect a merge conflict; "
                "give each file one owning task, or make one depend on the other")
        if any(r.state.get("instructions") for r in run.repos) and "checks" not in run.plan:
            out("  note     plan.json has no `checks`: list the checks the rules files above require (or [] if none)")
    verify = s.get("verify")
    if verify:
        stale = "" if verify["sha"] == head else f" (the branch has moved to {short(head)} since)"
        out(f"  verify   {'passed' if verify['passed'] else 'FAILED'} at {short(verify['sha'])}{stale}")
    for r in run.repos:
        if (r.state.get("feedback") or {}).get("sha"):
            f = r.state["feedback"]
            verdicts = ", ".join(f"{who} {state.lower()}" for who, state in f.get("verdicts", {}).items()) or "no reviews"
            out(f"  feedback {f'[{r.name}] ' if run.workspace else ''}CI {f['ci']} at {f['sha'][:12]}; {verdicts}; {len(f['seen'])} review item(s) seen")
    result = run.result
    if result:
        out(f"  result   {result.get('outcome', result.get('status'))}: {result['summary']}")
    _warn_root_changes(run)
    out(f"  next     {_next_step(run, phase, problem)}")
    info = {"slug": run.slug, "kind": s["kind"], "mode": run.mode, "phase": phase,
            "base": s["base"]["sha"] if not run.workspace else None, "runDir": str(run.dir), "work": str(run.work),
            "prTemplate": str(template) if template else None,
            "program": str(PROGRAM), "references": str(REFERENCES)}
    if run.workspace:
        info["repos"] = {r.name: {"work": str(r.work), "path": str(r.path), "base": r.state["base"]["sha"],
                                  "branch": r.state["branch"], "prTemplate": str(deliver.pr_template(r.work)),
                                  "prMd": str(r.pr_md)} for r in run.repos}
    phases.flush()
    marker("LOOP_SPEC_RUN", info)
    return 0


def _rel(run: Run, path: Path) -> Path:
    return path.relative_to(run.project) if path.is_relative_to(run.project) else path


# The hub skill's references, which only some runs need: a run kind's changes to the
# workflow, named on the `next` line at the spec, and the PR template, named at deliver.
REFERENCES = Path(__file__).resolve().parents[2] / "references"
KIND_GUIDES = ("micro", "debug", "revise")


def _next_step(run: Run, phase: str, problem: str | None = None) -> str:
    step = _step(run, phase, problem)
    named = []
    if phase == "spec" and run.state.get("kind") in KIND_GUIDES:
        named.append(str(REFERENCES / f"{run.state['kind']}.md"))
    if phase == "deliver":
        named += [str(p) for p in deliver.pr_guides(run)]
    return step + (f" (read {' and '.join(named)})" if named else "")


WRAP_UP = ("the host asked this run to wrap up: commit finished work, run loop-spec checkpoint --push, "
           "then loop-spec finish --status escalated --summary \"...\"")


def _wrap_up_asked(run: Run) -> bool:
    return (run.dir / hook.STOP_REQUESTED).is_file() and not run.result_path.is_file()


def _step(run: Run, phase: str, problem: str | None) -> str:
    if _wrap_up_asked(run):
        return WRAP_UP
    if problem:
        return f"fix {run.plan_path.name}"
    if phase == "spec":
        found = spec_problems(run.spec) if run.spec is not None else []
        if found:
            return f"fix {run.spec_path}: {'; '.join(found)}"
        approve = ", ask the user to approve its criteria (AskUserQuestion)" if run.mode == "interactive" else ""
        interview = ("ask the choices the request leaves open in one AskUserQuestion, your choice as the recommended "
                     "option (none open: no question), then " if run.mode != "autonomous" and run.state.get("kind") != "micro" else "")
        return f"{interview}write {run.spec_path}{approve}, then loop-spec status; no code before the plan is accepted"
    if phase == "plan":
        return f"write {run.plan_path}"
    if phase == "execute":
        ready = dag.ready(run.tasks, run.statuses())
        if ready:
            return "loop-spec task start " + " ".join(t["id"] for t in ready)
        return "finish the tasks in progress (loop-spec task done <id>), or unblock a blocked one"
    if phase == "verify":
        return "loop-spec verify"
    if phase == "iterate":
        return "review the whole change (base..HEAD in work), address what it finds, then loop-spec iterate"
    if phase == "deliver":
        delivered = any(r.state.get("delivered") for r in run.repos) and not deliver.undelivered(run, run.head())
        return "loop-spec feedback" if delivered else "loop-spec deliver"
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
    new = sorted(f"{r.name}/{f}" if run.workspace else f
                 for r in run.repos for f in set(git.dirty(r.path)) - set(r.state.get("rootChanges", [])))
    if new:
        out(f"  warning  files changed in your own checkout during this run, not in a worktree: {', '.join(new[:5])}")


# --- tasks -------------------------------------------------------------------------


def cmd_task_start(args, project: Path, cwd: Path) -> int:
    run = find(project, args.slug, cwd)
    statuses = run.statuses()
    heads = {}
    criteria = {c["id"]: c for c in run.checked_spec()["criteria"]}
    for task_id in args.ids:
        task = run.task(task_id)
        r = run.repo(task.get("repo"))
        feature_head = heads.setdefault(r.name, git.head(r.work))
        prepare = prepare_for(run.plan, r.name)
        if dag.status_of(task_id, statuses) == "done":
            out(f"{task_id}: already done")
            continue
        waits = dag.waiting_on(task, statuses)
        if waits:
            out(f"{task_id}: warning: {', '.join(waits)} not done yet, so this worktree will not have their changes")
        dest, branch = run.task_dir(task_id), run.task_branch(task_id)
        note = None
        if not dest.exists():
            if git.branch_exists(r.path, branch):
                git.add_worktree(r.path, dest, branch)
            else:
                git.add_worktree(r.path, dest, feature_head, new_branch=branch)
            if prepare:
                res = checks.run(prepare, dest, args.timeout)
                if res["exit"] != 0:
                    note = f"prepare failed (exit {res['exit']})"
                    out(f"{task_id}: prepare failed in its worktree:\n" + _indent(res["tail"]))
        run.set_task(task_id, "doing", note)
        brief = {
            "id": task_id, "worktree": str(dest), "branch": branch, "from": git.head(dest),
            "task": task, "goal": (run.spec or {}).get("goal"),
            "criteria": [criteria[c] for c in task.get("criteria", []) if c in criteria],
            "checks": [c["command"] for c in checks.repo_checks(run.plan) if not run.workspace or c.get("repo") == r.name],
            "prepared": prepare is not None and note is None,
        }
        if run.workspace:
            brief["repo"] = r.name
        marker("LOOP_SPEC_TASK", brief)
    run.save()
    _sync(run)
    return 0


def cmd_task_done(args, project: Path, cwd: Path) -> int:
    run = find(project, args.slug, cwd)
    task = run.task(args.id)
    r = run.repo(task.get("repo"))
    dest, branch = run.task_dir(args.id), run.task_branch(args.id)
    if not git.branch_exists(r.path, branch):  # done by the lead directly in work
        run.set_task(args.id, "done", args.note or "done in work")
        run.save()
        out(f"{args.id} done in work")
        _sync(run)
        out("next: " + _next_step(run, run.phase(run.head())))
        return 0
    if dest.exists():
        git.require_clean(dest, f"{args.id}'s worktree", f"commit them in {dest} (or discard them), then run task done again")
    new = git.commits(r.work, f"HEAD..{branch}")
    if new:
        git.require_clean(r.work, "the feature worktree", f"commit or discard them in {r.work}")
        merged = git.git(r.work, "merge", "--no-ff", "--no-edit", "-m", f"Merge {args.id}: {task.get('title', '')}", branch)
        if merged.returncode != 0:
            conflicts = git.run_git(r.work, "diff", "--name-only", "--diff-filter=U").split()
            git.git(r.work, "merge", "--abort")
            raise LoopSpecError(f"{args.id} conflicts with the feature branch in: {', '.join(conflicts) or merged.stderr.strip()}",
                                f"in {dest}: git merge {r.state['branch']}, resolve, commit, then run task done {args.id} again")
    if dest.exists():
        git.remove_worktree(r.path, dest, force=True)  # clean, checked above; --force only clears ignored files
    git.git(r.path, "branch", "-D", branch)
    _drop_remote_branch(r.path, branch)
    run.set_task(args.id, "done", args.note or (None if new else "no changes"))
    run.save()
    out(f"{args.id} merged ({len(new)} commit{'s' if len(new) != 1 else ''})" if new else f"{args.id} done with no changes")
    _warn_root_changes(run)
    _sync(run)
    out("next: " + _next_step(run, run.phase(run.head())))
    return 0


def _drop_remote_branch(project: Path, branch: str) -> None:
    """Remove a task branch a checkpoint pushed; a failure leaves it there."""
    if git.remote_tip(project, branch):
        git.git(project, "push", "--quiet", "origin", "--delete", branch)


def cmd_task_set(args, project: Path, cwd: Path) -> int:
    run = find(project, args.slug, cwd)
    run.task(args.id)
    run.set_task(args.id, args.status, args.note)
    run.save()
    out(f"{args.id} is {args.status}" + (f": {args.note}" if args.note else ""))
    _sync(run)
    return 0


# --- verify, deliver, finish -------------------------------------------------------


def cmd_verify(args, project: Path, cwd: Path) -> int:
    run = find(project, args.slug, cwd)
    run.tasks  # refuse a broken plan or spec before running anything
    items = checks.planned(run.checked_spec(), run.plan)
    if not items:
        raise LoopSpecError("there is nothing to verify: no spec criteria and no task verify commands",
                            f"write {run.spec_path.name} with criteria that name a check")
    head = run.head()
    sha = ({r.name: r.state["base"]["sha"] for r in run.repos} if run.workspace else run.state["base"]["sha"]) if args.base else head
    if sha is None:
        raise LoopSpecError("work is missing", "run loop-spec status to restore it")
    _sync(run)  # a head changed since the last verify enters VERIFY now, so the stream shows it
    for r in run.repos:
        if not args.base and (dirty := git.dirty(r.work)):
            out(f"note: uncommitted changes in {r.work} are not part of this verify: {', '.join(dirty[:5])}")
    out(f"verifying {short(sha)} in a clean checkout ({'the base' if args.base else 'the feature head'})")
    results, passed = [], _prepare(run, sha, args.timeout)
    for item in items if passed else []:
        if item["command"] is None:
            out(f"  -     {item['name']:8} no check; judge it in review: {item['text']}")
            results.append({"name": item["name"], "command": None})
            continue
        repo = run.repo(item.get("repo")) if run.workspace and item.get("repo") else None
        where = repo.verify_dir if repo else run.verify_dir
        r = checks.run(item["command"], where, args.timeout)
        _report(item["name"], r)
        if r["exit"] != 0 and item.get("repoCheck") and not args.base:
            r.update(_compare_at_base(run, run.repo(item.get("repo")), item, r, where, args.timeout))
        passed = passed and (r["exit"] == 0 or r.get("preexisting", False))
        results.append({"name": item["name"], **{k: v for k, v in r.items() if k != "output"}})
    if args.base:
        out(("passed" if passed else "failed") + " at the base; not recorded, since only the feature head is delivered")
    else:
        run.state["verify"] = {"sha": sha, "passed": passed, "results": results}
        run.save()
        out(("PASSED" if passed else "FAILED") + f": verify of {short(sha)} recorded")
    _warn_root_changes(run)
    _sync(run)
    if passed and not args.base:
        out("next: " + _next_step(run, run.phase(sha)))
    return 0 if passed else 1


def _prepare(run: Run, sha, timeout: int) -> bool:
    """Check `sha` out in each repository's verify directory and run the plan's `prepare` there;
    False when a prepare fails."""
    ok = True
    for r in run.repos:
        _checkout(r.path, r.verify_dir, sha_for(sha, r))
        prepare = prepare_for(run.plan, r.name)
        if prepare:
            res = checks.run(prepare, r.verify_dir, timeout)
            if res["exit"] != 0:
                _report(f"[{r.name}] prepare" if run.workspace else "prepare", res)
                ok = False
    return ok


def _compare_at_base(run: Run, repo, item: dict, head: dict, head_dir: Path, timeout: int) -> dict:
    """Run a failing repository check at the base too. It is pre-existing, and does not fail
    the verify, when it fails there as well and the head (run in `head_dir`) adds no output
    line the base lacks."""
    if head["exit"] == 127:  # bash: command not found; the check never ran, wherever it is run
        out("        its command was not found, so it did not run: not compared at the base")
        return {"preexisting": False}
    _checkout(repo.path, repo.base_dir, repo.state["base"]["sha"])
    prepare = prepare_for(run.plan, repo.name)
    if prepare and (res := checks.run(prepare, repo.base_dir, timeout))["exit"] != 0:
        _report("prepare", res)
        return {}
    base = checks.run(item["command"], repo.base_dir, timeout)
    if base["exit"] == 0:
        out("        passes at the base: this change made it fail")
        return {"preexisting": False}
    added = checks.new_lines(head["output"], base["output"], head_dir, repo.base_dir)
    if not added:
        out("        fails at the base too, with no new output: pre-existing, not counted")
        return {"preexisting": True}
    out("        fails at the base too, but these lines are new:\n" + _indent("\n".join(added[:20])))
    return {"preexisting": False, "newLines": added[:50]}


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
    for r in run.repos:
        if (r.state.get("delivered") or {}).get("sha") == sha_for(head, r) and r.state.get("pr"):
            out(f"{f'[{r.name}] ' if run.workspace else ''}delivered {r.state['branch']} at {sha_for(head, r)[:12]}: {r.state['pr']['url']}")
    _sync(run)
    if args.no_feedback or (_config(project).get("feedback") or {}).get("wait") is False:
        return _finish(run, "completed", _summary(run), head)
    out("next: loop-spec feedback (waits for the PR's checks, then reads its review)")
    return 0


def _summary(run: Run) -> str:
    return (run.spec or {}).get("goal") or first_line(run.state.get("request", ""), 100)


def _combine(outcomes: list[str]) -> str:
    """One CI outcome for several PRs: failed, else pending, else passed, else none."""
    return next((o for o in ("failed", "pending", "passed") if o in outcomes), "none")


def cmd_feedback(args, project: Path, cwd: Path) -> int:
    run = find(project, args.slug, cwd)
    head = run.head()
    if head is None:
        raise LoopSpecError("work is missing", "run loop-spec status to restore it")
    targets = [r for r in run.repos if r.state.get("pr") and r.state.get("delivered")]
    if not targets or deliver.undelivered(run, head):
        raise LoopSpecError("the current head has not been delivered", "verify, then `loop-spec deliver`")
    tag = {r.name: f"[{r.name}] " if run.workspace else "" for r in targets}
    call_end = time.monotonic() + args.timeout
    ci_by, failed = {}, False
    for n, r in enumerate(targets):  # once one PR's CI failed, the rest are read once and not waited on
        budget = 0 if failed else args.timeout if n == 0 else max(0, int(call_end - time.monotonic()))
        ci_by[r.name] = ci.wait(r.work, r.state["pr"]["number"], budget, stop=lambda: _wrap_up_asked(run))
        failed = failed or ci_by[r.name][0] == "failed"
    if _wrap_up_asked(run):
        return 0  # main prints the wrap-up step
    for r in targets:
        for c in ci_by[r.name][1]:
            out(f"{tag[r.name]}  {c.get('bucket', '?'):8} {c.get('name', '')}" + (f"  {c['link']}" if c.get("link") else ""))
    outcome = _combine([o for o, _ in ci_by.values()])
    if outcome == "pending":
        out(f"checks are still running after {args.timeout}s: run loop-spec feedback again")
        return 0
    feedback_config = _config(project).get("feedback") or {}
    review_wait = 60 * feedback_config.get("reviewWaitMinutes", 30)
    while True:  # with CI settled and nothing new, wait for reviewers who were asked and have not answered
        rounds = {}
        for r in targets:
            record = r.state.setdefault("feedback", {"seen": []})
            number = r.state["pr"]["number"]
            items, verdicts = review.read(r.work, number)
            new = [i for i in items if i["id"] not in record["seen"]]
            waiting = [] if new or outcome == "failed" else [
                *review.pending(r.work, number),
                *review.silent(items, feedback_config.get("waitFor", []), r.state["delivered"].get("at") or "1970-01-01T00:00:00+00:00")]
            waited_out = bool(waiting) and time.time() >= record.setdefault("reviewWaitSince", time.time()) + review_wait
            rounds[r.name] = (record, verdicts, new, waiting, waited_out)
        if (all(not w or wo for _, _, _, w, wo in rounds.values())
                or time.monotonic() >= call_end or _wrap_up_asked(run)):
            break
        time.sleep(ci.POLL_SECONDS)
    for r in targets:
        record, verdicts, new, _, _ = rounds[r.name]
        record.update(sha=r.state["delivered"]["sha"], ci=ci_by[r.name][0], verdicts=verdicts,
                      seen=record["seen"] + [i["id"] for i in new],
                      authors=sorted({*record.get("authors", []), *(i["author"] for i in new if i.get("author"))}))
    run.save()
    for r in targets:
        for c in ci_by[r.name][1]:
            if c.get("bucket") in ("fail", "cancel") and (log_tail := ci.failure_log(r.work, c)):
                out(f"{tag[r.name]}--- {c.get('name')} (failed log, last lines)\n{_indent(log_tail)}")
        _show_items(rounds[r.name][2], tag[r.name])
    new_all = [i for r in targets for i in rounds[r.name][2]]
    waiting_all = [f"{r.name}:{w}" if run.workspace else w for r in targets for w in rounds[r.name][3]]
    waited_out_all = bool(waiting_all) and all(rounds[r.name][4] for r in targets if rounds[r.name][3])
    if waiting_all and not waited_out_all:
        out(f"CI {outcome}, and review requested from {', '.join(waiting_all)} is not in yet: run loop-spec feedback again")
        return 0
    if waiting_all:
        out(f"review requested from {', '.join(waiting_all)} is still not in after {review_wait // 60} min; not waiting longer")
    skills = (_config(project).get("feedback") or {}).get("skills", [])
    if outcome == "failed" or new_all:
        out(("CI FAILED. " if outcome == "failed" else "") + (f"{len(new_all)} new review item(s). " if new_all else "") +
            "Fix what this change should fix (then verify, deliver, and feedback again), and answer the rest in a "
            "PR comment. A check that also fails on the base branch is not this change's.")
        return 1
    if skills:
        urls = ", ".join(r.state["pr"]["url"] for r in targets)
        out(f"CI {outcome}, and nothing new from reviewers. Run the project's feedback skills on {urls}: "
            f"{', '.join(skills)}. Treat what they report like review comments; if it is nothing, end the run "
            "with loop-spec finish --status completed.")
        return 0
    out("CI passed, and nothing new from reviewers" if outcome == "passed" else "no CI checks, and nothing new from reviewers")
    return _finish(run, "completed", _summary(run), head)


def _show_items(items: list[dict], tag: str = "") -> None:
    for i in items:
        where = f" on {i['path']}:{i.get('line') or '?'}" if i.get("path") else ""
        out(f"{tag}--- {i['kind']} by {i['author']}{where}" + (f"  {i['url']}" if i.get("url") else ""))
        if i.get("body", "").strip():
            out(_indent(i["body"].strip()))


def _config(project: Path) -> dict:
    return read_json(project / ".loop-spec" / "config.json", "config") or {}


def cmd_iterate(args, project: Path, cwd: Path) -> int:
    run = find(project, args.slug, cwd)
    head = run.head()
    if not run.verified_at(head):
        raise LoopSpecError("ITERATE reviews a verified head, and this one is not", "loop-spec verify first")
    run.state["iterate"] = {"sha": head, "caveats": args.caveats}
    run.save()
    out(f"review of {short(head)} recorded" + (f", with caveats: {args.caveats}" if args.caveats else ""))
    _sync(run)
    out("next: " + _next_step(run, run.phase(head)))
    return 0


def cmd_set(args, project: Path, cwd: Path) -> int:
    run = find(project, args.slug, cwd)
    if args.repo and not run.workspace:
        raise LoopSpecError("--repo names one repository of a run across repositories", "leave it out")
    targets = [run.repo(args.repo)] if args.repo else run.repos
    where = f" in {args.repo}" if args.repo else ""
    if args.branch and any(args.branch != r.state["branch"] for r in targets):
        for r in targets:
            if r.state.get("pr") or r.state.get("delivered"):
                raise LoopSpecError(f"{r.state['branch']} is already pushed", "a pushed branch keeps its name")
            if git.exists_anywhere(r.path, args.branch):
                raise LoopSpecError(f"a branch named {args.branch} already exists", "pick another name")
        for r in targets:
            git.run_git(r.work, "branch", "-m", r.state["branch"], args.branch)
            r.state["branch"] = args.branch
        out(f"branch is now {args.branch}{where}")
    if args.title:
        (targets[0].state if args.repo else run.state)["title"] = args.title
        out(f"PR title is now{where}: {args.title}")
    run.save()
    _sync(run)
    return 0


def cmd_checkpoint(args, project: Path, cwd: Path) -> int:
    """Commit what the feature and doing-task worktrees hold (not verified, not merged), and push on request."""
    run = find(project, args.slug, cwd)
    # each with where it started: a branch holding nothing past that is not pushed, since status rebuilds it
    targets = [(r.work, r.state["branch"], r.state["base"]["sha"]) for r in run.repos if r.work.exists()]
    targets += [(run.task_dir(tid), run.task_branch(tid), run.repo(run.task(tid).get("repo")).state["branch"])
                for tid, t in run.state.get("tasks", {}).items()
                if t.get("status") == "doing" and run.task_dir(tid).exists()]
    for dest, branch, start in targets:
        changed = bool(git.dirty(dest))
        if changed:
            git.run_git(dest, "add", "-A")
            git.run_git(dest, "commit", "--quiet", "-m", "wip: loop-spec checkpoint, not verified")
        empty = git.is_ancestor(dest, "HEAD", start)
        out(f"{_rel(run, dest)} {branch} {git.head(dest)[:12]} {'committed' if changed else 'clean'}"
            + (" (not pushed: no commits of its own)" if args.push and empty else ""))
        if args.push and not empty:
            pushed = git.git(dest, "push", "--quiet", "origin", f"HEAD:refs/heads/{branch}")
            if pushed.returncode != 0:
                raise LoopSpecError(f"git push of {branch} was rejected: {pushed.stderr.strip()}",
                                    "if origin moved, merge it in that worktree; never force-push")
    return 0


def cmd_sync(args, project: Path, cwd: Path) -> int:
    run = find(project, args.slug, cwd)
    merged = remote.sync(run)
    for move in merged:
        prefix = f"[{move['repo']}] " if run.workspace else ""
        out(f"{prefix}merged {move['ref']} ({move['commits']} commit{'s' if move['commits'] != 1 else ''})")
    out("next: verify again, since the head moved" if merged else "nothing moved on origin")
    _sync(run)
    return 0


def cmd_hook_stop(args, project: Path, cwd: Path) -> int:
    """The plugin's Stop hook. Never fails the session: any error lets the stop through."""
    try:
        answer = hook.decide(json.loads(sys.stdin.read() or "{}"), _next_step)
    except Exception:  # noqa: BLE001 - a broken hook must never stop someone's session
        return 0
    if answer:
        out(json.dumps(answer))
    return 0


def cmd_hook_post_bash(args, project: Path, cwd: Path) -> int:
    """The plugin's PostToolUse hook for Bash. Never fails the session: any error prints nothing."""
    try:
        lines = hook.stream_gaps(json.loads(sys.stdin.read() or "{}"))
    except Exception:  # noqa: BLE001 - a broken hook must never fail someone's tool call
        return 0
    for line in lines:
        out(line)
    return 0


def cmd_finish(args, project: Path, cwd: Path) -> int:
    run = find(project, args.slug, cwd)
    return _finish(run, args.status, args.summary, run.head())


def _finish(run: Run, status: str, summary: str, head) -> int:
    _sync(run)
    phase = (run.state.get("phaseStream") or {}).get("phase") or "spec"
    for r in run.repos:
        for scratch in (r.verify_dir, r.base_dir):
            git.remove_worktree(r.path, scratch, force=True)
    kept = []
    for task_id, t in run.state.get("tasks", {}).items():
        if t.get("status") == "done":
            _drop_remote_branch(_task_repo(run, task_id).path, run.task_branch(task_id))
    for dest, path in [*((d, _task_repo(run, d.name).path) for d in sorted((run.dir / "tasks").glob("*"))),
                       *((r.work, r.path) for r in run.repos)]:
        if dest.is_dir() and not git.remove_worktree(path, dest):
            out(f"kept {dest}: it has uncommitted changes")
            kept.append(str(dest))
    if run.workspace:  # the directories that held one worktree per repository
        for d in (run.verify_dir, run.dir / "base", run.work):
            try:
                d.rmdir()
            except OSError:
                pass
    result = legacy.record(run, status, summary, head, phase, kept)
    run.finish(result)
    path = legacy.publish(run, result)
    _sync(run)
    phases.result(run, result, path)
    out(f"the run's worktrees are removed; cd {run.project} before any further command")
    return 0


# --- wiring ------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="loop-spec", description="Run state and task graph for a loop-spec run.")
    parser.add_argument("--version", action="version", version=VERSION)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--project-root", help="the repository or workspace root; default: the one holding the current directory")
    common.add_argument("--slug", help="the run; default: the run holding the current directory, or the only open run")
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("start", parents=[common], help="start a run, or resume it if it exists")
    p.add_argument("--request")
    p.add_argument("--request-file")
    p.add_argument("--kind", choices=[k for k in KINDS if k != "revise"], default="cycle")
    p.add_argument("--pr", help="revise this open pull request (number, URL, or branch)")
    p.add_argument("--autonomous", action="store_true",
                   help="no one will answer questions (LOOP_SPEC_MODE=autonomous in the environment does the same)")
    p.add_argument("--supervised", action="store_true",
                   help="a host relays questions: the lead interviews at the spec, skips the approval step, and may stop to ask (LOOP_SPEC_MODE=supervised does the same)")
    p.add_argument("--base", help="branch to start from and target; default: origin's default branch")
    p.add_argument("--branch", help="feature branch name; default: feat/<slug> (fix/<slug> for debug)")
    p.add_argument("--title", help="the PR title; default: the spec's title")
    p.set_defaults(func=cmd_start)

    sub.add_parser("status", parents=[common], help="show a run, or list runs").set_defaults(func=cmd_status)

    task = sub.add_parser("task", help="start, finish, or mark tasks").add_subparsers(dest="action", required=True)
    p = task.add_parser("start", parents=[common], help="a worktree per task from the feature head, prepared; prints each brief")
    p.add_argument("ids", nargs="+")
    # 1200 s: a ceiling for a hung install, well above a cold dependency install.
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
    # 1200 s per command: a ceiling for a hung check, well above a full test suite or build.
    p.add_argument("--timeout", type=int, default=1200, help="seconds per command (default 1200)")
    p.set_defaults(func=cmd_verify)

    p = sub.add_parser("deliver", parents=[common], help="push the verified head, open or update its PR, end the run")
    p.add_argument("--draft", action="store_true")
    p.add_argument("--unverified", action="store_true", help="deliver without a passing verify, as a draft that says so")
    p.add_argument("--comment-file", help="also post this file as a comment on the PR (e.g. replies to review comments)")
    p.add_argument("--no-feedback", action="store_true", help="end the run now instead of waiting for CI and review")
    p.set_defaults(func=cmd_deliver)

    p = sub.add_parser("feedback", parents=[common],
                       help="wait for the delivered PR's checks, then read its review; end the run when both are clear")
    # 540 s returns before Claude Code's 10-minute Bash limit, so the lead sees "run again" instead of a kill.
    p.add_argument("--timeout", type=int, default=540, help="seconds to wait for checks before returning (default 540)")
    p.set_defaults(func=cmd_feedback)

    p = sub.add_parser("iterate", parents=[common],
                       help="record that the verified head's whole-change review is done and addressed (ITERATE)")
    p.add_argument("--caveats", help="what the review left open, carried to the result")
    p.set_defaults(func=cmd_iterate)

    p = sub.add_parser("set", parents=[common], help="rename the feature branch (before it is pushed) or set the PR title")
    p.add_argument("--repo", help="in a run across repositories, set these for this repository only")
    p.add_argument("--branch")
    p.add_argument("--title")
    p.set_defaults(func=cmd_set)

    p = sub.add_parser("checkpoint", parents=[common],
                       help="commit uncommitted work in the feature and task worktrees (unverified); --push sends their branches to origin")
    p.add_argument("--push", action="store_true")
    p.set_defaults(func=cmd_checkpoint)

    p = sub.add_parser("sync", parents=[common], help="merge what moved on origin (base or feature branch) into work")
    p.set_defaults(func=cmd_sync)

    sub.add_parser("hook-stop", parents=[common], help=argparse.SUPPRESS).set_defaults(func=cmd_hook_stop)
    sub.add_parser("hook-post-bash", parents=[common], help=argparse.SUPPRESS).set_defaults(func=cmd_hook_post_bash)

    p = sub.add_parser("finish", parents=[common], help="end a run without delivering")
    p.add_argument("--status", required=True, choices=RESULT_STATUSES)
    p.add_argument("--summary", required=True)
    p.set_defaults(func=cmd_finish)
    return parser


def _remind_wrap_up(args, project: Path, cwd: Path) -> None:
    """A host's wrap-up request reaches the lead on its next command, not only when its turn ends."""
    try:
        run = find(project, getattr(args, "slug", None), cwd)
    except LoopSpecError:
        return
    if _wrap_up_asked(run):
        out(f"next: {WRAP_UP}")


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    cwd = Path(os.getcwd())
    if args.command == "hook-stop":
        return cmd_hook_stop(args, cwd, cwd)  # runs outside any repository too, and never fails
    if args.command == "hook-post-bash":
        return cmd_hook_post_bash(args, cwd, cwd)  # likewise
    try:
        project = run_root(Path(args.project_root).resolve() if args.project_root else cwd)
        code = args.func(args, project, cwd)
        if args.command not in ("finish", "checkpoint", "status"):
            _remind_wrap_up(args, project, cwd)
        return code
    except LoopSpecError as exc:
        log.stderr.error(f"loop-spec: {exc.message}")
        if exc.repair:
            log.stderr.error(f"  next: {exc.repair}")
        return 1
    finally:
        phases.flush()
