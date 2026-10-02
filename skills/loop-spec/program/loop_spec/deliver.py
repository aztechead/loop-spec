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
import time
from pathlib import Path

from loop_spec import render
from loop_spec import repo as repo_module
from loop_spec.contract import load_config
from loop_spec.errors import LoopSpecError
from loop_spec.steps import Product  # noqa: F401 -- Pause kept for interface symmetry
from loop_spec.ids import now_iso


def _touched_repos(store) -> dict:
    heads = store.state["products"]["execute"]["product"].get("heads", {})
    touched = {}
    for name, repo_info in store.state["repos"].items():
        head = heads.get(name)
        if head and repo_module.commits_between(Path(repo_info["path"]), repo_info["baseSha"], head):
            touched[name] = head
    return touched


def _moved_branch_reason(repo: Path, worktree: Path, branch: str, local_sha: str | None, verified_sha: str) -> str:
    """EA-runs item 2: say how to keep commits made after VERIFY. Resetting past the
    verified SHA to clear this drops them; a rescue branch keeps them, and revise
    gates them once the PR exists. This row is written before the exit is known, so
    both the paused and the terminal case are named."""
    head = f"feature branch moved after VERIFY: local {(local_sha or 'missing')[:12]} vs verified {verified_sha[:12]}"
    if local_sha is None:
        return f"{head}; the branch is missing, so there is nothing to rescue"
    rescue = f"loop-spec-rescue-{local_sha[:8]}"
    return (f"{head}. Keep those commits (a hard reset drops them): `git -C {repo} branch {rescue} {local_sha}`. "
            f"If DELIVER is paused: `git -C {worktree} reset --keep {verified_sha}`, then re-enter DELIVER. "
            f"Once the PR is open: `git -C {repo} push origin {rescue}:{branch}`, then `loop-spec revise --pr <number>` "
            f"to verify them")


def pr_title(title: str, limit: int = 70) -> str:
    # GitHub shows about 70 characters of a title; a cut mid-word read as a typo
    # in the live debug run (LF-36), so cut at the last word boundary that fits. A goal
    # may span lines; a title is one (7.2.0).
    title = " ".join(title.split())
    if len(title) <= limit:
        return title
    head = title[: limit - 3].rsplit(" ", 1)[0].rstrip(" ,;:.")
    return head + "..."


_METADATA_FLAGS = ("--assignee", "--reviewer", "--label")


def _without_metadata(args: list[str]) -> list[str]:
    kept, skip = [], False
    for arg in args:
        if skip:
            skip = False
        elif arg in _METADATA_FLAGS:
            skip = True
        else:
            kept.append(arg)
    return kept


def _edit_body(worktree: Path, number: int, generated: str, caveats: list[str]) -> None:
    # The body is refreshed through its markers, so text a person added survives. A body
    # that cannot be read is never overwritten blind.
    code, out, err = repo_module.run_gh(worktree, "pr", "view", str(number), "--json", "body")
    try:
        existing = (json.loads(out).get("body") or "") if code == 0 else None
    except ValueError:
        existing = None
    if existing is None:
        caveats.append(f"the PR body was not updated: gh pr view --json body failed: {err.strip() or 'unreadable'}")
        return
    body_path = Path(tempfile.mkstemp(prefix="loop-spec-pr-body-", suffix=".md")[1])
    body_path.write_text(render.merge_body(existing, generated))
    code, _, err = repo_module.run_gh(worktree, "pr", "edit", str(number), "--body-file", str(body_path))
    if code != 0:
        caveats.append(f"the PR body was not updated: gh pr edit failed: {err.strip()}")


