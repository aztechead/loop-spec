"""Reading a delivered PR's CI: wait for its checks to settle, and say what failed and why.

`gh pr checks --json` reports each check's `bucket`: pass, fail, pending, skipping, or
cancel. A repository with workflow files is expected to report checks; one without them
is treated as having no CI once the PR exists.
"""
import json
import re
import time
from pathlib import Path

from loop_spec import git

POLL_SECONDS = 15  # GitHub updates check status every few seconds; 15 s keeps gh calls well under its rate limit
LOG_LINES = 40  # enough for a stack trace or a failed assertion, small enough to keep the lead's context
_JOB = re.compile(r"/actions/runs/(\d+)/job/(\d+)")


def expected(worktree: Path) -> bool:
    workflows = worktree / ".github" / "workflows"
    return workflows.is_dir() and any(workflows.glob("*.y*ml"))


def read(worktree: Path, pr: int) -> list[dict] | None:
    """The PR's checks, or None when gh could not report them (an error, or none registered yet)."""
    code, out, _ = git.gh(worktree, "pr", "checks", str(pr), "--json", "name,bucket,link,workflow")
    try:
        found = json.loads(out) if out.strip() else []
    except json.JSONDecodeError:
        return None
    return found or None  # gh exits non-zero for failing or pending checks; the JSON is what counts


def wait(worktree: Path, pr: int, timeout: int, sleep=time.sleep, clock=time.monotonic) -> tuple[str, list[dict]]:
    """Poll until every check settles or `timeout` passes. Returns (outcome, checks), where
    outcome is `passed`, `failed`, `none` (no CI), or `pending` (still running at the timeout)."""
    deadline = clock() + timeout
    while True:
        checks = read(worktree, pr)
        if checks is None and not expected(worktree):
            return "none", []
        if checks is not None and all(c.get("bucket") != "pending" for c in checks):
            failed = [c for c in checks if c.get("bucket") in ("fail", "cancel")]
            return ("failed" if failed else "passed"), checks
        if clock() >= deadline:
            return "pending", checks or []
        sleep(POLL_SECONDS)


def failure_log(worktree: Path, check: dict) -> str:
    """The tail of a failed GitHub Actions job's log, or '' when the check is not one."""
    match = _JOB.search(check.get("link") or "")
    if not match:
        return ""
    code, out, _ = git.gh(worktree, "run", "view", match.group(1), "--job", match.group(2), "--log-failed")
    return "\n".join(out.rstrip().splitlines()[-LOG_LINES:]) if code == 0 else ""
