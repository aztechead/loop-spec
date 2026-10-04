"""Reading what people and review bots said on a delivered PR.

Three sources: reviews (approve, request changes, or comment), inline review comments,
and conversation comments. The run's own replies carry `MARK` and are left out. Others
from the same gh account are kept: the person who started the run often reviews its PR
under their own login.
"""
import json
from pathlib import Path

from loop_spec import git

MARK = "<!-- loop-spec -->"  # appended to every comment the program posts


def _lines(worktree: Path, *args: str) -> list[dict]:
    code, out, _ = git.gh(worktree, *args)
    return [json.loads(line) for line in out.splitlines() if line.strip()] if code == 0 else []


def read(worktree: Path, pr: int) -> tuple[list[dict], dict]:
    """(items, verdicts): every review item the run did not post itself, oldest first, and
    each reviewer's latest review state (APPROVED, CHANGES_REQUESTED, ...)."""
    code, out, _ = git.gh(worktree, "pr", "view", str(pr), "--json", "reviews,comments")
    view = json.loads(out) if code == 0 and out.strip() else {}
    items, verdicts = [], {}
    for r in view.get("reviews", []):
        author = (r.get("author") or {}).get("login")
        if r.get("state") in ("APPROVED", "CHANGES_REQUESTED", "DISMISSED"):
            verdicts[author] = r["state"]
        if (r.get("body", "").strip() or r.get("state") == "CHANGES_REQUESTED") and MARK not in r.get("body", ""):
            items.append({"id": f"review:{r.get('id')}", "kind": f"review ({r.get('state', '').lower()})",
                          "author": author, "body": r.get("body", ""), "at": r.get("submittedAt", "")})
    for c in view.get("comments", []):
        author = (c.get("author") or {}).get("login")
        if MARK not in c.get("body", ""):
            items.append({"id": f"comment:{c.get('id')}", "kind": "comment", "author": author,
                          "body": c.get("body", ""), "url": c.get("url"), "at": c.get("createdAt", "")})
    inline = _lines(worktree, "api", f"repos/{{owner}}/{{repo}}/pulls/{pr}/comments", "--paginate", "--jq",
                    ".[] | {id, body, path, line, url: .html_url, author: .user.login, at: .created_at}")
    for c in inline:
        if MARK not in c.get("body", ""):
            items.append({**c, "id": f"inline:{c.get('id')}", "kind": "inline comment"})
    return sorted(items, key=lambda i: i.get("at") or ""), verdicts


def pending(worktree: Path, pr: int) -> list[str]:
    """Who was asked to review the PR and has not yet: users by login, teams by slug."""
    code, out, _ = git.gh(worktree, "pr", "view", str(pr), "--json", "reviewRequests")
    view = json.loads(out) if code == 0 and out.strip() else {}
    return [r.get("login") or r.get("slug") or r.get("name") or "?" for r in view.get("reviewRequests") or []]
