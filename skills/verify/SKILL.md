---
name: verify
description: "Run or resume the VERIFY phase of an in-progress loop-spec run: check the implementation against the spec's acceptance criteria. Use to redo or continue just the verify step of a run identified by --slug. Not for starting a new feature end to end (use cycle)."
---

Run this once, without changing directory, substituting the two placeholders:

    "${CLAUDE_SKILL_DIR}/../loop-spec/program/loop-spec" verify --project-root "{project-root}" --slug "{slug}"

`{project-root}` is the repository (or workspace) root the user is working in.
`{slug}` identifies the run to resume; find it with the `status` entry if unknown.

When the user asks for a headless run or names `--answer-policy default`, add
`--answer-policy default` to this command.

Then read `${CLAUDE_SKILL_DIR}/../loop-spec/references/runner.md` in full and follow it
for every line the program prints.

If the launcher is missing, read the sibling hub `skills/loop-spec/SKILL.md`. On any other
non-zero exit, report the program's output and stop.
