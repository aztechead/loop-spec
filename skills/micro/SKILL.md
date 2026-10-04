---
name: micro
description: "Make a small, well-defined code change (a one-file fix, a rename, a tiny tweak) and land it as a verified PR in one short loop-spec pass. Not for a feature that needs planning (cycle) or a bug that needs investigation (debug)."
argument-hint: "[--autonomous] <request>"
---

Start (or resume) a loop-spec run from the repository root:

    "${CLAUDE_SKILL_DIR}/../loop-spec/program/loop-spec" start --kind micro --project-root "{project-root}" --request "{request}"

- `{project-root}`: the root of the repository the user is working in.
- `{request}`: the user's request.
- Add `--autonomous` when the arguments start with `--autonomous` (leave it out of the
  request), when the user asked for an unattended or headless run, or when you have no
  way to ask the user questions.

Then read `${CLAUDE_SKILL_DIR}/../loop-spec/SKILL.md` and follow it until the run ends.
If the command exits non-zero, its last line says what to do next.
