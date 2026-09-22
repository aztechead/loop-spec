"""DELIVER's default implementation (M5): push each touched repo's feature branch
and open or update its PR.

Use `run` as the whole-run entry point: DELIVER dispatches no worker step, so unlike
`execute.py`/`verify.py` there is no per-call chunking, just one pass over every repo.
`Pause` is imported for interface symmetry with the other phase modules; no scenario
here needs it, since an out-of-band remote move maps to a normal `delivery blocked`
product exit, the same way EXECUTE's `blocked` exit is a product, not a raw pause.
"""
import json
from pathlib import Path

from . import render
from . import repo as repo_module
from .contract import load_config
from .errors import LoopSpecError
from .execute import Pause, Product  # noqa: F401 -- Pause kept for interface symmetry
from .ids import now_iso


def _touched_repos(store) -> dict:
    heads = store.state["products"]["execute"]["product"].get("heads", {})
    touched = {}
    for name, repo_info in store.state["repos"].items():
        head = heads.get(name)
        if head and repo_module.commits_between(Path(repo_info["path"]), repo_info["baseSha"], head):
            touched[name] = head
    return touched


def pr_title(title: str, limit: int = 70) -> str:
    # GitHub shows about 70 characters of a title; a cut mid-word read as a typo
    # in the live debug run (LF-36), so cut at the last word boundary that fits.
    if len(title) <= limit:
        return title
    head = title[: limit - 3].rsplit(" ", 1)[0].rstrip(" ,;:.")
    return head + "..."


def _reconcile_pr(store, repo_name: str, worktree: Path, repo_info: dict, base: str,
                   draft: bool, title: str, body: str) -> tuple[dict | None, str | None]:
    branch = repo_info["featureBranch"]
    code, out, err = repo_module.run_gh(worktree, "pr", "list", "--head", branch, "--state", "open",
                                         "--json", "number,url,headRefOid,baseRefName")
    if code != 0:
        return None, f"gh pr list failed: {err.strip()}"

    if not json.loads(out):
        # A crash-recovery marker, not a control-flow gate: `gh pr list` above already
        # reconciles a lost create response on its own, so nothing reads this back.
        store.state.setdefault("deliverCreating", {})[repo_name] = {"at": now_iso(), "branch": branch}
        store.save()
        body_path = Path(worktree) / ".loop-spec-pr-body.md"
        body_path.write_text(body)
        args = ["pr", "create", "--base", base, "--head", branch, "--title", pr_title(title), "--body-file", str(body_path)]
        if draft:
            args.append("--draft")
        code, _, err = repo_module.run_gh(worktree, *args)
        if code != 0:
            return None, f"gh pr create failed: {err.strip()}"
        store.state["deliverCreating"].pop(repo_name, None)
        store.save()

    code, out, err = repo_module.run_gh(worktree, "pr", "view", branch,
                                         "--json", "number,url,headRefName,headRefOid,baseRefName")
    if code != 0:
        return None, f"gh pr view failed: {err.strip()}"
    data = json.loads(out)
    return {"number": data["number"], "url": data["url"], "headRef": data["headRefName"],
            "headSha": data["headRefOid"], "base": data["baseRefName"]}, None


def run(store, paths, ctx):
    project_root = Path(ctx["paths"]["projectRoot"])
    config = load_config(project_root)
    iterate_exit = store.state["products"]["iterate"]["exit"]
    entry_payload = (ctx.get("entry") or {}).get("payload") or {}
    draft = bool(entry_payload.get("draft")) or iterate_exit == "converged with caveats"
    credential_checks = store.state.get("credentialChecks") or {}
    spec_product = store.state["products"]["spec"]["product"]
    slug = store.state["run"].get("slug") or "run"

    touched = _touched_repos(store)
    repos_out = []
    blocked = None

    for repo_name, repo_info in store.state["repos"].items():
        if repo_name not in touched:
            repos_out.append({"repo": repo_name, "pr": None, "deliveredSha": None, "caveats": [], "state": "skipped"})
            continue

        check = credential_checks.get(repo_name) or {}
        if not (check.get("git_ok") and check.get("gh_ok")):
            failed_tool = "git" if not check.get("git_ok") else "gh"
            reason = f"the {failed_tool} credential check failed: {check.get('failedCommand')}; repair: {check.get('repair')}"
            repos_out.append({"repo": repo_name, "pr": None, "deliveredSha": None, "caveats": [reason], "state": "failed"})
            blocked = True
            break

        # EXECUTE never commits into the operator's own checkout (repo_info["path"]);
        # its own worktrees/feature/<repo> is where the pushed commits actually live.
        execute_repos = (store.state.get("execute") or {}).get("repos") or {}
        execute_repo = execute_repos.get(repo_name)
        worktree = Path(execute_repo["worktree"]) if execute_repo else Path(repo_info["path"])
        push = repo_module._git(worktree, "push", "-u", "origin", repo_info["featureBranch"])
        if push.returncode != 0:
            reason = (f"push rejected: {push.stderr.strip()}; repair: fetch, resolve the "
                      "out-of-band change, and resume (never force)")
            repos_out.append({"repo": repo_name, "pr": None, "deliveredSha": None, "caveats": [reason], "state": "failed"})
            blocked = True
            break

        pr, error = _reconcile_pr(store, repo_name, worktree, repo_info, repo_info["defaultBranch"], draft,
                                   spec_product["goal"], render.pr_body(store))
        if error:
            repos_out.append({"repo": repo_name, "pr": None, "deliveredSha": None, "caveats": [error], "state": "failed"})
            continue
        repos_out.append({"repo": repo_name, "pr": pr, "deliveredSha": touched[repo_name], "caveats": [], "state": "delivered"})

    exit_ = "delivery blocked" if blocked else (
        "partially delivered" if any(r["state"] == "failed" for r in repos_out) else "delivered"
    )
    bound_to = {"requirements": store.state["revisions"]["requirements"], "plan": store.state["revisions"]["plan"]}
    return Product({"exit": exit_, "inputsDigest": ctx["inputs"]["digest"], "boundTo": bound_to, "repos": repos_out})
