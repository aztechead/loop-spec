#!/usr/bin/env python3
"""session_run.py - Run one agent node as a disposable headless CLI session.

Why: the in-harness rungs dispatch through the harness's own subagent tool and share
the lead's process; a headless run (`claude -p`, `codex exec`, `opencode run`) has no
persistent session to keep a fleet alive, so EXECUTE's `session` rung runs each task as
its own CLI process instead (docs/loop-spec/orchestrator-port-plan.md, WP5). The launch
line for each CLI is data in profiles/<cli>.toml, never a branch here. The process
exit is the completion signal: print mode has no terminal to observe, so no hook relay
is wired.

Usage:
    session_run.py --profile <name|path> --cwd <dir> --prompt-file <file>
                   [--model <selector>] [--bypass] [--seed-from <repo root>]
                   [--log-dir <dir>] [--timeout <seconds>]

Prints one JSON line:
    {"status": "completed|failed|timeout|env-fault", "exit": <int|null>, "argv": [...],
     "stdout": <path>, "stderr": <path>, "durationSeconds": <float>,
     "envFault": <pattern|null>}

Exit codes: 0 completed; 1 the CLI exited non-zero; 2 bad call, or the profile is
missing or malformed; 3 the CLI binary is not on PATH, or python3 is older than 3.11;
4 the CLI failed on a provider or transport line the profile names (retry, do not
charge the attempt); 5 the timeout elapsed and the process was killed.
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time

try:
    import tomllib
except ImportError:
    print("session_run: python3 >= 3.11 (tomllib) is required for the session layer", file=sys.stderr)
    sys.exit(3)

PROFILES_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "profiles")
TAIL_BYTES = 64 * 1024
ANSI = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")
LIST_KEYS = ("launch_args", "guarded_args", "bypass_args", "seed_files", "env_fault_patterns")


def die(message, code=2):
    print("session_run: %s" % message, file=sys.stderr)
    sys.exit(code)


def profile_path(name):
    if name.endswith(".toml") or "/" in name:
        return name
    override = os.environ.get("LOOP_SPEC_SESSION_PROFILES", "")
    if override:
        candidate = os.path.join(override, name + ".toml")
        if os.path.isfile(candidate):
            return candidate
    return os.path.join(PROFILES_DIR, name + ".toml")


def load_profile(name):
    path = profile_path(name)
    try:
        with open(path, "rb") as fh:
            profile = tomllib.load(fh)
    except FileNotFoundError:
        die("no profile %r (looked at %s)" % (name, path))
    except tomllib.TOMLDecodeError as exc:
        die("profile %s is not valid TOML: %s" % (path, exc))
    if not isinstance(profile.get("binary"), str) or not profile["binary"]:
        die("profile %s has no `binary`" % path)
    template = profile.get("prompt_template", "{prompt}")
    if not isinstance(template, str) or "{prompt}" not in template:
        die("profile %s: `prompt_template` must contain {prompt}" % path)
    for key in LIST_KEYS:
        value = profile.get(key, [])
        if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
            die("profile %s: `%s` must be a list of strings" % (path, key))
        profile[key] = value
    env = profile.get("env", {})
    if not isinstance(env, dict) or any(not isinstance(v, str) for v in env.values()):
        die("profile %s: `[env]` values must be strings" % path)
    profile["env"] = env
    profile["prompt_template"] = template
    profile["path"] = path
    return profile


def build_argv(profile, prompt, model, bypass):
    argv = [profile["binary"]] + profile["launch_args"]
    argv += profile["bypass_args"] if bypass else profile["guarded_args"]
    if model and model != "inherit":
        flag = profile.get("model_flag")
        if not isinstance(flag, str) or not flag:
            die("profile %s names no `model_flag`, so --model cannot be honored" % profile["path"])
        argv += [flag, model]
    argv.append(profile["prompt_template"].replace("{prompt}", prompt))
    return argv


def child_env(profile_env):
    # The session is an implementer, not a member of the cycle that dispatched it: the
    # plugin bindings and every LOOP_SPEC_* setting would make it act as the lead, and an
    # inherited session id would append its transcript to the lead's.
    env = {k: v for k, v in os.environ.items()
           if not k.startswith("LOOP_SPEC_")
           and k not in ("CLAUDE_PROJECT_DIR", "CLAUDE_SKILL_DIR", "CLAUDE_PLUGIN_ROOT",
                         "CLAUDE_CODE_SESSION_ID")}
    env.update(profile_env)
    return env


def seed(profile, source, target):
    if not source or os.path.realpath(source) == os.path.realpath(target):
        return
    for rel in profile["seed_files"]:
        src = os.path.join(source, rel)
        dst = os.path.join(target, rel)
        if os.path.isfile(src) and not os.path.exists(dst):
            os.makedirs(os.path.dirname(dst) or ".", exist_ok=True)
            shutil.copyfile(src, dst)


def env_fault(profile, *paths):
    tail = ""
    for path in paths:
        try:
            with open(path, "rb") as fh:
                fh.seek(0, os.SEEK_END)
                fh.seek(max(0, fh.tell() - TAIL_BYTES))
                tail += fh.read().decode("utf-8", errors="replace")
        except OSError:
            continue
    lines = [ANSI.sub("", line) for line in tail.splitlines()]
    for pattern in profile["env_fault_patterns"]:
        try:
            compiled = re.compile(pattern)
        except re.error as exc:
            die("profile %s: env_fault_pattern %r does not compile: %s" % (profile["path"], pattern, exc))
        if any(compiled.search(line) for line in lines):
            return pattern
    return None


def main(argv):
    parser = argparse.ArgumentParser(prog="session_run.py", add_help=True)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--cwd", required=True)
    parser.add_argument("--prompt-file", required=True)
    parser.add_argument("--model", default="inherit")
    parser.add_argument("--bypass", action="store_true")
    parser.add_argument("--seed-from", default="")
    parser.add_argument("--log-dir", default="")
    parser.add_argument("--timeout", type=float, default=None)
    try:
        args = parser.parse_args(argv)
    except SystemExit:
        return 2
    if not os.path.isdir(args.cwd):
        die("--cwd %s is not a directory" % args.cwd)
    try:
        with open(args.prompt_file, encoding="utf-8") as fh:
            prompt = fh.read()
    except OSError as exc:
        die("cannot read --prompt-file: %s" % exc)
    if not prompt.strip():
        die("--prompt-file %s is empty" % args.prompt_file)
    timeout = args.timeout
    if timeout is None:
        raw = os.environ.get("LOOP_SPEC_SESSION_TIMEOUT_SECS", "3600")
        try:
            timeout = float(raw)
        except ValueError:
            die("LOOP_SPEC_SESSION_TIMEOUT_SECS must be a number, got %r" % raw)
    if timeout <= 0:
        die("the timeout must be positive")

    profile = load_profile(args.profile)
    if shutil.which(profile["binary"]) is None:
        die("%s is not on PATH (profile %s)" % (profile["binary"], profile["path"]), 3)
    command = build_argv(profile, prompt, args.model, args.bypass)
    seed(profile, args.seed_from, args.cwd)

    log_dir = args.log_dir or os.path.join(args.cwd, ".loop-spec", "sessions")
    os.makedirs(log_dir, exist_ok=True)
    stamp = "%s-%d-%d" % (profile.get("name", "session"), int(time.time()), os.getpid())
    out_path = os.path.join(log_dir, stamp + ".stdout")
    err_path = os.path.join(log_dir, stamp + ".stderr")

    started = time.time()
    status, code = "completed", None
    with open(out_path, "wb") as out, open(err_path, "wb") as err:
        proc = subprocess.Popen(command, cwd=args.cwd, env=child_env(profile["env"]),
                                stdin=subprocess.DEVNULL, stdout=out, stderr=err)
        try:
            code = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
            status = "timeout"
    fault = None
    if status == "completed" and code != 0:
        status = "failed"
    if status != "completed":
        fault = env_fault(profile, out_path, err_path)
        if fault is not None:
            status = "env-fault"
    print(json.dumps({"status": status, "exit": code, "argv": command, "stdout": out_path,
                      "stderr": err_path, "durationSeconds": round(time.time() - started, 3),
                      "envFault": fault}))
    return {"completed": 0, "failed": 1, "env-fault": 4, "timeout": 5}[status]


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
