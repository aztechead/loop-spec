---
name: debug
description: "Diagnose and fix a specific failure: reproduce a bug or error report, find the root cause, and land a fix with a regression test. Use for a stack trace, a failing test, or a reported bug. Not for a new feature (use cycle) or a one-line style/typo fix with no bug (use micro)."
---

Run this once, without changing directory, substituting the two placeholders:

    "${LOOP_SPEC_SKILL_DIR}/../loop-spec/program/loop-spec" debug --project-root "{project-root}" --request "{request}"

`{project-root}` is the repository (or workspace) root the user is working in.
`{request}` is the error report, stack trace, or bug description to reproduce and fix.

Then read the last stdout line, `LOOP_SPEC_NEXT {"kind": ..., "path": ...}`, open the
file at `path`, and act on it:

- `step`: do what `step.json` says (dispatch the named role in the named directory with
  the composed prompt; the worker writes the result file it names), then run
  `"${LOOP_SPEC_SKILL_DIR}/../loop-spec/program/loop-spec" submit --project-root "{project-root}" --step <stepAttemptId> [--dispatch <name>]`
  and repeat from "read the last stdout line".
- `question`: ask the user the question in `question.json` (with `AskUserQuestion`), then run
  `... loop-spec answer --project-root "{project-root}" --question <id> --answer "<text>"`
  and repeat.
- `result`: report the result file to the user in the chat shape. Stop.

If the launcher is missing, read the sibling hub `skills/loop-spec/SKILL.md`. On any other
non-zero exit, report the program's output and stop.
