---
name: debug
description: "Diagnose and fix a specific failure: reproduce a bug or error report, find the root cause, and land a fix with a regression test. Use whenever the user pastes a stack trace, names a failing test, or reports that their code broke or regressed, even if they never say debug. Not for a new feature (use cycle), a one-line style/typo fix with no bug (use micro), or a problem with a tool or machine setup outside the repository's code."
argument-hint: "<error, stack trace, or failing test>"
---

Run this once, without changing directory, substituting the two placeholders:

    "${CLAUDE_SKILL_DIR}/../loop-spec/program/loop-spec" debug --project-root "{project-root}" --request "{request}"

`{project-root}` is the repository (or workspace) root the user is working in.
`{request}` is the error report, stack trace, or bug description to reproduce and fix.

When the user asks for a headless run or names `--answer-policy default`, add
`--answer-policy default` to this command.

Then read `${CLAUDE_SKILL_DIR}/../loop-spec/references/runner.md` in full and follow it
for every line the program prints.

If the launcher is missing, read the sibling hub `${CLAUDE_SKILL_DIR}/../loop-spec/SKILL.md`. On any other
non-zero exit, report the program's output and stop.
