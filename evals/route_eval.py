#!/usr/bin/env python3
"""Measure which loop-spec entry skill a request triggers.

Loads the plugin into `claude -p` with --plugin-dir, sends each query from a query
file against a small fixture repository, and records the first tool call: the entry
name when it is a `loop-spec:<entry>` Skill call, else "none". The process is killed
as soon as that call's input is complete, so no skill ever runs. See README.md.
"""
import argparse
import json
import logging
import os
import select
import subprocess
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

log = logging.getLogger("route_eval")

FIXTURE = {
    "api/upload.py": 'import time\n\nTIMEOUT = 30\n\ndef upload(user, data):\n    return {"ok": True}\n',
    "tests/test_upload.py": "def test_upload():\n    pass\n",
    "README.md": "# demo api\nWe recieve uploads.\n",
}


def make_fixture(root: Path) -> None:
    for rel, text in FIXTURE.items():
        (root / rel).parent.mkdir(parents=True, exist_ok=True)
        (root / rel).write_text(text)
    git = ["git", "-c", "user.email=eval@loop-spec", "-c", "user.name=eval"]
    subprocess.run(["git", "init", "-q"], cwd=root, check=True)
    subprocess.run(["git", "add", "-A"], cwd=root, check=True)
    subprocess.run([*git, "commit", "-qm", "fixture"], cwd=root, check=True)


def first_entry(query: str, plugin: str, model: str, cwd: Path, timeout: int) -> str:
    env = {k: v for k, v in os.environ.items() if k != "CLAUDECODE"}
    proc = subprocess.Popen(
        ["claude", "-p", query, "--plugin-dir", plugin, "--model", model,
         "--output-format", "stream-json", "--verbose", "--include-partial-messages"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, cwd=cwd, env=env)
    buf, tool, args, start = "", None, "", time.time()
    try:
        while time.time() - start < timeout:
            if not select.select([proc.stdout], [], [], 1.0)[0]:
                if proc.poll() is not None:
                    return "none"
                continue
            chunk = os.read(proc.stdout.fileno(), 65536)
            if not chunk:
                return "none"
            buf += chunk.decode("utf-8", "replace")
            while "\n" in buf:
                line, buf = buf.split("\n", 1)
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                if event.get("type") != "stream_event":
                    continue
                se = event["event"]
                kind = se.get("type")
                if kind == "content_block_start" and se["content_block"].get("type") == "tool_use":
                    tool, args = se["content_block"]["name"], ""
                elif kind == "content_block_delta" and tool and se["delta"].get("type") == "input_json_delta":
                    args += se["delta"]["partial_json"]
                elif kind == "content_block_stop" and tool:
                    if tool != "Skill":
                        return "none"
                    skill = json.loads(args or "{}").get("skill", "")
                    return skill.split(":", 1)[1] if skill.startswith("loop-spec:") else "none"
                elif kind == "message_stop":
                    return "none"
        return "timeout"
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait()


def main() -> int:
    here = Path(__file__).resolve().parent
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("queries", nargs="+", type=Path, help="query files (routing-*.json)")
    ap.add_argument("--plugin-dir", default=str(here.parent), help="plugin to load (default: this checkout)")
    ap.add_argument("--model", default="claude-opus-5-5")
    ap.add_argument("--runs", type=int, default=5, help="runs per query")
    ap.add_argument("--workers", type=int, default=6)
    ap.add_argument("--timeout", type=int, default=120, help="seconds per run")
    ap.add_argument("--out", type=Path, help="write per-query results as JSON here")
    opts = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(message)s")

    total = hits = 0
    results = {}
    with tempfile.TemporaryDirectory() as tmp:
        make_fixture(Path(tmp))
        for path in opts.queries:
            queries = json.loads(path.read_text())
            jobs = [q["query"] for q in queries for _ in range(opts.runs)]
            with ThreadPoolExecutor(opts.workers) as pool:
                got = list(pool.map(lambda q: first_entry(q, opts.plugin_dir, opts.model, Path(tmp), opts.timeout), jobs))
            rows = []
            for i, q in enumerate(queries):
                runs = got[i * opts.runs:(i + 1) * opts.runs]
                passed = sum(g in q["accept"] for g in runs)
                hits, total = hits + passed, total + len(runs)
                rows.append({**q, "got": runs})
                log.info("%s got=%s accept=%s :: %s", "PASS" if passed == len(runs) else "FAIL",
                         runs, q["accept"], q["query"].splitlines()[0][:70])
            results[path.name] = rows
    log.info("score %d/%d", hits, total)
    if opts.out:
        opts.out.write_text(json.dumps(results, indent=1) + "\n")
    return 0 if hits == total else 1


if __name__ == "__main__":
    raise SystemExit(main())
