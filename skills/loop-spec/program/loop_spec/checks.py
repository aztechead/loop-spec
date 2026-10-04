"""Run shell commands in a checkout and keep what a reader needs from each run."""
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
    }


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