def _reconcile_pr(store, repo_name: str, worktree: Path, repo_info: dict, base: str,
                   draft: bool, title: str, body: str, verified_sha: str,
                   reviewers: list[str] = (), labels: list[str] = ()) -> tuple[dict | None, str | None, list[str]]:
    branch = repo_info["featureBranch"]
    code, out, err = repo_module.run_gh(worktree, "pr", "list", "--head", branch, "--state", "open",
                                         "--json", "number,url,headRefOid,baseRefName,isDraft")
    if code != 0:
        return None, f"gh pr list failed: {err.strip()}", []

    caveats = []
    existing = json.loads(out)
    if existing:
        number = existing[0]["number"]
        # 7.1.0: a re-entry or a revise run refreshes the body it rendered; a failed
        # edit leaves the old body and says so, it never fails the delivery.
        _edit_body(worktree, number, body, caveats)
        # The PR's draft state follows this delivery's verdict both ways: a non-draft
        # delivery marks an existing draft ready (a revise that cleanly addresses review
        # on an earlier caveats run's draft), a draft delivery converts a ready PR back.
        # Like the body edit, a failure is a caveat only.
        if existing[0].get("isDraft") and not draft:
            code, _, err = repo_module.run_gh(worktree, "pr", "ready", str(number))
            if code != 0:
                caveats.append(f"the PR is still a draft: gh pr ready failed: {err.strip()}")
        elif draft and not existing[0].get("isDraft"):
            code, _, err = repo_module.run_gh(worktree, "pr", "ready", str(number), "--undo")
            if code != 0:
                caveats.append(f"the PR is not a draft: gh pr ready --undo failed: {err.strip()}")
    else:
        # LF-48: the body file lives outside the worktree; an untracked file inside it
        # made the feature checkout "dirty" and terminal cleanup kept it as backlog.
        template = render.pr_template(worktree, verified_sha)
        body_path = Path(tempfile.mkstemp(prefix="loop-spec-pr-body-", suffix=".md")[1])
        body_path.write_text(body if template is None else body.rstrip("\n") + "\n\n" + template)
        # A crash-recovery marker, not a control-flow gate: `gh pr list` above already
        # reconciles a lost create response on its own, so nothing reads this back.
        store.state.setdefault("deliver", {}).setdefault("creating", {})[repo_name] = {"at": now_iso(), "branch": branch}
        store.save()
        args = ["pr", "create", "--base", base, "--head", branch, "--title", pr_title(title), "--body-file", str(body_path),
                "--assignee", "@me"]
        for name in reviewers:
            args += ["--reviewer", name]
        for name in labels:
            args += ["--label", name]
        if draft:
            args.append("--draft")
        code, _, err = repo_module.run_gh(worktree, *args)
        if code != 0 and re.search(r"reviewer|label|assignee", err, re.IGNORECASE):
            # A name the repository does not know must not cost the PR: retry without them.
            caveats.append(f"the PR was opened without its assignee, reviewers, and labels: {err.strip()}")
            code, _, err = repo_module.run_gh(worktree, *_without_metadata(args))
        if code != 0:
            return None, f"gh pr create failed: {err.strip()}", caveats
        store.state["deliver"]["creating"].pop(repo_name, None)
        store.save()

    pr, error = _view_pr(worktree, branch)
    return pr, error, caveats


def _read_ci(worktree: Path, row: dict) -> None:
    """One read of the PR's CI after the push (DELIVER runs under a host tool call with a
    time cap, so it never waits). Pending and error are caveats; a failing check drafts
    the PR, and the revise entry is the way back once the author fixes it."""
    pr = row["pr"]
    state, detail = repo_module.pr_checks(worktree, pr["number"])
    row["checks"] = {"state": state, "detail": detail}
    if state == "pending":
        row["caveats"].append(f"CI is still running: {detail or pr['url']}")
    elif state == "error":
        row["caveats"].append(f"CI was not read: {detail}")
    elif state == "fail":
        row["caveats"].append(f"CI checks failed: {detail}")
        code, _, err = repo_module.run_gh(worktree, "pr", "ready", str(pr["number"]), "--undo")
        if code != 0:
            row["caveats"].append(f"the PR is not a draft: gh pr ready --undo failed: {err.strip()}")


def _view_pr(worktree: Path, branch: str) -> tuple[dict | None, str | None]:
    code, out, err = repo_module.run_gh(worktree, "pr", "view", branch,
                                         "--json", "number,url,headRefName,headRefOid,baseRefName")
    if code != 0:
        return None, f"gh pr view failed: {err.strip()}"
    try:
        data = json.loads(out)
    except ValueError as exc:
        return None, f"gh pr view failed: {exc}"
    return {"number": data["number"], "url": data["url"], "headRef": data["headRefName"],
            "headSha": data["headRefOid"], "base": data["baseRefName"]}, None


# Seconds slept before each re-read of a PR head that is an ancestor of the pushed head
# (the hosting server lagging the push): 30 s worst case per repo.
_PR_HEAD_WAITS = (2, 4, 8, 16)


def _stale_pr_head(worktree: Path, pr: dict, expected: str) -> bool:
    return pr["headSha"] != expected and repo_module.is_ancestor(worktree, pr["headSha"], expected)


