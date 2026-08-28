#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The Step 5 init procedure lives in the cycle skill's feature-init reference.
python3 - "$ROOT/skills/cycle/references/feature-init.md" "$ROOT/skills/shared/execute-subagent.md" <<'PY'
from pathlib import Path
import sys

cycle = Path(sys.argv[1]).read_text(encoding="utf-8")
mint = cycle[cycle.index("# Mint feat/{slug} when adopt-pr.sh did not select an existing PR."):]
start = mint.index('if [[ "$worktrees_enabled" == "0" ]]')
fallback = mint.index("else", start)
end = mint.index("fi", fallback)
disabled = mint[start:fallback]
enabled = mint[fallback:end]

# EXECUTE's one-shot subagent rung is where LOOP_SPEC_WORKTREES=0 actually lands
# (lib/execute-rung.sh selects `subagent`). Its prompt template must select the mode
# from the rung result BEFORE composing a prompt -- a template that emits `git worktree
# add` and falls back after the guard denies it costs a denied tool call and an error
# line on every headless run.
execute = Path(sys.argv[2]).read_text(encoding="utf-8")
inputs = execute[execute.index("## Inputs"):execute.index("## In-place single-repository mode")]
in_place = execute[execute.index("## In-place single-repository mode"):execute.index("## Lead wave loop")]
wave = execute[execute.index("## Lead wave loop"):execute.index("## Agent dispatch convention")]
prompt = execute[execute.index("Step 1 - The task worktree already exists"):execute.index("## Reviewer Agent prompt")]

checks = [
    ("adopted PR attaches instead of minting feat/{slug}",
     "attach-feature-worktree" in cycle and "adopting PR" in cycle),
    ("disabled branch performs an in-place checkout", 'checkout -b "feat/${slug}"' in disabled),
    ("disabled branch never invokes the worktree helper", "create-feature-worktree" not in disabled),
    ("enabled branch invokes the worktree helper", "create-feature-worktree" in enabled),
    ("the rung's worktreesEnabled is read before any prompt is composed",
     "worktreesEnabled" in inputs and "before composing any" in inputs),
    ("the worktree path is resolved in worktree mode only", "worktree mode only" in inputs),
    ("headless subagent isolation is lead-created worktrees",
     "subagentIsolation" in inputs and "lead-worktree" in inputs),
    ("the in-place mode never emits a worktree command",
     "worktree add" not in in_place and "EnterWorktree" not in in_place),
    ("the in-place mode is selected before a prompt is composed, not after a denial",
     "BEFORE resolving a worktree path" in in_place),
    ("the in-place reviewer reads the working-tree diff, not a task branch",
     "diff -- {task.files}" in in_place),
    ("the lead creates each task worktree before any Agent call",
     "any Agent call" in wave and "worktree add" in wave),
    ("wave width > 1 requires a created worktree per member",
     "Wave width > 1 is allowed only when" in wave),
    ("a failed worktree add serializes rather than overlapping in the feature root",
     "never overlap writers in the feature root" in wave),
    ("the implementer prompt tells the agent the worktree already exists",
     "The task worktree already exists" in prompt and "Do not run" in prompt),
    ("the implementer prompt does not invoke git worktree add",
     'worktree add "{worktree_path}"' not in prompt and "worktree add -b" not in prompt),
]
failures = 0
for name, passed in checks:
    print(("PASS: " if passed else "FAIL: ") + name)
    failures += not passed
print(f"Results: {len(checks) - failures} passed, {failures} failed")
raise SystemExit(1 if failures else 0)
PY
