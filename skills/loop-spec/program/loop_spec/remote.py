"""What moved on origin since the run last looked, and merging it into the feature branch.

Two things can move under a run: the base branch (teammates merge to main) and the
feature branch itself on origin (a teammate or a bot pushed to the PR). Both are
merged into the feature worktree, never rebased, so commits already reviewed or pushed
keep their SHAs and the next push is a fast-forward.
"""
from loop_spec import git
from loop_spec.errors import LoopSpecError
from loop_spec.runs import Repo, Run


def retarget(run: Run, repo: Repo) -> None:
    """When the branch this run stacks on merged and left origin, move the run onto that branch's own base.
    The one change on origin a refused deliver may make: the PR's base, which records the same fact."""
    stacked = repo.state.get("stackedOn") or run.state.get("stackedOn")
    if not stacked or not merged_away(repo.work, repo.state["base"]["branch"], stacked["pr"],
                                      "end the run with loop-spec finish --status escalated and start it again on the right base"):
        return
    work = repo.work
    repo.state["base"]["branch"] = stacked["base"]
    run.state.pop("stackedOn", None)
    if repo.state.get("pr"):
        git.pr_set_base(work, repo.state["pr"]["number"], stacked["base"])
    run.save()


def merged_away(work, branch: str, pr: dict, fix: str) -> bool:
    """Whether `branch` left origin because its PR merged. False while origin has it (or there is no
    origin); raises when it is gone and its PR did not merge."""
    if not git.has_origin(work) or git.remote_has(work, branch):
        return False
    if git.gh_json(work, "pr", "view", str(pr["number"]), "--json", "state").get("state") != "MERGED":
        raise LoopSpecError(f"origin/{branch} is gone and its PR {pr['url']} did not merge", fix)
    return True


def moves(run: Run, repo: Repo) -> list[dict]:
    """Fetch origin's base and feature branches; return each one the feature head does not contain."""
    retarget(run, repo)
    work, base, branch = repo.work, repo.state["base"]["branch"], repo.state["branch"]
    if not git.has_origin(work):
        return []
    found = []
    for what, name in (("base", base), ("branch", branch)):
        git.fetch(work, git.tracking(name))  # a branch origin does not have yet is simply absent
        tip = git.remote_tip(work, name)
        if tip and not git.is_ancestor(work, tip, "HEAD"):
            if what == "branch" and repo.state.get("pr") is None:
                raise LoopSpecError(f"origin/{name} has commits this run never had: it belongs to other work",
                                    "give this run its own branch: loop-spec set --branch NAME")
            found.append({"repo": repo.name, "what": what, "ref": f"origin/{name}", "sha": tip,
                          "commits": len(git.commits(work, f"HEAD..{tip}"))})
    return found


def describe(move: dict) -> str:
    return f"{move['ref']} has {move['commits']} commit{'s' if move['commits'] != 1 else ''} the feature branch does not"


def sync(run: Run) -> list[dict]:
    """Merge every move into the feature worktrees. Raises on a conflict, leaving the
    merge in progress in the worktree for the lead to resolve and commit."""
    for r in run.repos:
        if git.git(r.work, "rev-parse", "--verify", "--quiet", "MERGE_HEAD").returncode == 0:
            raise LoopSpecError(f"a merge is still in progress in {r.work}",
                                "resolve the conflicts, `git commit --no-edit` there, then run sync again")
        git.require_clean(r.work, "the feature worktree", f"commit or discard them in {r.work}, then sync")
    merged = []
    for r in run.repos:
        work = r.work
        for move in moves(run, r):
            proc = git.git(work, "merge", "--no-edit", "-m", f"Merge {move['ref']} into {r.state['branch']}", move["sha"])
            if proc.returncode != 0:
                conflicts = git.run_git(work, "diff", "--name-only", "--diff-filter=U").split()
                raise LoopSpecError(f"merging {move['ref']} conflicts in: {', '.join(conflicts) or proc.stderr.strip()}",
                                    f"resolve them in {work} keeping both sides' intent, `git commit --no-edit`, then run sync again")
            merged.append(move)
        base_tip = git.remote_tip(work, r.state["base"]["branch"])
        if base_tip and git.is_ancestor(work, base_tip, "HEAD"):
            r.state["base"]["sha"] = base_tip  # the base the change now sits on, also after a resolved conflict
    run.save()
    return merged
