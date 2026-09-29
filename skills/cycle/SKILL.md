---
name: cycle
description: "Run the full loop-spec cycle (SPEC, PLAN, EXECUTE, VERIFY, ITERATE, DELIVER) on a feature request or spec file and deliver a PR. Use whenever the user asks to add, build, or change behavior in their code beyond a one-line tweak, especially when they want it tested or landed as a pull request, even if they never mention loop-spec. Not for a one-line fix (use micro), a failing test or bug report (use debug), PR review comments (use revise), or a question that changes no code."
---

Run this once, without changing directory, substituting the two placeholders:

    "${CLAUDE_SKILL_DIR}/../loop-spec/program/loop-spec" cycle --project-root "{project-root}" --request "{request}"

`{project-root}` is the repository (or workspace) root the user is working in.
`{request}` is the user's request text; pass a file with `--request-file` instead when
they gave a spec file.

When the user asks for a headless run or names `--answer-policy default`, add
`--answer-policy default` to this command.

Then read `${CLAUDE_SKILL_DIR}/../loop-spec/references/runner.md` in full and follow it
for every line the program prints.

If the launcher is missing, read the sibling hub `skills/loop-spec/SKILL.md`. On any other
non-zero exit, report the program's output and stop.
