# Phase 2: the plan

For the lead of a loop-spec run in PLAN. The job: write `plan.json` in `runDir`, the
task graph the program runs, and have `LS status` accept it before any task starts.

## plan.json

Use this shape; the program reads these fields. This plan, for a spec with criteria
AC-1 to AC-3, runs T-1 and T-2 in parallel, then T-3 once both are merged:

```json
{"prepare": "uv sync",
 "checks": [{"command": "uv run ruff check", "source": "CLAUDE.md"},
            {"command": "uv run mypy calc", "source": "AGENTS.md"}],
 "tasks": [{"id": "T-1", "title": "Add lerp with its tests", "dependsOn": [],
            "files": ["calc/lerp.py", "tests/test_lerp.py"], "criteria": ["AC-1"],
            "verify": ".venv/bin/python -m pytest -q tests/test_lerp.py"},
           {"id": "T-2", "title": "Add clamp with its tests", "dependsOn": [],
            "files": ["calc/clamp.py", "tests/test_clamp.py"], "criteria": ["AC-2"],
            "verify": ".venv/bin/python -m pytest -q tests/test_clamp.py"},
           {"id": "T-3", "title": "Export both and document them", "dependsOn": ["T-1", "T-2"],
            "files": ["calc/__init__.py", "README.md"], "criteria": ["AC-3"],
            "verify": ".venv/bin/python -c 'from calc import lerp, clamp'"}]}
```

- `prepare` installs what the checks need into a fresh checkout (`.venv/bin/python`
  exists only after it). The program runs it in each task's worktree and before every
  verify. Leave it out when nothing needs installing.
- `checks` are the repository's own required checks. Read each rules file `LS status`
  lists and put every command they say a change must pass (lint, format, typecheck,
  tests, build) here, with the file it came from; write `[]` when they require none.
  When one fails at verify, the program runs it at the base too: output that is the
  same there is pre-existing and does not fail the run; new output does.
- Every `check`, `verify`, and `checks` command is a bash command run from the
  repository root.

## Tasks

A task is a unit one implementer can build and test on its own.

- Keep code and its tests in the same task. Give each file one owning task.
- `dependsOn` only what a task needs merged first; independent tasks run in parallel. A
  small change is one task; split work only where the parts are independent.
- Each task's `verify` runs the tests that exercise it, and every criterion is named in
  some task's `criteria`.
- When the change alters behavior a doc describes, or a public symbol other code calls,
  include that update in a task: migrate the callers, then remove what they no longer
  use.

## The check

Run `LS status`. It validates the graph and names each problem with what would fix it:
a missing or duplicate id, an unknown dependency, a cycle, or a task naming a criterion
the spec does not have. Fix `plan.json` and run it again until it accepts the plan. It
also names any criterion no task covers (add it to a task's `criteria`), and any two
tasks that can run at once but list the same file, which would conflict when merged
(give the file one owner, or make one task depend on the other). Its `next` line then
names the first tasks to start.
