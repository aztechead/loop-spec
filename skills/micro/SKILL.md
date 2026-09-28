---
name: micro
description: "Make a small, well-defined change (a one-file fix, a typo, a tiny tweak) in one autonomous pass. Use for a change too small to need a spec/plan/execute/verify cycle. Not for a feature that needs planning (use cycle) or a bug that needs root-cause investigation (use debug)."
---

Run this once, without changing directory, substituting the two placeholders:

    "${CLAUDE_SKILL_DIR}/../loop-spec/program/loop-spec" micro --project-root "{project-root}" --state-home "${CLAUDE_PLUGIN_DATA}" --request "{request}"

`{project-root}` is the repository (or workspace) root the user is working in.
`{request}` is the user's request text; pass a file with `--request-file` instead when
they gave a spec file.

Then read `${CLAUDE_SKILL_DIR}/../loop-spec/references/runner.md` in full and follow it
for every line the program prints.

If the launcher is missing, read the sibling hub `skills/loop-spec/SKILL.md`. On any other
non-zero exit, report the program's output and stop.
