"""Run shell commands in a checkout and keep what a reader needs from each run."""
import subprocess
import time
from pathlib import Path

TAIL_LINES = 40


def run(command: str, cwd: Path, timeout: int) -> dict:
    """Run `command` with bash in `cwd`. Never raises for the command's own failure."""
    started = time.monotonic()
    try:
        proc = subprocess.run(["bash", "-c", command], cwd=cwd, capture_output=True, text=True, timeout=timeout)
        code, output = proc.returncode, proc.stdout + proc.stderr
    except subprocess.TimeoutExpired as exc:
        code, output = 124, f"{_text(exc.stdout)}{_text(exc.stderr)}\n(timed out after {timeout}s)"
    lines = output.rstrip().splitlines()
    return {
        "command": command,
        "exit": code,
        "seconds": round(time.monotonic() - started, 1),
        "tail": "\n".join(lines[-TAIL_LINES:]),
    }


def _text(data) -> str:
    if data is None:
        return ""
    return data.decode(errors="replace") if isinstance(data, bytes) else data


def planned(spec: dict | None, plan: dict | None) -> list[dict]:
    """What verify runs: each spec criterion's check, then each task's verify command
    no criterion already runs. A criterion with no check is listed with command None."""
    items, seen = [], set()
    for c in (spec or {}).get("criteria", []):
        items.append({"name": c.get("id", "?"), "text": c.get("text", ""), "command": c.get("check") or None})
        seen.add(c.get("check"))
    for t in (plan or {}).get("tasks", []):
        cmd = t.get("verify")
        if cmd and cmd not in seen:
            items.append({"name": t["id"], "text": t.get("title", ""), "command": cmd})
            seen.add(cmd)
    return items
