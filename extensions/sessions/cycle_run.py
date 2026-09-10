#!/usr/bin/env python3
"""Launch fresh phase sessions until a durable terminal result or a bounded stop.

The caller starts this process once. Only a fresh phase-handoff result permits a
relaunch; a successful CLI exit alone never means the requested work completed.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile

from session_run import load_profile

PLUGIN = Path(__file__).resolve().parents[2]


def result_stamp(path):
    try:
        info = path.stat()
        return info.st_ino, info.st_mtime_ns, path.read_bytes()
    except FileNotFoundError:
        return None


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cwd", default=".")
    parser.add_argument("--profile", choices=("claude", "codex", "opencode"), required=True)
    parser.add_argument("--prompt-file", required=True)
    parser.add_argument("--max-invocations", type=int, default=16)
    parser.add_argument("--timeout", type=float, default=3600)
    args = parser.parse_args(argv)
    if args.max_invocations < 1 or args.timeout <= 0:
        parser.error("--max-invocations and --timeout must be positive")
    root = Path(args.cwd).resolve()
    task = Path(args.prompt_file).read_text(encoding="utf-8").strip()
    if not root.is_dir() or not task:
        parser.error("--cwd must exist and --prompt-file must contain a task")
    profile = load_profile(args.profile)
    for key in ("cycle_entry", "cycle_resume"):
        if not isinstance(profile.get(key), str) or not profile[key].strip():
            parser.error("session profile is missing " + key)
    env = dict(os.environ, LOOP_SPEC_AUTONOMOUS="1", LOOP_SPEC_NON_INTERACTIVE="1",
               LOOP_SPEC_HARNESS=args.profile)
    state_dir = root / ".loop-spec"
    state_dir.mkdir(exist_ok=True)
    result_path = state_dir / "last-result.json"
    report = {"status": "exhausted", "reason": "invocation-limit", "invocations": 0,
              "result": str(result_path), "sessions": []}
    with (state_dir / "launcher.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("cycle-launch: another launcher owns this checkout", file=sys.stderr)
            return 2
        with tempfile.TemporaryDirectory(prefix="launcher-", dir=str(state_dir)) as temp:
            prompt_path = Path(temp) / "prompt.md"
            phase = "spec"
            for attempt in range(args.max_invocations):
                prompt = profile["cycle_entry"].replace("{task}", task) if attempt == 0 else profile["cycle_resume"]
                prompt_path.write_text(prompt, encoding="utf-8")
                model = subprocess.run(["bash", str(PLUGIN / "lib/feature-init.sh"), "phase-model", phase],
                                       cwd=root, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                if model.returncode:
                    report.update(status="failed", reason="phase-model: " + model.stderr.strip())
                    break
                before = result_stamp(result_path)
                command = [sys.executable, str(PLUGIN / "extensions/sessions/session_run.py"),
                           "--profile", args.profile, "--cwd", str(root), "--prompt-file", str(prompt_path),
                           "--model", model.stdout.strip(), "--timeout", str(args.timeout),
                           "--lead", "--plugin-root", str(PLUGIN)]
                print("cycle-launch: invocation %d phase=%s" % (attempt + 1, phase), file=sys.stderr, flush=True)
                child = subprocess.Popen(command, env=env, text=True, stdout=subprocess.PIPE)
                previous_term = signal.getsignal(signal.SIGTERM)
                def interrupt(signum, frame):
                    child.terminate()
                signal.signal(signal.SIGTERM, interrupt)
                try:
                    output, _ = child.communicate()
                except KeyboardInterrupt:
                    child.terminate()
                    output, _ = child.communicate()
                finally:
                    signal.signal(signal.SIGTERM, previous_term)
                report["invocations"] += 1
                try:
                    report["sessions"].append(json.loads(output))
                except ValueError:
                    report["sessions"].append({"exit": child.returncode, "error": output})
                after = result_stamp(result_path)
                if child.returncode or after is None or after == before:
                    report.update(status="failed", reason="session-failed-or-no-fresh-result")
                    subprocess.run(["bash", str(PLUGIN / "lib/cycle-reconcile.sh"), "--result-root", str(root),
                                    "--reason", report["reason"]], env=env, stdout=subprocess.DEVNULL)
                    break
                try:
                    result = json.loads(after[2])
                    if not isinstance(result, dict) or result.get("schema") != 1 or not result.get("loopSpecVersion"):
                        raise ValueError("missing result contract fields")
                    if result.get("status") not in ("completed", "paused", "escalated", "terminal", "failed"):
                        raise ValueError("unknown result status")
                    if result.get("converged") is True and result["status"] != "completed":
                        raise ValueError("only completed results can converge")
                except ValueError as exc:
                    report.update(status="failed", reason="invalid-result: " + str(exc))
                    break
                if result.get("status") == "paused" and result.get("reason") == "phase-handoff":
                    phase = result.get("phaseReached")
                    if not isinstance(phase, str) or not phase:
                        report.update(status="failed", reason="handoff-has-no-next-phase")
                        break
                    continue
                report.update(status="completed" if result.get("converged") is True else
                              "paused" if result["status"] == "completed" else result["status"],
                              reason=result.get("reason") or result.get("status"))
                break
        target = state_dir / "launcher-result.json"
        temporary = target.with_suffix(".tmp")
        temporary.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        os.replace(temporary, target)
    print(json.dumps(report))
    return 0 if report["status"] == "completed" else 1


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except (OSError, ValueError) as exc:
        print("cycle-launch: " + str(exc), file=sys.stderr)
        sys.exit(2)