def _stale_head_refusal(worktree: Path, repo_info: dict, action: str, stale: str, expected: str) -> str:
    branch = repo_info["featureBranch"]
    origin = repo_module.remote_head(worktree, "origin", branch)
    if origin is None:
        return (f"{action}; could not read origin/{branch} after the PR kept reporting {stale[:12]}; "
                "repair: check origin's push URL, network, and access, then re-enter (never force)")
    if origin == expected:
        return (f"{action}; the PR still reports head {stale[:12]}, an ancestor of {expected[:12]}, after "
                f"{len(_PR_HEAD_WAITS) + 1} reads over {sum(_PR_HEAD_WAITS)} s; repair: the hosting server "
                "has not caught up with the push; re-enter DELIVER to read it again")
    return (f"{action}; origin's branch is at {origin[:12]}, not the pushed head; someone moved it back; "
            "repair: re-enter DELIVER to push again")


def _push_repair(stderr: str) -> str:
    # A non-zero push is not always a non-fast-forward (LF-58: an unreachable remote
    # read as "resolve the out-of-band change"); name the repair only when git says so.
    if re.search(r"non-fast-forward|fetch first", stderr):
        return "the remote branch has commits the verified SHA lacks; fetch, reconcile, and re-enter (never force)"
    return "check origin's push URL, network, and access, then re-enter (never force)"


def _accept_extension(worktree: Path, repo_info: dict, verified_sha: str, globs: list[str]) -> tuple[dict | None, str | None]:
    """(accepted, refusal): an allowed extension, or the reason this repo cannot be
    delivered; (None, None) when the remote holds no extension (push as usual)."""
    ext = repo_module.remote_extension(worktree, repo_info["featureBranch"], verified_sha, repo_info["baseSha"], globs)
    if ext["state"] == "error":
        return None, (f"could not read origin/{repo_info['featureBranch']}: {ext['why']}; "
                      "repair: check origin's push URL, network, and access, then re-enter (never force)")
    if ext["state"] != "extension":
        return None, None
    if ext["refused"]:
        return None, (f"the remote branch has commits after the verified SHA that touch {', '.join(ext['refused'])}; "
                      "repair: deliver.acceptRemotePaths allows only paths the verified change never touches; "
                      "remove those commits from the branch or widen the list, then re-enter (never force)")
    return {k: ext[k] for k in ("head", "commits", "paths")}, None


def _published(store, repo_name: str, row: dict) -> dict:
    """LF-58: what earlier DELIVER attempts already put on the remote (a pushed SHA, a
    PR) survives a later failed attempt, so a re-entry never erases that history."""
    earlier = ((store.state.get("deliver") or {}).get("published") or {}).get(repo_name)
    if earlier is None or row["state"] == "delivered":
        return row
    pr = earlier.get("pr")
    # The PR is as its own attempt last saw it, not re-verified against the newer push.
    pr_note = (f"; PR #{pr['number']} last seen at head {(pr.get('headSha') or '?')[:12]} "
               f"(attempt {earlier.get('prAttemptId', earlier['attemptId'])})") if pr else ""
    how = "observed on the remote (no push)" if earlier.get("observed") else "published"
    caveats = row["caveats"] + [f"{how}: {earlier['sha'][:12]} (attempt {earlier['attemptId']}){pr_note}"]
    if earlier.get("acceptedRemote"):
        # Historical: what an earlier attempt accepted, not re-validated here.
        caveats.append("previously accepted remote commits: " + _accepted_text(earlier["acceptedRemote"]))
    return {**row, "publishedSha": earlier["sha"], "pr": row["pr"] or pr, "caveats": caveats}


def _accepted_text(accepted: dict) -> str:
    commits = ", ".join(f"{c['sha'][:12]} ({c['subject']})" for c in accepted["commits"])
    return f"{commits} touching {', '.join(accepted['paths'])}, head {accepted['head'][:12]}"


def _record_published(store, repo_name: str, sha: str, pr: dict | None, attempt_id: str,
                      accepted: dict | None = None) -> None:
    # Cumulative: a push with no PR yet (pr=None) keeps the PR an earlier attempt recorded.
    published = store.state.setdefault("deliver", {}).setdefault("published", {})
    earlier = published.get(repo_name) or {}
    record = {"sha": sha, "attemptId": attempt_id, "at": now_iso(),
              "pr": earlier.get("pr"), "prAttemptId": earlier.get("prAttemptId", earlier.get("attemptId")),
              "acceptedRemote": earlier.get("acceptedRemote"), "observed": earlier.get("observed", False)}
    if accepted is not None:
        record.update(acceptedRemote=accepted, observed=True)
    if pr is not None:
        record.update(pr=pr, prAttemptId=attempt_id)
    published[repo_name] = record
    store.save()


