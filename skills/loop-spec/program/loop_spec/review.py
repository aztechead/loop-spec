"""Reading what people and review bots said on a delivered PR.

Three sources: reviews (approve, request changes, or comment), inline review comments,
and conversation comments. Anything the authenticated gh user wrote is left out: those
are the run's own replies.
"""
import json
from pathlib import Path

from loop_spec import git


def _lines(worktree: Path, *args: str) -> list[dict]:
    code, out, _ = git.gh(worktree, *args)
    return [json.loads(line) for line in out.splitlines() if line.strip()] if code == 0 else []


def me(worktree: Path) -> str | None:
    code, out, _ = git.gh(worktree, "api", "user", "--jq", ".login")
    return (out.strip() or None) if code == 0 else None


def read(worktree: Path, pr: int) -> tuple[list[dict], dict]:
    """(items, verdicts): every review item not written by this gh user, oldest first, and
    each reviewer's latest review state (APPROVED, CHANGES_REQUESTED, ...)."""
    self_login = me(worktree)
    code, out, _ = git.gh(worktree, "pr", "view", str(pr), "--json", "reviews,comments")
    view = json.loads(out) if code == 0 and out.strip() else {}
    items, verdicts = [], {}
    for r in view.get("reviews", []):
        author = (r.get("author") or {}).get("login")
        if author == self_login:
            continue
        if r.get("state") in ("APPROVED", "CHANGES_REQUESTED", "DISMISSED"):
            verdicts[author] = r["state"]
        if r.get("body", "").strip() or r.get("state") == "CHANGES_REQUESTED":
            items.append({"id": f"review:{r.get('id')}", "kind": f"review ({r.get('state', '').lower()})",
                          "author": author, "body": r.get("body", ""), "at": r.get("submittedAt", "")})
    for c in view.get("comments", []):
        author = (c.get("author") or {}).get("login")
        if author != self_login:
            items.append({"id": f"comment:{c.get('id')}", "kind": "comment", "author": author,
                          "body": c.get("body", ""), "url": c.get("url"), "at": c.get("createdAt", "")})
    inline = _lines(worktree, "api", f"repos/{{owner}}/{{repo}}/pulls/{pr}/comments", "--paginate", "--jq",
                    ".[] | {id, body, path, line, url: .html_url, author: .user.login, at: .created_at}")
    for c in inline:
        if c.get("author") != self_login:
            items.append({**c, "id": f"inline:{c.get('id')}", "kind": "inline comment"})
    return sorted(items, key=lambda i: i.get("at") or ""), verdicts
