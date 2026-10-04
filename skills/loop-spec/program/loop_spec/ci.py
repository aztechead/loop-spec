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
_STAMP = re.compile(r"^\d{4}-\d\d-\d\dT[\d:.]+Z ")  # each job log line's timestamp


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
    """Poll until a check fails, every check passes, or `timeout` passes. Returns (outcome, checks),
    where outcome is `passed`, `failed`, `none` (no CI), or `pending` (still running at the timeout)."""
    deadline = clock() + timeout
    while True:
        checks = read(worktree, pr)
        if checks is None and not expected(worktree):
            return "none", []
        if checks is not None and any(c.get("bucket") in ("fail", "cancel") for c in checks):
            return "failed", checks  # no need to wait for slow checks: the fix's push starts them over
        if checks is not None and all(c.get("bucket") != "pending" for c in checks):
            return "passed", checks
        if clock() >= deadline:
            return "pending", checks or []
        sleep(POLL_SECONDS)


def failure_log(worktree: Path, check: dict) -> str:
    """The tail of a failed GitHub Actions job's log, up to its last error, or '' when the check is
    not one. Read from the job, since GitHub serves `gh run view --log-failed` only once the whole
    run has finished, and feedback reports a failure while slower jobs still run."""
    match = _JOB.search(check.get("link") or "")
    if not match:
        return ""
    code, out, _ = git.gh(worktree, "api", f"repos/{{owner}}/{{repo}}/actions/jobs/{match.group(2)}/logs")
    if code != 0:
        return ""
    lines = [_STAMP.sub("", line) for line in out.rstrip().splitlines()]
    errors = [i for i, line in enumerate(lines) if line.startswith("##[error]")]
    return "\n".join(lines[:errors[-1] + 1 if errors else len(lines)][-LOG_LINES:])
