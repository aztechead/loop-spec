#!/usr/bin/env python3
"""Normalize native tool inputs before running the shared PreToolUse guards.

Exit 2 and stderr are the denial contract; adapters must preserve that decision.
Patch tools can touch several paths, including a move destination, in one call.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent


def main():
    payload = json.load(sys.stdin)
    name = payload.get("tool_name", "")
    args = payload.get("tool_input") or {}
    cwd = payload.get("cwd") or os.getcwd()
    env = dict(os.environ, CLAUDE_PROJECT_DIR=cwd, CLAUDE_PLUGIN_ROOT=str(ROOT))
    calls = []
    if name in ("Bash", "bash", "Execute"):
        payload.update(tool_name="Bash", tool_input=args)
        calls = [("hooks/team/" + script + ".sh", payload) for script in
                 ("no-worktrees-guard", "result-forgery-guard", "nested-session-guard")]
    elif name in ("Write", "Edit", "write", "edit", "WriteFile", "EditFile", "apply_patch", "patch"):
        if name in ("apply_patch", "patch"):
            patch = (args.get("command") or args.get("patchText") or args.get("patch") or "").replace("\r\n", "\n")
            paths = re.findall(r"^\*\*\* (?:Add File|Update File|Delete File|Move to): (.+)$", patch, re.M)
            if not paths:
                print("DENY: patch input has no recognizable target paths", file=sys.stderr)
                return 2
        else:
            paths = [args.get("file_path") or args.get("filePath") or args.get("path")]
        for path in paths:
            if not isinstance(path, str) or not path:
                print("DENY: write input has no target path", file=sys.stderr)
                return 2
            target = str((Path(cwd) / path).resolve())
            normalized = dict(payload, tool_name="Write", tool_input={"file_path": target})
            calls.append(("hooks/restrict-agent-paths.sh", normalized))
    elif name in ("Agent", "spawn_agent", "task", "dispatch_subagent"):
        calls = [("hooks/team/no-worktrees-guard.sh", dict(payload, tool_name="Agent"))]
    for script, data in calls:
        result = subprocess.run(["bash", str(ROOT / script)], input=json.dumps(data),
                                cwd=cwd, env=env, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, universal_newlines=True, timeout=10)
        if result.returncode != 0:
            print(result.stderr.strip() or "DENY: " + script, file=sys.stderr)
            return 2
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, TypeError, AttributeError, subprocess.TimeoutExpired) as exc:
        print("DENY: tool guard could not verify the call: %s" % exc, file=sys.stderr)
        sys.exit(2)
