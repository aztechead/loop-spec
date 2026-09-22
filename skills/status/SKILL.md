---
name: status
description: "Show the state of a loop-spec run: current phase, open question or step, budget, and result if finished. Use to check progress or find out what a run is waiting on. Not for advancing a run (use its phase entry, e.g. spec, plan, execute)."
---

Run this once, without changing directory:

    "${LOOP_SPEC_SKILL_DIR}/../loop-spec/program/loop-spec" status --project-root "{project-root}" [--slug "{slug}"]

`{project-root}` is the repository (or workspace) root the user is working in.
Pass `--slug` to see one run's detail; omit it to list the runs known for this repository.

Report the command's output to the user. This command never advances a run and always
exits 0. If the launcher is missing, read the sibling hub `skills/loop-spec/SKILL.md`.
