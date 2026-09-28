---
name: spec
description: "Run or resume the SPEC phase of an in-progress loop-spec run: turn a feature request into acceptance criteria, boundaries, and open questions. Use to redo or continue just the spec step of a run identified by --slug. Not for starting a new feature end to end (use cycle) or for a one-line fix (use micro)."
---

Run this once, without changing directory, substituting the two placeholders:

    "${CLAUDE_SKILL_DIR}/../loop-spec/program/loop-spec" spec --project-root "{project-root}" --state-home "${CLAUDE_PLUGIN_DATA}" --slug "{slug}"

`{project-root}` is the repository (or workspace) root the user is working in.
`{slug}` identifies the run to resume; find it with the `status` entry if unknown.

Then read `${CLAUDE_SKILL_DIR}/../loop-spec/references/runner.md` in full and follow it
for every line the program prints.

If the launcher is missing, read the sibling hub `skills/loop-spec/SKILL.md`. On any other
non-zero exit, report the program's output and stop.
