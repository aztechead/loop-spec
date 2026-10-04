"""What moved on origin since the run last looked, and merging it into the feature branch.

Two things can move under a run: the base branch (teammates merge to main) and the
feature branch itself on origin (a teammate or a bot pushed to the PR). Both are
merged into the feature worktree, never rebased, so commits already reviewed or pushed
keep their SHAs and the next push is a fast-forward.
"""
from loop_spec import git
from loop_spec.errors import LoopSpecError
from loop_spec.runs import Run


def moves(run: Run) -> list[dict]:
    """Fetch origin's base and feature branches; return each one the feature head does not contain."""
    work, base, branch = run.work, run.state["base"]["branch"], run.state["branch"]
    if not git.has_origin(work):
        return []
    found = []
    for what, name in (("base", base), ("branch", branch)):
        git.fetch(work, git.tracking(name))  # a branch origin does not have yet is simply absent
        tip = git.remote_tip(work, name)
        if tip and not git.is_ancestor(work, tip, "HEAD"):
            found.append({"what": what, "ref": f"origin/{name}", "sha": tip,
                          "commits": len(git.commits(work, f"HEAD..{tip}"))})
    return found


def describe(move: dict) -> str:
    return f"{move['ref']} has {move['commits']} commit{'s' if move['commits'] != 1 else ''} the feature branch does not"


def sync(run: Run) -> list[dict]:
    """Merge every move into the feature worktree. Raises on a conflict, leaving the
    merge in progress in the worktree for the lead to resolve and commit."""
    work = run.work
    if git.git(work, "rev-parse", "--verify", "--quiet", "MERGE_HEAD").returncode == 0:
        raise LoopSpecError(f"a merge is still in progress in {work}",
                            "resolve the conflicts, `git commit --no-edit` there, then run sync again")
    git.require_clean(work, "the feature worktree", f"commit or discard them in {work}, then sync")
    merged = []
    for move in moves(run):
        proc = git.git(work, "merge", "--no-edit", "-m", f"Merge {move['ref']} into {run.state['branch']}", move["sha"])
        if proc.returncode != 0:
            conflicts = git.run_git(work, "diff", "--name-only", "--diff-filter=U").split()
            raise LoopSpecError(f"merging {move['ref']} conflicts in: {', '.join(conflicts) or proc.stderr.strip()}",
                                f"resolve them in {work} keeping both sides' intent, `git commit --no-edit`, then run sync again")
        merged.append(move)
    base_tip = git.remote_tip(work, run.state["base"]["branch"])
    if base_tip and git.is_ancestor(work, base_tip, "HEAD"):
        run.state["base"]["sha"] = base_tip  # the base the change now sits on, also after a resolved conflict
    run.save()
    return merged
