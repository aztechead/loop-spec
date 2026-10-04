---
name: micro
description: "Make a small, well-defined code change (a one-file fix, a rename, a tiny tweak) and land it as a verified PR in one short loop-spec pass. Not for a feature that needs planning (cycle) or a bug that needs investigation (debug)."
argument-hint: "[--autonomous] <request>"
---

Start (or resume) a loop-spec run, from the repository:

    "${CLAUDE_SKILL_DIR}/../loop-spec/program/loop-spec" start --kind micro --request "{request}"

- `{request}`: the user's request.
- Add `--autonomous` if no one can answer questions during this run (a headless or
  unattended run, or arguments that start with `--autonomous`).

Then follow `${CLAUDE_SKILL_DIR}/../loop-spec/SKILL.md` until the run ends.