def _post_replies(store, worktree: Path, row: dict) -> None:
    """Answer the review the revise run read: one inline reply per non-acknowledged inline
    comment, one summary PR comment, and a review re-request for the human reviewers whose
    comments were addressed or declined. Core state only; each failure is a caveat."""
    adoption = store.state.get("adoption") or {}
    operator = (store.state.get("operator") or {}).get("login")
    number, sha = row["pr"]["number"], row["deliveredSha"]
    deliver_state = store.state.setdefault("deliver", {})
    replied = deliver_state.setdefault("replied", [])
    todo = [r for r in store.state.get("reviewReplies") or [] if r["gap"] not in replied]
    if not todo or adoption.get("repo") != row["repo"]:
        return
    for reply in todo:
        if reply.get("kind") == "inline" and reply.get("commentId") and reply["disposition"] != "acknowledged":
            text = f"<!-- loop-spec:reply -->\n{reply['disposition']}: {reply['note']} ({sha[:12]})"
            code, _, err = repo_module.run_gh(worktree, "api", f"repos/{{owner}}/{{repo}}/pulls/{number}/comments/"
                                              f"{reply['commentId']}/replies", "-f", f"body={text}")
            if code != 0:
                row["caveats"].append(f"inline reply to {reply['url']} failed: {err.strip()}")
    lines = ["<!-- loop-spec:reply -->", f"loop-spec answered this review at {sha[:12]}:", ""]
    author = adoption.get("author")
    if operator and author and author != operator:
        lines.insert(2, f"Commits pushed to @{author}'s branch by @{operator} through loop-spec.\n")
    lines += [f"- {r.get('url') or r['gap']} ({r['disposition']}): {r['note']}" for r in todo]
    body_path = Path(tempfile.mkstemp(prefix="loop-spec-reply-", suffix=".md")[1])
    body_path.write_text("\n".join(lines) + "\n")
    code, _, err = repo_module.run_gh(worktree, "pr", "comment", str(number), "--body-file", str(body_path))
    body_path.unlink(missing_ok=True)
    if code != 0:
        row["caveats"].append(f"the review reply comment failed: {err.strip()}")
    people = sorted({r["author"] for r in todo if r["disposition"] in ("addressed", "declined")
                     and r.get("kind") != "check" and r.get("author") and not r["author"].endswith("[bot]")
                     and r["author"] not in (operator, author, "unknown")})
    if people:
        code, _, err = repo_module.run_gh(worktree, "pr", "edit", str(number), "--add-reviewer", ",".join(people))
        if code != 0:
            row["caveats"].append(f"review was not re-requested from {', '.join(people)}: {err.strip()}")
    replied.extend(r["gap"] for r in todo)
    store.save()


