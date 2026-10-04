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
from loop_spec.runs import (KINDS, RESULT_STATUSES, Run, all_runs, find, first_free, first_line, read_json, slugify,
                            spec_problems)

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
        "createdAt": legacy.now_iso(),
        "mode": "autonomous" if args.autonomous else "interactive",
        "request": request,
        "base": {"branch": base_branch, "sha": base_sha},
        "branch": branch,
        "title": args.title,
        "pr": pr,
        "instructions": git.instruction_files(project, base_sha),
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
            where = f"done: {result.get('outcome', result.get('status'))}" if result else r.state.get("kind", "")
            out(f"{r.slug:42} {where:22} updated {r.state.get('updatedAt', '?')}")
        if not runs:
            out("loop-spec: no runs in this repository")
        return 0
    return show_status(run)


def _sync(run: Run) -> None:
    """Announce any phase change since the stream last spoke (see phases.py)."""
    try:
        phases.sync(run, git.head(run.work) if run.work.exists() else None)
    except LoopSpecError:
        pass  # a plan that is not a DAG yet: the phase stays where it was


def show_status(run: Run) -> int:
    _sync(run)
    s = run.state
    head = git.head(run.work) if run.work.exists() else None
    try:
        run.tasks
        problem = None
    except LoopSpecError as exc:
        problem = exc.message
    phase = "spec" if run.spec is None or spec_problems(run.spec) else ("plan" if problem else run.phase(head))
    out(f"{run.slug}: {s['kind']}, {run.mode}, phase {phase}")
    out(f"  request  {first_line(s.get('request', ''), 100)}")
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
        if s.get("instructions") and "checks" not in run.plan:
            out("  note     plan.json has no `checks`: list the checks the rules files above require (or [] if none)")
    verify = s.get("verify")
    if verify:
        stale = "" if verify["sha"] == head else f" (the branch has moved to {head[:12] if head else '?'} since)"
        out(f"  verify   {'passed' if verify['passed'] else 'FAILED'} at {verify['sha'][:12]}{stale}")
    if s.get("feedback"):
        f = s["feedback"]
        verdicts = ", ".join(f"{who} {state.lower()}" for who, state in f.get("verdicts", {}).items()) or "no reviews"
        out(f"  feedback CI {f['ci']} at {f['sha'][:12]}; {verdicts}; {len(f['seen'])} review item(s) seen")
    result = run.result
    if result:
        out(f"  result   {result.get('outcome', result.get('status'))}: {result['summary']}")
    _warn_root_changes(run)
    out(f"  next     {_next_step(run, phase, problem)}")
    marker("LOOP_SPEC_RUN", {"slug": run.slug, "kind": s["kind"], "mode": run.mode, "phase": phase,
                             "base": s["base"]["sha"], "runDir": str(run.dir), "work": str(run.work),
                             "prTemplate": str(template) if template else None,
                             "program": str(PROGRAM), "references": str(REFERENCES)})
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


def _step(run: Run, phase: str, problem: str | None) -> str:
    if problem:
        return f"fix {run.plan_path.name}"
    if phase == "spec":
        found = spec_problems(run.spec) if run.spec is not None else []
        if found:
            return f"fix {run.spec_path}: {'; '.join(found)}"
        approve = ", ask the user to approve its criteria (AskUserQuestion)" if run.mode == "interactive" else ""
        return f"write {run.spec_path}{approve}, then loop-spec status; no code before the plan is accepted"
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
        delivered = (run.state.get("delivered") or {}).get("sha") == git.head(run.work)
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
    new = sorted(set(git.dirty(run.project)) - set(run.state.get("rootChanges", [])))
    if new:
        out(f"  warning  files changed in your own checkout during this run, not in a worktree: {', '.join(new[:5])}")


# --- tasks -------------------------------------------------------------------------


def cmd_task_start(args, project: Path, cwd: Path) -> int:
    run = find(project, args.slug, cwd)
    statuses = run.statuses()
    feature_head = git.head(run.work)
    criteria = {c["id"]: c for c in run.checked_spec()["criteria"]}
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
            "checks": [c["command"] for c in checks.repo_checks(run.plan)],
            "prepared": prepare is not None and note is None,
        })
    run.save()
    _sync(run)
    return 0


