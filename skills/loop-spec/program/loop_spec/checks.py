"""Run shell commands in a checkout and keep what a reader needs from each run."""
import re
import subprocess
import time
from pathlib import Path

TAIL_LINES = 40


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


_DURATION = re.compile(r"\d+(\.\d+)?\s*(ms|s|sec|seconds)\b")


def new_lines(head_output: str, base_output: str) -> list[str]:
    """Lines of a check's output at the head that its output at the base lacks, ignoring durations."""
    def norm(text):
        return {_DURATION.sub("N", line.strip()) for line in text.splitlines() if line.strip()}
    base = norm(base_output)
    return [line for line in head_output.splitlines() if line.strip() and _DURATION.sub("N", line.strip()) not in base]


def planned(spec: dict | None, plan: dict | None) -> list[dict]:
    """What verify runs: each spec criterion's check, each task's verify command, then each
    repository check from plan.json, skipping a command already listed. A criterion with
    no check is listed with command None."""
    items, seen = [], set()
    for c in (spec or {}).get("criteria", []):
        items.append({"name": c.get("id", "?"), "text": c.get("text", ""), "command": c.get("check") or None})
        seen.add(c.get("check"))
    for t in (plan or {}).get("tasks", []):
        cmd = t.get("verify")
        if cmd and cmd not in seen:
            items.append({"name": t["id"], "text": t.get("title", ""), "command": cmd})
            seen.add(cmd)
    for i, check in enumerate(repo_checks(plan), 1):
        if check["command"] not in seen:
            items.append({"name": f"check-{i}", "text": check.get("source", ""), "command": check["command"], "repoCheck": True})
            seen.add(check["command"])
    return items


def repo_checks(plan: dict | None) -> list[dict]:
    """plan.json's `checks`: the repository's own required checks, as {command, source}."""
    return [c if isinstance(c, dict) else {"command": c} for c in (plan or {}).get("checks", []) if c]