def run(store, paths, ctx):
    project_root = Path(ctx["paths"]["projectRoot"])
    config = load_config(project_root)
    globs = (config.get("deliver") or {}).get("acceptRemotePaths") or []
    readiness = (config.get("deliver") or {}).get("readiness", "checks")
    reviewers = (config.get("deliver") or {}).get("reviewers") or []
    labels = (config.get("deliver") or {}).get("labels") or []
    iterate_exit = store.state["products"]["iterate"]["exit"]
    entry_payload = (ctx.get("entry") or {}).get("payload") or {}
    draft = bool(entry_payload.get("draft")) or iterate_exit == "converged with caveats"
    credential_checks = store.state.get("credentialChecks") or {}
    spec_product = store.state["products"]["spec"]["product"]
    slug = store.state["run"].get("slug") or "run"

    # 7.4.1: a no-change run delivers nothing. An adopted PR's own commits would count
    # as touched from the base, so the gate is EXECUTE's exit, not _touched_repos.
    no_change = store.state["products"]["execute"]["exit"] == "no change"
    touched = {} if no_change else _touched_repos(store)
    adoption = store.state.get("adoption") or {}
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

    # Base moved: something merged into the PR base after this run forked (another
    # agent's PR) and the verified head no longer merges into it. Checked for every
    # touched repo before the first push, so nothing is published; EXECUTE merges the
    # new base in (a resolver settles any conflicts) and the run re-verifies (D9).
    moved, fetch_failed = {}, {}
    for repo_name, head in touched.items():
        repo_info = store.state["repos"][repo_name]
        path = Path(repo_info["path"])
        try:
            tip = repo_module.fetch_base(path, repo_info["defaultBranch"])
        except LoopSpecError as exc:
            fetch_failed[repo_name] = f"{exc.message}; repair: {exc.repair}"
            continue
        if repo_module.is_ancestor(path, tip, head):
            continue
        if not repo_module.is_ancestor(path, repo_info["baseSha"], tip):
            fetch_failed[repo_name] = (f"origin/{repo_info['defaultBranch']} ({tip[:12]}) no longer contains this run's base "
                                       f"{repo_info['baseSha'][:12]} (rewritten history); repair: restore the base branch, or "
                                       "merge it into the feature branch by hand, then re-enter (never force)")
            continue
        # Any move is merged in and re-verified, conflicts or not: a clean merge can still
        # break what the verified head did.
        moved[repo_name] = {"newBase": tip, "conflicts": repo_module.merge_conflicts(path, head, tip)}
    if moved:
        for repo_name, repo_info in store.state["repos"].items():
            if repo_name not in moved:
                note = [f"not attempted: the base moved under {', '.join(sorted(moved))}"] if repo_name in touched else []
                repos_out.append({"repo": repo_name, "pr": None, "deliveredSha": None, "caveats": note, "state": "skipped"})
                continue
            move = moved[repo_name]
            repos_out.append({"repo": repo_name, "pr": None, "deliveredSha": None, "state": "base moved", **move, "caveats": [
                f"{repo_info['defaultBranch']} moved to {move['newBase'][:12]}; EXECUTE merges it in "
                f"(conflicts: {', '.join(move['conflicts']) or 'none'}), then the run re-verifies"]})
        return Product({"exit": "base moved", "inputsDigest": ctx["inputs"]["digest"], "boundTo": bound_to, "repos": repos_out})

    for repo_name, repo_info in store.state["repos"].items():
        if repo_name not in touched:
            pr = None
            if no_change and adoption.get("repo") == repo_name:
                # The open PR already does what was asked; name it, write nothing (D6).
                pr = {"number": adoption["number"], "url": adoption["url"], "headRef": adoption["headRef"],
                      "headSha": adoption["headSha"], "base": adoption["baseBranch"]}
            repos_out.append({"repo": repo_name, "pr": pr, "deliveredSha": None, "caveats": [], "state": "skipped"})
            continue

        # EXECUTE never commits into the operator's own checkout (repo_info["path"]);
        # its own worktrees/feature/<repo> is where the pushed commits actually live.
        worktree = paths.feature_worktree(repo_name)
        if not worktree.is_dir():
            worktree = Path(repo_info["path"])

        # R8: a commit added to the feature branch after VERIFY passed must never
        # get published just because DELIVER pushes whatever the branch currently
        # points at. Caught here, before any push, so a moved branch is this
        # repo's own row instead of an out-of-band commit only D1 notices after
        # it is already live.
        verified_sha = touched[repo_name]
        local_sha = repo_module.branch_sha(worktree, repo_info["featureBranch"])
        if local_sha != verified_sha:
            reason = _moved_branch_reason(Path(repo_info["path"]), worktree, repo_info["featureBranch"],
                                          local_sha, verified_sha)
            repos_out.append(_published(store, repo_name, {"repo": repo_name, "pr": None, "deliveredSha": None, "caveats": [reason], "state": "failed"}))
            continue

        def failed(reason: str) -> dict:
            return _published(store, repo_name, {"repo": repo_name, "pr": None, "deliveredSha": None,
                                                 "caveats": [reason], "state": "failed"})

        if repo_name in fetch_failed:
            repos_out.append(failed(fetch_failed[repo_name]))
            continue

        # 7.1.0: with deliver.acceptRemotePaths set, commits someone else put on the
        # branch after the verified SHA (a changelog bot) are accepted when every path
        # they touch is allowed and none is part of the verified change; the verified
        # SHA is still what was delivered, the extension is recorded beside it.
        accepted, refusal = None, None
        if globs:
            accepted, refusal = _accept_extension(worktree, repo_info, verified_sha, globs)
            if refusal is not None:
                repos_out.append(failed(refusal))
                continue
        if accepted is None:
            # Push the immutable, verified SHA to the ref by value, not the mutable
            # branch name -- nothing else in this program reads the upstream tracking
            # config `-u` used to set, so dropping it costs no other caller anything.
            push = repo_module._git(worktree, "push", "origin", f"{verified_sha}:refs/heads/{repo_info['featureBranch']}")
            if push.returncode != 0 and globs:
                # A bot may have pushed between the fetch and the push: look once more.
                accepted, refusal = _accept_extension(worktree, repo_info, verified_sha, globs)
            if accepted is None and push.returncode != 0:
                # LF-58: one repo's rejected push is that repo's failed row; the others
                # are still attempted, so a workspace can deliver partially.
                stderr = push.stderr.strip()
                repos_out.append(failed(refusal or f"push rejected: {stderr}; repair: {_push_repair(stderr)}"))
                continue
        # Recorded before the PR step, so a failure there keeps what is on the remote.
        _record_published(store, repo_name, verified_sha, None, ctx["attempt"]["id"], accepted)
        action = (f"observed {accepted['head'][:12]} (the verified {verified_sha[:12]} plus accepted commits) "
                  f"on {repo_info['featureBranch']}, no push") if accepted else \
                 f"pushed {verified_sha[:12]} to {repo_info['featureBranch']}"

        pr, error, pr_caveats = _reconcile_pr(store, repo_name, worktree, repo_info, repo_info["defaultBranch"], draft,
                                               spec_product["goal"], render.pr_body(store, repo_name), verified_sha,
                                               reviewers, labels)
        if error:
            # The branch IS on the remote: record what was published and where it stopped.
            repos_out.append(failed(f"{action}; the PR step failed: {error}"))
            continue
        # A hosting server can lag the push: a PR head that is an ancestor of the pushed
        # head is re-read a few times before it is recorded or judged.
        expected = (accepted or {}).get("head", verified_sha)
        for wait in _PR_HEAD_WAITS:
            if not _stale_pr_head(worktree, pr, expected):
                break
            time.sleep(wait)
            pr, error = _view_pr(worktree, repo_info["featureBranch"])
            if error:
                break
        if error:
            repos_out.append(failed(f"{action}; the PR step failed: {error}"))
            continue
        if _stale_pr_head(worktree, pr, expected):
            repos_out.append(failed(_stale_head_refusal(worktree, repo_info, action, pr["headSha"], expected)))
            continue
        if globs and pr["headSha"] != expected:
            # The PR names another head than the one observed: accept it only as the
            # same allowed extension, observed at exactly that head.
            later, refusal = _accept_extension(worktree, repo_info, verified_sha, globs)
            if later is None or later["head"] != pr["headSha"]:
                repos_out.append(failed(refusal or f"{action}; the PR head moved to {pr['headSha'][:12]}, "
                                                   "which is not an accepted extension of the verified SHA"))
                continue
            accepted = later
        _record_published(store, repo_name, verified_sha, pr, ctx["attempt"]["id"], accepted)
        row = {"repo": repo_name, "pr": pr, "deliveredSha": touched[repo_name], "caveats": list(pr_caveats), "state": "delivered"}
        if accepted:
            row["acceptedRemote"] = accepted
            row["caveats"].append("accepted remote commits under deliver.acceptRemotePaths: " + _accepted_text(accepted))
        if readiness == "checks":
            _read_ci(worktree, row)
        if repo_module._configured_remote_host(Path(repo_info["path"]), "origin") is not None:
            _post_replies(store, worktree, row)
        repos_out.append(row)

    # A workspace run opens one PR per repo; each body links the others once all exist.
    delivered_rows = [r for r in repos_out if r["state"] == "delivered" and r["pr"]]
    if len(delivered_rows) >= 2:
        for row in delivered_rows:
            siblings = [(o["repo"], o["pr"]["url"]) for o in delivered_rows if o is not row]
            worktree = paths.feature_worktree(row["repo"])
            if not worktree.is_dir():
                worktree = Path(store.state["repos"][row["repo"]]["path"])
            _edit_body(worktree, row["pr"]["number"], render.pr_body(store, row["repo"], siblings), row["caveats"])

    # Mixed is partial; nothing delivered is blocked (the rows name why); an
    # untouched (skipped) repo never makes a delivery partial.
    delivered_any = any(r["state"] == "delivered" for r in repos_out)
    failed_any = any(r["state"] == "failed" for r in repos_out)
    exit_ = "delivered" if not failed_any else ("partially delivered" if delivered_any else "delivery blocked")
    return Product({"exit": exit_, "inputsDigest": ctx["inputs"]["digest"], "boundTo": bound_to, "repos": repos_out})