def cmd_task_done(args, project: Path, cwd: Path) -> int:
    run = find(project, args.slug, cwd)
    task = run.task(args.id)
    dest, branch = run.task_dir(args.id), run.task_branch(args.id)
    if not git.branch_exists(project, branch):  # done by the lead directly in work
        run.set_task(args.id, "done", args.note or "done in work")
        run.save()
        out(f"{args.id} done in work")
        _sync(run)
        out("next: " + _next_step(run, run.phase(git.head(run.work))))
        return 0
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
    _sync(run)
    out("next: " + _next_step(run, run.phase(git.head(run.work))))
    return 0


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
    base_sha = run.state["base"]["sha"]
    sha = base_sha if args.base else git.head(run.work)
    _sync(run)  # a head changed since the last verify enters VERIFY now, so the stream shows it
    if not args.base and (dirty := git.dirty(run.work)):
        out(f"note: uncommitted changes in {run.work} are not part of this verify: {', '.join(dirty[:5])}")
    out(f"verifying {sha[:12]} in a clean checkout ({'the base' if args.base else 'the feature head'})")
    results, passed = [], _prepare(run, run.verify_dir, sha, args.timeout)
    for item in items if passed else []:
        if item["command"] is None:
            out(f"  -     {item['name']:8} no check; judge it in review: {item['text']}")
            results.append({"name": item["name"], "command": None})
            continue
        r = checks.run(item["command"], run.verify_dir, args.timeout)
        _report(item["name"], r)
        if r["exit"] != 0 and item.get("repoCheck") and not args.base:
            r.update(_compare_at_base(run, item, r, base_sha, args.timeout))
        passed = passed and (r["exit"] == 0 or r.get("preexisting", False))
        results.append({"name": item["name"], **{k: v for k, v in r.items() if k != "output"}})
    if args.base:
        out(("passed" if passed else "failed") + " at the base; not recorded, since only the feature head is delivered")
    else:
        run.state["verify"] = {"sha": sha, "passed": passed, "results": results}
        run.save()
        out(("PASSED" if passed else "FAILED") + f": verify of {sha[:12]} recorded")
    _warn_root_changes(run)
    _sync(run)
    if passed and not args.base:
        out("next: " + _next_step(run, run.phase(sha)))
    return 0 if passed else 1


def _prepare(run: Run, dest: Path, sha: str, timeout: int) -> bool:
    """Check `sha` out at `dest` and run the plan's `prepare` there; False when prepare fails."""
    _checkout(run.project, dest, sha)
    prepare = (run.plan or {}).get("prepare")
    if not prepare:
        return True
    r = checks.run(prepare, dest, timeout)
    if r["exit"] != 0:
        _report("prepare", r)
    return r["exit"] == 0


def _compare_at_base(run: Run, item: dict, head: dict, base_sha: str, timeout: int) -> dict:
    """Run a failing repository check at the base too. It is pre-existing, and does not fail
    the verify, when it fails there as well and the head adds no output line the base lacks."""
    base_dir = run.dir / "base"
    if not _prepare(run, base_dir, base_sha, timeout):
        return {}
    base = checks.run(item["command"], base_dir, timeout)
    if base["exit"] == 0:
        out("        passes at the base: this change made it fail")
        return {"preexisting": False}
    added = checks.new_lines(head["output"], base["output"])
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
    out(f"delivered {run.state['branch']} at {head[:12]}: {run.state['pr']['url']}")
    _sync(run)
    if args.no_feedback or (_config(project).get("feedback") or {}).get("wait") is False:
        return _finish(run, "completed", _summary(run), head)
    out("next: loop-spec feedback (waits for the PR's checks, then reads its review)")
    return 0


def _summary(run: Run) -> str:
    return (run.spec or {}).get("goal") or first_line(run.state.get("request", ""), 100)


def cmd_feedback(args, project: Path, cwd: Path) -> int:
    run = find(project, args.slug, cwd)
    delivered, pr = run.state.get("delivered"), run.state.get("pr")
    head = git.head(run.work)
    if not delivered or not pr or delivered["sha"] != head:
        raise LoopSpecError("the current head has not been delivered", "verify, then `loop-spec deliver`")
    call_end = time.monotonic() + args.timeout
    outcome, found = ci.wait(run.work, pr["number"], args.timeout)
    for c in found:
        out(f"  {c.get('bucket', '?'):8} {c.get('name', '')}" + (f"  {c['link']}" if c.get("link") else ""))
    if outcome == "pending":
        out(f"checks are still running after {args.timeout}s: run loop-spec feedback again")
        return 0
    record = run.state.setdefault("feedback", {"seen": []})
    review_wait = 60 * (_config(project).get("feedback") or {}).get("reviewWaitMinutes", 30)
    while True:  # with CI settled and nothing new, wait for reviewers who were asked and have not answered
        items, verdicts = review.read(run.work, pr["number"])
        new = [i for i in items if i["id"] not in record["seen"]]
        waiting = [] if new or outcome == "failed" else review.pending(run.work, pr["number"])
        waited_out = bool(waiting) and time.time() >= record.setdefault("reviewWaitSince", time.time()) + review_wait
        if not waiting or waited_out or time.monotonic() >= call_end:
            break
        time.sleep(ci.POLL_SECONDS)
    record.update(sha=head, ci=outcome, verdicts=verdicts, seen=record["seen"] + [i["id"] for i in new],
                  authors=sorted({*record.get("authors", []), *(i["author"] for i in new if i.get("author"))}))
    run.save()
    for c in found:
        if c.get("bucket") in ("fail", "cancel") and (log_tail := ci.failure_log(run.work, c)):
            out(f"--- {c.get('name')} (failed log, last lines)\n{_indent(log_tail)}")
    for i in new:
        where = f" on {i['path']}:{i.get('line') or '?'}" if i.get("path") else ""
        out(f"--- {i['kind']} by {i['author']}{where}" + (f"  {i['url']}" if i.get("url") else ""))
        if i.get("body", "").strip():
            out(_indent(i["body"].strip()))
    if waiting and not waited_out:
        out(f"CI {outcome}, and review requested from {', '.join(waiting)} is not in yet: run loop-spec feedback again")
        return 0
    if waiting:
        out(f"review requested from {', '.join(waiting)} is still not in after {review_wait // 60} min; not waiting longer")
    skills = (_config(project).get("feedback") or {}).get("skills", [])
    if outcome == "failed" or new:
        out(("CI FAILED. " if outcome == "failed" else "") + (f"{len(new)} new review item(s). " if new else "") +
            "Fix what this change should fix (then verify, deliver, and feedback again), and answer the rest in a "
            "PR comment. A check that also fails on the base branch is not this change's.")
        return 1
    if skills:
        out(f"CI {outcome}, and nothing new from reviewers. Run the project's feedback skills on {pr['url']}: "
            f"{', '.join(skills)}. Treat what they report like review comments; if it is nothing, end the run "
            "with loop-spec finish --status completed.")
        return 0
    out("CI passed, and nothing new from reviewers" if outcome == "passed" else "no CI checks, and nothing new from reviewers")
    return _finish(run, "completed", _summary(run), head)


