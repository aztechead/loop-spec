---
name: cycle
description: Run the full loop-spec cycle (SPEC, PLAN, EXECUTE, VERIFY, ITERATE, DELIVER) on a feature request or spec file and deliver a PR. Use for a feature or change that needs planning, implementation, and verification. Not for a one-line fix (use micro), a failing test or bug report (use debug), or PR review comments (use revise).
---

Run this once, without changing directory, substituting the two placeholders:

    "${CLAUDE_SKILL_DIR}/../loop-spec/program/loop-spec" cycle --project-root "{project-root}" --state-home "${CLAUDE_PLUGIN_DATA}" --request "{request}"

`{project-root}` is the repository (or workspace) root the user is working in.
`{request}` is the user's request text; pass a file with `--request-file` instead when
they gave a spec file.

Then read `${CLAUDE_SKILL_DIR}/../loop-spec/references/runner.md` in full and follow it
for every line the program prints.

If the launcher is missing, read the sibling hub `skills/loop-spec/SKILL.md`. On any other
non-zero exit, report the program's output and stop.
