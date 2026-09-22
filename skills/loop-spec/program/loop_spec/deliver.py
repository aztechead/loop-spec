"""DELIVER's default implementation (M5): push each touched repo's feature branch
and open or update its PR.

Use `run` as the whole-run entry point: DELIVER dispatches no worker step, so unlike
`execute.py`/`verify.py` there is no per-call chunking, just one pass over every repo.
`Pause` is imported for interface symmetry with the other phase modules; no scenario
here needs it, since an out-of-band remote move maps to a normal `delivery blocked`
product exit, the same way EXECUTE's `blocked` exit is a product, not a raw pause.
"""
import json
import re
import tempfile
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
        # LF-48: the body file lives outside the worktree; an untracked file inside it
        # made the feature checkout "dirty" and terminal cleanup kept it as backlog.
        body_path = Path(tempfile.mkstemp(prefix="loop-spec-pr-body-", suffix=".md")[1])
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


def _push_repair(stderr: str) -> str:
    # A non-zero push is not always a non-fast-forward (LF-58: an unreachable remote
    # read as "resolve the out-of-band change"); name the repair only when git says so.
    if re.search(r"non-fast-forward|fetch first", stderr):
        return "the remote branch has commits the verified SHA lacks; fetch, reconcile, and re-enter (never force)"
    return "check origin's push URL, network, and access, then re-enter (never force)"


def _published(store, repo_name: str, row: dict) -> dict:
    """LF-58: what earlier DELIVER attempts already put on the remote (a pushed SHA, a
    PR) survives a later failed attempt, so a re-entry never erases that history."""
    earlier = (store.state.get("deliverPublished") or {}).get(repo_name)
    if earlier is None or row["state"] == "delivered":
        return row
    pr_note = f" and PR #{earlier['pr']['number']}" if earlier.get("pr") else ""
    return {**row, "publishedSha": earlier["sha"], "pr": row["pr"] or earlier.get("pr"),
            "caveats": row["caveats"] + [f"published earlier: {earlier['sha'][:12]}{pr_note} (attempt {earlier['attemptId']})"]}


def _record_published(store, repo_name: str, sha: str, pr: dict | None, attempt_id: str) -> None:
    store.state.setdefault("deliverPublished", {})[repo_name] = {"sha": sha, "pr": pr, "attemptId": attempt_id, "at": now_iso()}
    store.save()


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
    bound_to = {"requirements": store.state["revisions"]["requirements"], "plan": store.state["revisions"]["plan"]}

    # D7: every touched repo's credentials are checked before the FIRST remote write,
    # so a refusal blocks DELIVER with nothing published anywhere.
    refused = {}
    for repo_name in touched:
        check = credential_checks.get(repo_name) or {}
        if not (check.get("git_ok") and check.get("gh_ok")):
            failed_tool = "git" if not check.get("git_ok") else "gh"
            refused[repo_name] = f"the {failed_tool} credential check failed: {check.get('failedCommand')}; repair: {check.get('repair')}"
    if refused:
        for repo_name in store.state["repos"]:
            if repo_name not in touched:
                repos_out.append({"repo": repo_name, "pr": None, "deliveredSha": None, "caveats": [], "state": "skipped"})
                continue
            reason = refused.get(repo_name) or (f"not attempted: the credential check failed for "
                                                f"{', '.join(sorted(refused))}, so this attempt wrote to no remote")
            repos_out.append(_published(store, repo_name, {"repo": repo_name, "pr": None, "deliveredSha": None, "caveats": [reason], "state": "failed"}))
        return Product({"exit": "delivery blocked", "inputsDigest": ctx["inputs"]["digest"], "boundTo": bound_to, "repos": repos_out})

    for repo_name, repo_info in store.state["repos"].items():
        if repo_name not in touched:
            repos_out.append({"repo": repo_name, "pr": None, "deliveredSha": None, "caveats": [], "state": "skipped"})
            continue

        # EXECUTE never commits into the operator's own checkout (repo_info["path"]);
        # its own worktrees/feature/<repo> is where the pushed commits actually live.
        execute_repos = (store.state.get("execute") or {}).get("repos") or {}
        execute_repo = execute_repos.get(repo_name)
        worktree = Path(execute_repo["worktree"]) if execute_repo else Path(repo_info["path"])

        # R8: a commit added to the feature branch after VERIFY passed must never
        # get published just because DELIVER pushes whatever the branch currently
        # points at. Caught here, before any push, so a moved branch is this
        # repo's own row instead of an out-of-band commit only D1 notices after
        # it is already live.
        verified_sha = touched[repo_name]
        local_sha = repo_module.branch_sha(worktree, repo_info["featureBranch"])
        if local_sha != verified_sha:
            reason = (f"feature branch moved after VERIFY: local {(local_sha or 'missing')[:12]} "
                      f"vs verified {verified_sha[:12]}")
            repos_out.append(_published(store, repo_name, {"repo": repo_name, "pr": None, "deliveredSha": None, "caveats": [reason], "state": "failed"}))
            continue

        # Push the immutable, verified SHA to the ref by value, not the mutable
        # branch name -- nothing else in this program reads the upstream tracking
        # config `-u` used to set, so dropping it costs no other caller anything.
        push = repo_module._git(worktree, "push", "origin", f"{verified_sha}:refs/heads/{repo_info['featureBranch']}")
        if push.returncode != 0:
            # LF-58: one repo's rejected push is that repo's failed row; the others
            # are still attempted, so a workspace can deliver partially.
            stderr = push.stderr.strip()
            reason = f"push rejected: {stderr}; repair: {_push_repair(stderr)}"
            repos_out.append(_published(store, repo_name, {"repo": repo_name, "pr": None, "deliveredSha": None, "caveats": [reason], "state": "failed"}))
            continue
        _record_published(store, repo_name, verified_sha, None, ctx["attempt"]["id"])

        pr, error = _reconcile_pr(store, repo_name, worktree, repo_info, repo_info["defaultBranch"], draft,
                                   spec_product["goal"], render.pr_body(store))
        if error:
            # The branch IS on the remote: record what was published and where it stopped.
            reason = f"pushed {verified_sha[:12]} to {repo_info['featureBranch']}; the PR step failed: {error}"
            repos_out.append({"repo": repo_name, "pr": None, "deliveredSha": None, "publishedSha": verified_sha,
                              "caveats": [reason], "state": "failed"})
            continue
        _record_published(store, repo_name, verified_sha, pr, ctx["attempt"]["id"])
        repos_out.append({"repo": repo_name, "pr": pr, "deliveredSha": touched[repo_name], "caveats": [], "state": "delivered"})

    # Mixed is partial; nothing delivered is blocked (the rows name why); an
    # untouched (skipped) repo never makes a delivery partial.
    delivered_any = any(r["state"] == "delivered" for r in repos_out)
    failed_any = any(r["state"] == "failed" for r in repos_out)
    exit_ = "delivered" if not failed_any else ("partially delivered" if delivered_any else "delivery blocked")
    return Product({"exit": exit_, "inputsDigest": ctx["inputs"]["digest"], "boundTo": bound_to, "repos": repos_out})
