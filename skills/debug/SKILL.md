---
name: debug
description: "Diagnose and fix a specific failure: reproduce a bug or error report, find the root cause, and land a fix with a regression test. Use for a stack trace, a failing test, or a reported bug. Not for a new feature (use cycle) or a one-line style/typo fix with no bug (use micro)."
---

Run this once, without changing directory, substituting the two placeholders:

    "${CLAUDE_SKILL_DIR}/../loop-spec/program/loop-spec" debug --project-root "{project-root}" --state-home "${CLAUDE_PLUGIN_DATA}" --request "{request}"

`{project-root}` is the repository (or workspace) root the user is working in.
`{request}` is the error report, stack trace, or bug description to reproduce and fix.

Then read `${CLAUDE_SKILL_DIR}/../loop-spec/references/runner.md` in full and follow it
for every line the program prints.

If the launcher is missing, read the sibling hub `skills/loop-spec/SKILL.md`. On any other
non-zero exit, report the program's output and stop.
