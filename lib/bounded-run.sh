#!/usr/bin/env bash
# Shared bounded-execution seam for external commands.
#
# Source this file, then call the helpers below. It exists because "run an outside
# command" was implemented five separate times across the delivery path and only ONE
# of them (lib/pr-delivery.sh) bounded the call. Every other caller could block
# forever, which in an unattended run is indistinguishable from slow progress: the
# container burns until its job deadline and no terminal result is ever written.
#
# Two distinct hazards, two helpers:
#
#   loop_spec_disable_interactive_prompts
#       Stop git/gh from ever asking a human anything. In a TTY-less container a
#       prompt usually cannot render, but `gh` and `git` can still sit waiting on a
#       credential helper. Nobody is there to type.
#
#   loop_spec_run_bounded <timeout_secs> <stdout_file> <stderr_file> <cmd> [args...]
#       Run one command with a wall-clock deadline. Returns the command's exit code,
#       or 124 on timeout (matching coreutils `timeout` and lib/run-with-watchdog.sh,
#       so callers already branching on 124 keep working). The child is started in
#       its own process group and the whole group is signalled, so a wrapper that
#       spawns children (git -> credential helper, gh -> browser opener) cannot
#       outlive the deadline.
#
#   loop_spec_resolve_timeout <value> <default>
#       Validate an operator-supplied timeout. Returns the default when unset,
#       rejects anything that is not a positive integer <= 3600. Deliberately
#       rejects 0: a zero deadline reads like "no limit" and is exactly the
#       footgun this file exists to remove.
#
# Timeouts are per-call, not per-phase. They bound a single network round trip; they
# are not a budget, and they do not cap how long a phase may legitimately work.
#
# python3 is a hard runtime dependency of loop-spec (see CLAUDE.md), and is already
# required by the callers that use this seam.

# Export the "never ask a human" environment for git and gh.
loop_spec_disable_interactive_prompts() {
  export GH_PROMPT_DISABLED=1
  export GIT_TERMINAL_PROMPT=0
}

# Echo a validated timeout, or the supplied default when the value is empty.
# Exits non-zero with a message on stderr when the value is present but invalid,
# so a typo surfaces at startup instead of silently disabling the deadline.
loop_spec_resolve_timeout() {
  local value="${1:-}" fallback="${2:-}"
  if [[ -z "$value" ]]; then
    printf '%s' "$fallback"
    return 0
  fi
  if [[ ! "$value" =~ ^[0-9]+$ ]] || [[ "${#value}" -gt 4 ]]; then
    echo "loop-spec: timeout must be a positive integer number of seconds (got '$value')" >&2
    return 1
  fi
  value=$((10#$value))
  if [[ "$value" -lt 1 || "$value" -gt 3600 ]]; then
    echo "loop-spec: timeout must be between 1 and 3600 seconds (got '$value')" >&2
    return 1
  fi
  printf '%s' "$value"
}

# Run one command under a wall-clock deadline, capturing stdout/stderr to files.
# Usage: loop_spec_run_bounded TIMEOUT STDOUT_FILE STDERR_FILE CMD [ARGS...]
# Honors LOOP_SPEC_BOUNDED_RUN_CWD when set, matching the delivery callers that run
# git/gh against a specific checkout.
loop_spec_run_bounded() {
  local timeout_secs="$1" stdout_file="$2" stderr_file="$3"
  shift 3
  python3 - "$timeout_secs" "$stdout_file" "$stderr_file" "$@" <<'PY'
import os, signal, subprocess, sys

timeout = int(sys.argv[1])
stdout_path, stderr_path = sys.argv[2], sys.argv[3]
argv = sys.argv[4:]
try:
    proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            universal_newlines=True, preexec_fn=os.setsid,
                            cwd=os.environ.get("LOOP_SPEC_BOUNDED_RUN_CWD") or None)
    try:
        out, err = proc.communicate(timeout=timeout)
        rc = proc.returncode
    except subprocess.TimeoutExpired:
        # Signal the whole group: a bare kill leaves credential helpers and other
        # grandchildren holding the pipes open, and communicate() would still block.
        os.killpg(proc.pid, signal.SIGTERM)
        try:
            out, err = proc.communicate(timeout=1)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            out, err = proc.communicate()
        err = (err or "") + "\ncommand timed out after %ds" % timeout
        rc = 124
except OSError as exc:
    out, err, rc = "", str(exc), 127
with open(stdout_path, "w") as f:
    f.write(out or "")
with open(stderr_path, "w") as f:
    f.write(err or "")
sys.exit(rc)
PY
}

# Run a command under a deadline, feeding it text on stdin.
# Usage: loop_spec_run_bounded_stdin TIMEOUT STDOUT_FILE STDERR_FILE STDIN_TEXT CMD [ARGS...]
# The stdin text is passed through the environment to the runner and written to the
# child's pipe -- never placed in argv and never written to disk. Callers holding a
# configured shell fragment that may embed a credential (the refresh hook) need both
# of those properties, so `bash -c "$fragment"` and a temp script are both wrong.
loop_spec_run_bounded_stdin() {
  local timeout_secs="$1" stdout_file="$2" stderr_file="$3" stdin_text="$4"
  shift 4
  LOOP_SPEC_BOUNDED_RUN_STDIN="$stdin_text" \
  python3 - "$timeout_secs" "$stdout_file" "$stderr_file" "$@" <<'PY'
import os, signal, subprocess, sys

timeout = int(sys.argv[1])
stdout_path, stderr_path = sys.argv[2], sys.argv[3]
argv = sys.argv[4:]
stdin_text = os.environ.pop("LOOP_SPEC_BOUNDED_RUN_STDIN", "")
env = dict(os.environ)
try:
    proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, universal_newlines=True,
                            preexec_fn=os.setsid, env=env,
                            cwd=os.environ.get("LOOP_SPEC_BOUNDED_RUN_CWD") or None)
    try:
        out, err = proc.communicate(input=stdin_text, timeout=timeout)
        rc = proc.returncode
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGTERM)
        try:
            out, err = proc.communicate(timeout=1)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            out, err = proc.communicate()
        err = (err or "") + "\ncommand timed out after %ds" % timeout
        rc = 124
except OSError as exc:
    out, err, rc = "", str(exc), 127
with open(stdout_path, "w") as f:
    f.write(out or "")
with open(stderr_path, "w") as f:
    f.write(err or "")
sys.exit(rc)
PY
}

# Run a shell FRAGMENT (not an argv) under the same deadline, with output merged to
# a single file. This is the shape the verify/regression callers need: they hold a
# configured command string, not an argument vector.
# Usage: loop_spec_run_bounded_shell TIMEOUT OUTPUT_FILE COMMAND_TEXT
loop_spec_run_bounded_shell() {
  local timeout_secs="$1" output_file="$2" command_text="$3"
  loop_spec_run_bounded "$timeout_secs" "$output_file" "$output_file.stderr" \
    bash -c "$command_text"
  local rc=$?
  if [[ -s "$output_file.stderr" ]]; then
    cat "$output_file.stderr" >>"$output_file" 2>/dev/null || true
  fi
  rm -f "$output_file.stderr" 2>/dev/null || true
  return "$rc"
}
