"""Push the feature branch and open or update its pull request with a body built from the run."""
from pathlib import Path

from loop_spec import git, remote, review
from loop_spec.errors import LoopSpecError
from loop_spec.runs import Run, first_line, read_json

MARK = {True: "pass", False: "fail", None: "not checked"}


def title(run: Run) -> str:
    """The run's own title (start --title), else the spec's, else the request's first line."""
    return first_line(run.state.get("title") or (run.spec or {}).get("title") or run.state.get("request") or run.slug, 70)


VISUAL_PR = Path(__file__).resolve().parents[2] / "references" / "visual-pr" / "pr_description_template.md"
REPO_TEMPLATES = (".github/pull_request_template.md", ".github/PULL_REQUEST_TEMPLATE.md", "PULL_REQUEST_TEMPLATE.md",
                  "pull_request_template.md", "docs/pull_request_template.md", "docs/PULL_REQUEST_TEMPLATE.md")


def pr_template(worktree: Path) -> Path:
    """The template `pr.md` follows: the repository's own PR template when it has one,
    else the bundled visual-pr format."""
    for name in REPO_TEMPLATES:
        if (worktree / name).is_file():
            return worktree / name
    folder = worktree / ".github" / "PULL_REQUEST_TEMPLATE"
    found = sorted(folder.glob("*.md")) if folder.is_dir() else []
    return found[0] if found else VISUAL_PR


def pr_guides(run: Run) -> list[Path]:
    """What to read to write `pr.md`, while it is still to be written: its template. Nothing
    for an adopted PR, whose description stays."""
    if (run.state.get("pr") or {}).get("adopted") or (run.dir / "pr.md").is_file() or not run.work.exists():
        return []
    return [pr_template(run.work)]


def template_leftovers(text: str, template: Path) -> list[str]:
    """Lines of `pr.md` that are still the template's own `{...}` placeholder lines."""
    placeholders = {line.strip() for line in template.read_text().splitlines() if "{" in line and "}" in line}
    return [line.strip() for line in text.splitlines() if line.strip() in placeholders]


def body(run: Run, verified: bool) -> str:
    """The PR description: the lead's `pr.md`, then the criteria and how verify showed them,
    folded so the description stays the shape its template gives it."""
    return run.dir.joinpath("pr.md").read_text().rstrip() + "\n\n" + "\n".join(_verification(run, verified)) + "\n"


def _verification(run: Run, verified: bool) -> list[str]:
    spec, verify = run.spec or {}, run.state.get("verify") or {}
    by_name = {r["name"]: r for r in verify.get("results", [])}
    head = (f"checked in a clean checkout of `{verify['sha'][:12]}`, the commit this PR delivers" if verified
            else "NOT verified: delivered without a passing verify")
    lines = ["<details>", f"<summary>Acceptance criteria: {head}</summary>", ""]
    if spec.get("criteria"):
        lines += ["| | Criterion | Check |", "|---|---|---|"]
        for c in spec["criteria"]:
            r = by_name.get(c.get("id"))
            ok = None if r is None or r.get("command") is None else r.get("exit") == 0
            check = f"`{c['check']}`" if c.get("check") else "no command; judged in review"
            lines.append(f"| {MARK[ok]} | **{c.get('id', '')}** {_cell(c.get('text', ''))} | {_cell(check)} |")
    return lines + ["", "_Delivered by loop-spec._", "</details>"]


def _cell(text: str) -> str:
    return text.replace("|", "\\|").replace("\n", " ")