def _config(project: Path) -> dict:
    return read_json(project / ".loop-spec" / "config.json", "config") or {}


def cmd_iterate(args, project: Path, cwd: Path) -> int:
    run = find(project, args.slug, cwd)
    head = git.head(run.work)
    if not run.verified_at(head):
        raise LoopSpecError("ITERATE reviews a verified head, and this one is not", "loop-spec verify first")
    run.state["iterate"] = {"sha": head, "caveats": args.caveats}
    run.save()
    out(f"review of {head[:12]} recorded" + (f", with caveats: {args.caveats}" if args.caveats else ""))
    _sync(run)
    out("next: " + _next_step(run, run.phase(head)))
    return 0


def cmd_set(args, project: Path, cwd: Path) -> int:
    run = find(project, args.slug, cwd)
    state = run.state
    if args.branch and args.branch != state["branch"]:
        if state.get("pr") or state.get("delivered"):
            raise LoopSpecError(f"{state['branch']} is already pushed", "a pushed branch keeps its name")
        if git.branch_exists(project, args.branch):
            raise LoopSpecError(f"a branch named {args.branch} already exists", "pick another name")
        git.run_git(run.work, "branch", "-m", state["branch"], args.branch)
        state["branch"] = args.branch
        out(f"branch is now {args.branch}")
    if args.title:
        state["title"] = args.title
        out(f"PR title is now: {args.title}")
    run.save()
    _sync(run)
    return 0


def cmd_sync(args, project: Path, cwd: Path) -> int:
    run = find(project, args.slug, cwd)
    merged = remote.sync(run)
    for move in merged:
        out(f"merged {move['ref']} ({move['commits']} commit{'s' if move['commits'] != 1 else ''})")
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


def cmd_finish(args, project: Path, cwd: Path) -> int:
    run = find(project, args.slug, cwd)
    return _finish(run, args.status, args.summary, git.head(run.work) if run.work.exists() else None)


def _finish(run: Run, status: str, summary: str, head: str | None) -> int:
    _sync(run)
    phase = (run.state.get("phaseStream") or {}).get("phase") or "spec"
    for scratch in (run.verify_dir, run.dir / "base"):
        git.remove_worktree(run.project, scratch, force=True)
    kept = []
    for dest in [*sorted((run.dir / "tasks").glob("*")), run.work]:
        if dest.is_dir() and not git.remove_worktree(run.project, dest):
            out(f"kept {dest}: it has uncommitted changes")
            kept.append(str(dest))
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
    p.add_argument("--branch")
    p.add_argument("--title")
    p.set_defaults(func=cmd_set)

    p = sub.add_parser("sync", parents=[common], help="merge what moved on origin (base or feature branch) into work")
    p.set_defaults(func=cmd_sync)

    sub.add_parser("hook-stop", parents=[common], help=argparse.SUPPRESS).set_defaults(func=cmd_hook_stop)

    p = sub.add_parser("finish", parents=[common], help="end a run without delivering")
    p.add_argument("--status", required=True, choices=RESULT_STATUSES)
    p.add_argument("--summary", required=True)
    p.set_defaults(func=cmd_finish)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    cwd = Path(os.getcwd())
    if args.command == "hook-stop":
        return cmd_hook_stop(args, cwd, cwd)  # runs outside any repository too, and never fails
    try:
        project = git.project_root(Path(args.project_root).resolve() if args.project_root else cwd)
        return args.func(args, project, cwd)
    except LoopSpecError as exc:
        log.stderr.error(f"loop-spec: {exc.message}")
        if exc.repair:
            log.stderr.error(f"  next: {exc.repair}")
        return 1
