#!/usr/bin/env bash
# plan-structure.sh - Check the task graph before critique and at PLAN exit.
# Usage: plan-structure.sh <feature-dir> <tasks.json>
# Uses EXECUTE's batching, file exclusions, and width floor. Does not edit inputs.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tasks="${2:?usage: plan-structure.sh <feature-dir> <tasks.json>}"
tasks="$(cd "$(dirname "$tasks")" && pwd -P)/$(basename "$tasks")"
. "$SCRIPT_DIR/exit-gate-prelude.sh" "${1:-}"
collapsed_tasks=""
trap '[[ -z "$collapsed_tasks" ]] || rm -f "$collapsed_tasks"' EXIT
# Preserve raw PLAN cycle validation before batching can rewrite dependencies.
raw_rc=0; lib dag-width < "$tasks" >/dev/null 2>&1 || raw_rc=$?
(( raw_rc == 3 )) && flag "[feasibility] task DAG has a dependency cycle"
(( raw_rc == 0 || raw_rc == 3 )) || { flag "[feasibility] cannot read task DAG"; exit 1; }
# EXECUTE dispatches the collapsed task graph. Measure that same graph here so
# PLAN's width gate and the rung selector cannot disagree about batching.
width_tasks="$tasks"
collapsed_tasks="$(mktemp "${TMPDIR:-/tmp}/loop-spec-plan-width.XXXXXX")" \
  || { flag "[width] could not allocate temporary collapsed task graph"; exit 1; }
if ! bash "$SCRIPT_DIR/task-batch.sh" collapse "$tasks" > "$collapsed_tasks" 2>/dev/null; then
  flag "[width] task-batch collapse failed; refusing to measure a graph different from EXECUTE"
  exit 1
fi
width_tasks="$collapsed_tasks"
rc=0; lib dag-width < "$width_tasks" >/dev/null 2>&1 || rc=$?
(( rc == 3 )) && flag "[feasibility] collapsed task DAG has a dependency cycle"
(( rc == 0 || rc == 3 )) || { flag "[feasibility] cannot read collapsed task DAG"; exit 1; }
# A task that names a file another task names waits for it (execute-prepare.sh adds
# the edge), so tasks that share files run as one chain however many there are: the
# 6.5.0 cycle here dispatched 12 tasks one at a time, 9 of its 11 edges file overlaps.
# This measures the width EXECUTE will see, declared plus overlap edges under the same
# excludes, and flags a chain while the plan can still be reshaped. Plans of up to
# three tasks are left alone by default; merging those buys nothing. A non-empty
# LOOP_SPEC_PLAN_MIN_WIDTH is an explicit operator request and applies to small plans
# too (default 2; 1 accepts any chain).
# ponytail: the overlap union mirrors execute-prepare.sh; extract one script when a third caller appears.
min_width_override="${LOOP_SPEC_PLAN_MIN_WIDTH-}"
min_width="${min_width_override:-2}"
[[ "$min_width" =~ ^[0-9]+$ ]] \
  || { echo "plan-structure: LOOP_SPEC_PLAN_MIN_WIDTH must be a non-negative integer, got '$min_width'" >&2; exit 2; }
if (( rc == 0 )); then
  excludes="$(fget '(.fileConflictExcludeGlobs // []) | join("\n")')" || excludes=""
  [[ -f ".loop-spec/file-conflict-exclude.txt" ]] && excludes="$excludes
$(cat ".loop-spec/file-conflict-exclude.txt")"
  width="$(EXCLUDES="$excludes" python3 - "$width_tasks" "$SCRIPT_DIR/dag-width.sh" <<'PY'
import fnmatch, json, os, subprocess, sys
tasks = json.load(open(sys.argv[1]))
globs = [g.strip() for g in os.environ.get("EXCLUDES", "").splitlines() if g.strip()]
def excluded(path): return any(fnmatch.fnmatch(path, g) for g in globs)
ordered = sorted(tasks, key=lambda t: str(t.get("id")))
for t in ordered:
    t["blockedBy"] = list(t.get("blockedBy") or [])
owners = {}
for i, a in enumerate(ordered):
    for b in ordered[i + 1:]:
        shared = [f for f in (a.get("files") or []) if f in (b.get("files") or []) and not excluded(f)]
        if shared and a["id"] not in b["blockedBy"] and b["id"] not in a["blockedBy"]:
            b["blockedBy"].append(a["id"])
        for f in shared:
            owners.setdefault(f, set()).update([a["id"], b["id"]])
run = subprocess.run(["bash", sys.argv[2]], input=json.dumps(ordered), capture_output=True, text=True)
if run.returncode not in (0, 3):
    raise RuntimeError("cannot measure effective task DAG: " + run.stderr)
top = sorted(owners.items(), key=lambda kv: (-len(kv[1]), kv[0]))[:3]
# Exit code 3 is the dag-width.sh cycle answer: the declared blockedBy plus the
# overlap edges just added can loop even when the declared graph alone does not.
width = -1 if run.returncode == 3 else int(run.stdout.strip() or 0)
print(json.dumps({"tasks": len(tasks), "width": width,
                  "shared": ["%s (%s)" % (f, ",".join(sorted(ids))) for f, ids in top]}))
PY
)" || { flag "[width] could not measure effective task DAG"; exit 1; }
  if [[ -n "$width" ]]; then
    n="$(jq -r '.tasks' <<<"$width")"; w="$(jq -r '.width' <<<"$width")"
    shared="$(jq -r '.shared | join("; ")' <<<"$width")"
    if [[ "$w" == "-1" ]]; then
      flag "[width] $n tasks: declared blockedBy plus file-overlap edges form a cycle EXECUTE will refuse to dispatch; give each shared file one owning task${shared:+: $shared}"
    elif (( min_width > 1 && w < min_width )) && { (( n >= 4 )) || [[ -n "$min_width_override" ]]; }; then
      if [[ -n "$min_width_override" ]]; then
        flag "[width] $n tasks run $w at a time below the explicit floor $min_width: review declared dependencies and file ownership to expose genuinely independent work; do not remove true prerequisites or add filler${shared:+: $shared}"
      else
        flag "[width] $n tasks run $w at a time: tasks that share a file wait for each other; give each shared file one owning task or merge the tasks that share it${shared:+: $shared}"
      fi
    fi
  fi
fi
(( flags == 0 )) || exit 1
