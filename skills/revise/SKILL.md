---
name: revise
description: "Address reviewer feedback on an already-open pull request. Use when a human or bot left PR review comments to resolve. Not for starting new work (use cycle) or fixing a bug found outside review (use debug)."
---

Run this once, without changing directory, substituting the two placeholders:

    "${CLAUDE_SKILL_DIR}/../loop-spec/program/loop-spec" revise --project-root "{project-root}" --state-home "${CLAUDE_PLUGIN_DATA}" --pr "{pr}"

`{project-root}` is the repository (or workspace) root the user is working in.
`{pr}` is the pull request number or URL whose review feedback to address.

Then read `${CLAUDE_SKILL_DIR}/../loop-spec/references/runner.md` in full and follow it
for every line the program prints.

If the launcher is missing, read the sibling hub `skills/loop-spec/SKILL.md`. On any other
non-zero exit, report the program's output and stop.
