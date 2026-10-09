"""Run shell commands in a checkout and keep what a reader needs from each run."""
import os
import re
import subprocess
import tempfile
import time
from pathlib import Path

TAIL_LINES = 40  # a failure's last lines name it; more would crowd the lead's context


def run(command: str, cwd: Path, timeout: int) -> dict:
    """Run `command` with bash in `cwd`. Never raises for the command's own failure."""
    started = time.monotonic()
    try:
        proc = subprocess.run(["bash", "-c", command], cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              text=True, timeout=timeout)
        code, output = proc.returncode, proc.stdout
    except subprocess.TimeoutExpired as exc:
        partial = exc.output.decode(errors="replace") if isinstance(exc.output, bytes) else exc.output or ""
        code, output = 124, f"{partial}\n(timed out after {timeout}s)"
    return {
        "command": command,
        "exit": code,
        "seconds": round(time.monotonic() - started, 1),
        "tail": "\n".join(output.rstrip().splitlines()[-TAIL_LINES:]),
        "output": output,
    }


_DURATION = re.compile(r"\d+(\.\d+)?\s*(ms|s|sec|seconds)\b|(?<![\w:.])\d+:\d\d(:\d\d)?(\.\d+)?(?![\w:])")
_PYTEST_RUN = re.compile(r"\bpytest-\d+\b")  # pytest numbers its temp directory anew each session


def new_lines(head_output: str, base_output: str, head_root: Path, base_root: Path) -> list[str]:
    """Lines of a check's output at the head that its output at the base lacks. What differs
    between any two runs of one check is masked first: the checkout it ran in, temp paths, and durations."""
    head, base = _masker(head_root), _masker(base_root)
    seen = {base(line) for line in base_output.splitlines() if line.strip()}
    return [line for line in head_output.splitlines() if line.strip() and head(line) not in seen]


def _masker(root: Path):
    tmp = tempfile.gettempdir()
    names = {str(root): "<root>", os.path.realpath(root): "<root>"}
    for t in (tmp, os.path.realpath(tmp), "/tmp"):
        names.setdefault(t, "<tmp>")
    # a temp path's first component is a per-run random name (mkdtemp's, pytest-of-<user>'s)
    paths = re.compile("(" + "|".join(map(re.escape, sorted(names, key=len, reverse=True))) + r")(?![\w.-])(/[^/\s]+)?")

    def mask(line: str) -> str:
        line = paths.sub(lambda m: names[m[1]] + ("/*" if names[m[1]] == "<tmp>" and m[2] else m[2] or ""), line.strip())
        return _DURATION.sub("N", _PYTEST_RUN.sub("pytest-N", line))
    return mask


def planned(spec: dict | None, plan: dict | None) -> list[dict]:
    """What verify runs: each spec criterion's check, each task's verify command, then each
    repository check from plan.json, skipping a command already listed (for the same repository).
    A criterion with no check is listed with command None. Criteria run from the verify root,
    task and repository items from their repository's checkout (`repo`, set in a workspace)."""
    items, seen = [], set()
    for c in (spec or {}).get("criteria", []):
        items.append({"name": c.get("id", "?"), "text": c.get("text", ""), "command": c.get("check") or None})
        seen.add((None, c.get("check")))
    for t in (plan or {}).get("tasks", []):
        cmd = t.get("verify")
        if cmd and (t.get("repo"), cmd) not in seen:
            items.append({"name": t["id"], "text": t.get("title", ""), "command": cmd, "repo": t.get("repo")})
            seen.add((t.get("repo"), cmd))
    for i, check in enumerate(repo_checks(plan), 1):
        if (check.get("repo"), check["command"]) not in seen:
            items.append({"name": f"check-{i}", "text": check.get("source", ""), "command": check["command"],
                          "repoCheck": True, "repo": check.get("repo")})
            seen.add((check.get("repo"), check["command"]))
    return items


def repo_checks(plan: dict | None) -> list[dict]:
    """plan.json's `checks`: the repository's own required checks, as {command, source}."""
    return [c if isinstance(c, dict) else {"command": c} for c in (plan or {}).get("checks", []) if c]
