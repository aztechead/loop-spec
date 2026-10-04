"""Push the feature branch and open or update its pull request with a body built from the run."""
from pathlib import Path

from loop_spec import git
from loop_spec.errors import LoopSpecError
from loop_spec.runs import Run

MARK = {True: "pass", False: "fail", None: "not checked"}


def title(run: Run) -> str:
    request = run.state.get("request", "").strip().splitlines()
    text = (run.spec() or {}).get("title") or (request[0] if request else run.slug)
    return text if len(text) <= 70 else text[:67].rstrip() + "..."


def body(run: Run, verified: bool) -> str:
    spec, plan = run.spec() or {}, run.plan() or {}
    verify = run.state.get("verify") or {}
    by_name = {r["name"]: r for r in verify.get("results", [])}
    lines = ["## Summary", "", spec.get("goal") or run.state.get("request", ""), ""]
    criteria = spec.get("criteria", [])
    if criteria:
        lines += ["## Acceptance criteria", "", "| | Criterion | Check |", "|---|---|---|"]
        for c in criteria:
            r = by_name.get(c.get("id"))
            ok = None if r is None or r.get("command") is None else r.get("exit") == 0
            check = f"`{c['check']}`" if c.get("check") else "reviewed, no command"
            lines.append(f"| {MARK[ok]} | **{c.get('id', '')}** {_cell(c.get('text', ''))} | {_cell(check)} |")
        lines.append("")
    tasks = plan.get("tasks", [])
    if tasks:
        lines += ["## Tasks", ""]
        lines += [f"- **{t['id']}** {t.get('title', '')}" for t in tasks]
        lines.append("")
    for key, heading in (("decisions", "Decisions"), ("assumptions", "Assumptions")):
        if spec.get(key):
            lines += [f"## {heading}", "", *[f"- {item}" for item in spec[key]], ""]
    lines += ["## Verification", ""]
    if verified:
        lines.append(f"Every check above was run by loop-spec in a clean checkout of `{verify['sha'][:12]}`, the commit this PR delivers.")
    else:
        lines.append("**Not verified.** This head was delivered without a passing loop-spec verify; treat it as a draft.")
    lines += ["", "_Delivered by loop-spec._"]
    return "\n".join(lines) + "\n"


def _cell(text: str) -> str:
    return text.replace("|", "\\|").replace("\n", " ")


def publish(run: Run, *, draft: bool, unverified: bool) -> dict:
    """Push the feature branch and open or update its PR. Returns {"number", "url"}."""
    state, work = run.state, run.work
    head = git.head(work)
    verify = state.get("verify") or {}
    verified = bool(verify.get("passed")) and verify.get("sha") == head
    if not verified and not unverified:
        why = "no verify has run" if not verify else (
            "the last verify failed" if not verify.get("passed") else f"verify ran on {verify['sha'][:12]}, but the branch is now at {head[:12]}")
        raise LoopSpecError(f"refusing to deliver an unverified head: {why}",
                            "run `loop-spec verify`, or pass --unverified to open a draft PR that says it is unverified")
    if not git.commits(work, f"{state['base']['sha']}..{head}"):
        raise LoopSpecError("the feature branch has no commits beyond its base; there is nothing to deliver",
                            "finish the run with `loop-spec finish --status no-change --summary ...`")
    if dirty := git.dirty(work):
        raise LoopSpecError(f"the integration worktree has uncommitted changes: {', '.join(dirty[:5])}",
                            f"commit or discard them in {work}, then verify again")
    if not git.has_origin(work):
        raise LoopSpecError("the repository has no origin remote", "add one with `git remote add origin <url>`")

    branch = state["branch"]
    push = git.git(work, "push", "--quiet", "-u", "origin", f"HEAD:refs/heads/{branch}")
    if push.returncode != 0:
        raise LoopSpecError(f"git push was rejected: {push.stderr.strip()}",
                            f"if origin/{branch} moved, merge it in {work}, run verify again, then deliver; never force-push")

    text_path = run.dir / "pr-body.md"
    text_path.write_text(body(run, verified))
    pr = state.get("pr")
    if pr is None:
        existing = git.gh_json(work, "pr", "list", "--head", branch, "--state", "open", "--json", "number,url")
        pr = existing[0] if existing else None
    if pr is None:
        config = state.get("config", {})
        args = ["pr", "create", "--base", state["base"]["branch"], "--head", branch, "--title", title(run),
                "--body-file", str(text_path), "--assignee", "@me"]
        if draft or not verified:
            args.append("--draft")
        for reviewer in config.get("reviewers", []):
            args += ["--reviewer", reviewer]
        for label in config.get("labels", []):
            args += ["--label", label]
        code, _, err = git.gh(work, *args)
        if code != 0:
            raise LoopSpecError(f"gh pr create failed: {err.strip()}", "check `gh auth status`; the branch is pushed, so deliver again once fixed")
        pr = git.gh_json(work, "pr", "view", branch, "--json", "number,url")
    elif state.get("kind") != "revise":
        git.gh(work, "pr", "edit", str(pr["number"]), "--title", title(run), "--body-file", str(text_path))
    state["pr"] = {"number": pr["number"], "url": pr["url"]}
    state["delivered"] = {"sha": head, "verified": verified}
    run.save()
    return state["pr"]


def adopt_pr(project: Path, ref: str) -> dict:
    """An open PR's number, url, head branch, and base branch, for a revise run."""
    pr = git.gh_json(project, "pr", "view", ref, "--json", "number,url,headRefName,baseRefName,state,isCrossRepository")
    if pr.get("state") != "OPEN":
        raise LoopSpecError(f"PR {ref} is {pr.get('state', 'not open')}", "revise works on an open PR")
    if pr.get("isCrossRepository"):
        raise LoopSpecError(f"PR {ref} comes from a fork", "check the fork out yourself; loop-spec revises same-repository PRs")
    return pr