def publish(run: Run, *, draft: bool, unverified: bool, comment_file: Path | None) -> str:
    """Push the feature branch, open or update its PR, and optionally comment on it.
    Returns the delivered head SHA; the PR is recorded in run.state["pr"]."""
    state, work = run.state, run.work
    head = git.head(work)
    verified = run.verified_at(head)
    if not verified and not unverified:
        verify = state.get("verify")
        why = "no verify has run" if not verify else (
            "the last verify failed" if not verify["passed"] else f"verify ran on {verify['sha'][:12]}, but the branch is now at {head[:12]}")
        raise LoopSpecError(f"refusing to deliver an unverified head: {why}",
                            "run `loop-spec verify`, or pass --unverified to open a draft PR that says it is unverified")
    if not unverified and (state.get("iterate") or {}).get("sha") != head:
        raise LoopSpecError("this head has no recorded review (ITERATE)",
                            "review the whole change, address what it finds, then `loop-spec iterate` and deliver")
    if not git.commits(work, f"{state['base']['sha']}..{head}"):
        raise LoopSpecError("the feature branch has no commits beyond its base; there is nothing to deliver",
                            "end the run with `loop-spec finish --status no-change --summary ...`")
    git.require_clean(work, "the feature worktree", f"commit or discard them in {work}, then verify again")
    adopted = (state.get("pr") or {}).get("adopted")
    if not adopted and not (run.dir / "pr.md").is_file():
        raise LoopSpecError(f"there is no PR description at {run.dir / 'pr.md'}",
                            f"write it following {pr_template(work)}, then deliver again")
    if not adopted and (left := template_leftovers((run.dir / "pr.md").read_text(), pr_template(work))):
        raise LoopSpecError(f"pr.md still has {len(left)} line(s) of the template's placeholders, such as: {left[0][:100]}",
                            "replace each with what this change does, or delete it, then deliver again")
    if not git.has_origin(work):
        raise LoopSpecError("the repository has no origin remote", "add one with `git remote add origin <url>`")
    code, _, err = git.gh(work, "auth", "status")
    if code != 0:  # checked before the push, so a missing gh changes nothing on origin
        raise LoopSpecError(f"gh cannot open the PR: {err.strip().splitlines()[0] if err.strip() else 'gh auth status failed'}",
                            "install gh and run `gh auth login`, then deliver again")
    moved = remote.moves(run)
    if moved:
        raise LoopSpecError("origin moved since this head was verified: " + "; ".join(remote.describe(m) for m in moved),
                            "run `loop-spec sync` to merge it in, then verify and deliver again")

    branch = state["branch"]
    push = git.git(work, "push", "--quiet", "-u", "origin", f"HEAD:refs/heads/{branch}")
    if push.returncode != 0:
        raise LoopSpecError(f"git push was rejected: {push.stderr.strip()}",
                            f"if origin/{branch} moved, merge it in {work}, verify again, then deliver; never force-push")

    body_path = run.dir / "pr-body.md"
    body_path.write_text(body(run, verified))
    pr = state.get("pr")
    if pr is None:
        existing = git.gh_json(work, "pr", "list", "--head", branch, "--state", "open", "--json", "number,url")
        pr = existing[0] if existing else None
    if pr is None:
        pr = _create(run, branch, body_path, draft=draft or not verified)
    elif not pr.get("adopted"):
        git.gh(work, "pr", "edit", str(pr["number"]), "--title", title(run), "--body-file", str(body_path))
    state["pr"] = pr
    state["delivered"] = {"sha": head, "verified": verified}
    run.save()
    if comment_file:
        reply = f"{comment_file.read_text().rstrip()}\n\n{review.MARK}\n"
        code, _, err = git.gh(work, "pr", "comment", str(pr["number"]), "--body", reply)
        if code != 0:
            raise LoopSpecError(f"the PR was delivered, but gh pr comment failed: {err.strip()}",
                                f"run loop-spec deliver --comment-file {comment_file} again")
    return head


def _create(run: Run, branch: str, body_path: Path, *, draft: bool) -> dict:
    config = read_json(run.project / ".loop-spec" / "config.json", "config") or {}
    args = ["pr", "create", "--base", run.state["base"]["branch"], "--head", branch, "--title", title(run),
            "--body-file", str(body_path), "--assignee", "@me", *(["--draft"] if draft else [])]
    for reviewer in config.get("reviewers", []):
        args += ["--reviewer", reviewer]
    for label in config.get("labels", []):
        args += ["--label", label]
    code, out, err = git.gh(run.work, *args)
    if code != 0:
        raise LoopSpecError(f"gh pr create failed: {err.strip()}", "check `gh auth status`; the branch is pushed, so deliver again once fixed")
    url = out.strip().splitlines()[-1]
    return {"number": int(url.rstrip("/").rsplit("/", 1)[1]), "url": url}


def adopt_pr(project: Path, ref: str) -> dict:
    """An open PR's number, url, head branch, and base branch, for a revise run."""
    pr = git.gh_json(project, "pr", "view", ref, "--json", "number,url,headRefName,baseRefName,state,isCrossRepository")
    if pr.get("state") != "OPEN":
        raise LoopSpecError(f"PR {ref} is {pr.get('state', 'not open')}", "revise works on an open PR")
    if pr.get("isCrossRepository"):
        raise LoopSpecError(f"PR {ref} comes from a fork", "check the fork out yourself; loop-spec revises same-repository PRs")
    return pr
