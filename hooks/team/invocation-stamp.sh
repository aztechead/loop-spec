#!/usr/bin/env bash
# UserPromptSubmit hook: stamp the tokens of a /loop-spec:<skill> prompt for the driver.
#
# Claude Code contract: exit 0 always; stdout is ignored unless it is a JSON decision.
#
# Why: the cycle skill rewrites the free prose of $ARGUMENTS before it calls
# `cycle-driver.sh start`, and two of five eval runs dropped the `autonomous` token in
# that rewrite (the 2026-09-06 live evals, finding 3). The raw prompt is the one
# place the tokens are certain, and this hook is the one reader that sees it. It writes
# `.loop-spec/invocation-stamp.json`; `cycle-driver.sh start` merges any token the
# rewritten arguments lost and deletes the stamp, so a stale stamp never binds a later
# run (the driver also ignores one older than LOOP_SPEC_STAMP_MAX_AGE_MIN, default 30).
#
# Stands down (exit 0, nothing written) when the prompt is not a /loop-spec:<skill>
# invocation, when python3 is missing, or when the project dir is not writable.
#
# Kill switch: LOOP_SPEC_INVOCATION_STAMP=0.
# Environment variables (all optional):
#   LOOP_SPEC_INVOCATION_STAMP   Set to "0" to disable. Default: 1 (active).
#   CLAUDE_PROJECT_DIR           Project root; default $PWD.
set -euo pipefail

[[ "${LOOP_SPEC_INVOCATION_STAMP:-1}" == "0" ]] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0

input="$(cat)"
project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"

# The payload rides in the environment: the script itself is on stdin.
LOOP_SPEC_STAMP_INPUT="$input" python3 - "$project_dir" <<'PY' || exit 0
import json, os, re, sys, time

try:
    payload = json.loads(os.environ.get("LOOP_SPEC_STAMP_INPUT") or "")
except ValueError:
    sys.exit(0)
prompt = str(payload.get("prompt") or payload.get("message") or payload.get("content") or "")
m = re.match(r"^\s*(?:/loop-spec:|/loop-spec-|\$loop-spec-)(cycle|auto|intake|debug|micro)(?:\s+(.*))?$", prompt, re.S)
if not m:
    sys.exit(0)
target = os.path.join(sys.argv[1], ".loop-spec")
os.makedirs(target, exist_ok=True)
stamp = {"schema": 1, "skill": m.group(1), "args": (m.group(2) or "").strip(), "ts": int(time.time())}
tmp = os.path.join(target, "invocation-stamp.json.tmp")
with open(tmp, "w") as fh:
    json.dump(stamp, fh)
os.replace(tmp, os.path.join(target, "invocation-stamp.json"))
PY
exit 0
