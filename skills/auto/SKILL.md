---
name: auto
description: "Route a request to the right loop-spec entry: a full cycle, a small change, a debug, a revision of an open pull request, or a mechanical operation done directly with no cycle. Use when the request does not say which entry it needs."
---

Run this once, without changing directory, substituting the two placeholders:

    "${CLAUDE_SKILL_DIR}/../loop-spec/program/loop-spec" auto --project-root "{project-root}" --request "{request}"

`{project-root}` is the repository (or workspace) root the user is working in.
`{request}` is the user's request text; pass a file with `--request-file` instead when
they gave a spec file.

When the user asks for a headless run or names `--answer-policy default`, add
`--answer-policy default` to this command.

Then read `${CLAUDE_SKILL_DIR}/../loop-spec/references/runner.md` in full and follow it
for every line the program prints.

If the launcher is missing, read the sibling hub `skills/loop-spec/SKILL.md`. On any other
non-zero exit, report the program's output and stop.
