"""Reading what people and review bots said on a delivered PR.

Three sources: reviews (approve, request changes, or comment), inline review comments,
and conversation comments. The run's own replies carry `MARK` and are left out. Others
from the same gh account are kept: the person who started the run often reviews its PR
under their own login. An item shown stays open until answered; see `feedback` in cli.py.
"""
import json
import re
from datetime import datetime
from pathlib import Path

from loop_spec import git
from loop_spec.errors import LoopSpecError

MARK = "<!-- loop-spec -->"  # appended to every comment the program posts
RUNNING = r"^\W*(?:\w+\W+){0,3}(?:running|in progress)\W*$"  # a short line ending in the status word; re.I | re.M


def _lines(worktree: Path, *args: str) -> list[dict]:
    code, out, _ = git.gh(worktree, *args)
    return [json.loads(line) for line in out.splitlines() if line.strip()] if code == 0 else []


def read(worktree: Path, pr: int) -> tuple[list[dict], dict]:
    """(items, verdicts): every review item the run did not post itself, oldest first, and
    each reviewer's latest review state (APPROVED, CHANGES_REQUESTED, ...). Each item has
    `answered`: an approval or dismissal, or an inline comment with a later one in its thread."""
    code, out, _ = git.gh(worktree, "pr", "view", str(pr), "--json", "reviews")
    view = json.loads(out) if code == 0 and out.strip() else {}
    items, verdicts = [], {}
    for r in view.get("reviews", []):
        author = (r.get("author") or {}).get("login")
        if r.get("state") in ("APPROVED", "CHANGES_REQUESTED", "DISMISSED"):
            verdicts[author] = r["state"]
        if (r.get("body", "").strip() or r.get("state") == "CHANGES_REQUESTED") and MARK not in r.get("body", ""):
            items.append({"id": f"review:{r.get('id')}", "kind": f"review ({r.get('state', '').lower()})",
                          "author": author, "body": r.get("body", ""), "at": r.get("submittedAt", ""),
                          "answered": r.get("state") in ("APPROVED", "DISMISSED")})
    # Keyed with updated_at, so a bot that edits one pinned comment in place reports again.
    for c in _lines(worktree, "api", f"repos/{{owner}}/{{repo}}/issues/{pr}/comments", "--paginate", "--jq",
                    ".[] | {id, body, url: .html_url, author: .user.login, at: .updated_at}"):
        if MARK not in c.get("body", ""):
            items.append({**c, "id": f"comment:{c.get('id')}@{c.get('at')}", "kind": "comment", "answered": False})
    inline = _lines(worktree, "api", f"repos/{{owner}}/{{repo}}/pulls/{pr}/comments", "--paginate", "--jq",
                    ".[] | {id, body, path, line, url: .html_url, author: .user.login, at: .created_at, reply_to: .in_reply_to_id}")
    last = {}  # the newest comment of each thread, the run's own replies included
    for c in inline:
        root = c.get("reply_to") or c["id"]
        last[root] = max(last.get(root, 0), c["id"])
    for c in inline:
        if MARK not in c.get("body", ""):
            items.append({**c, "id": f"inline:{c['id']}", "kind": "inline comment",
                          "answered": c["id"] < last[c.get("reply_to") or c["id"]]})
    return sorted(items, key=lambda i: i.get("at") or ""), verdicts


def running_pattern(text: str | None) -> re.Pattern:
    try:
        return re.compile(text or RUNNING, re.I | re.M)
    except re.error as e:
        raise LoopSpecError(f"feedback.runningPattern is not a regular expression: {e}", "fix it in .loop-spec/config.json")


def split(items: list[dict], record: dict, pattern: re.Pattern) -> tuple[list[dict], list[dict], list[dict]]:
    """(new, still open, running): items not yet shown, items shown and not answered, and
    a bot's conversation comments not yet shown that say its review is still running."""
    seen, shown = record.get("seen", []), record.get("open", [])
    fresh = [i for i in items if i["id"] not in seen]
    running = [i for i in fresh if i["kind"] == "comment" and (i.get("author") or "").endswith("[bot]")
               and pattern.search(i.get("body", ""))]
    held = {i["id"] for i in running}
    return ([i for i in fresh if i["id"] not in held],
            [i for i in items if i["id"] in shown and not i["answered"]],
            running)


def pending(worktree: Path, pr: int) -> list[str]:
    """Who was asked to review the PR and has not yet: users by login, teams by slug."""
    code, out, _ = git.gh(worktree, "pr", "view", str(pr), "--json", "reviewRequests")
    view = json.loads(out) if code == 0 and out.strip() else {}
    return [r.get("login") or r.get("slug") or r.get("name") or "?" for r in view.get("reviewRequests") or []]


def silent(items: list[dict], logins: list[str], since: str) -> list[str]:
    """The `logins` with no item dated after `since` (the delivery): reviewers the run waits for.
    A trailing `[bot]` is ignored on both sides."""
    bare = lambda login: (login or "").removesuffix("[bot]")  # noqa: E731
    when = lambda stamp: datetime.fromisoformat(stamp)  # noqa: E731
    return [w for w in logins
            if not any(bare(i.get("author")) == bare(w) and i.get("at") and when(i["at"]) > when(since) for i in items)]
