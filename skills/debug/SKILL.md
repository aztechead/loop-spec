---
name: debug
description: "Reproduce and fix a specific failure with loop-spec: confirm the bug at the start commit, find the root cause, fix it with a regression test, and deliver a verified PR. Use whenever the user pastes a stack trace, names a failing test, or reports something broke or regressed. Not for new features (cycle) or problems with the machine or tools outside the repository."
argument-hint: "[--autonomous] <error, stack trace, or failing test>"
---

Start (or resume) a loop-spec run from the repository root:

    "${CLAUDE_SKILL_DIR}/../loop-spec/program/loop-spec" start --kind debug --project-root "{project-root}" --request "{request}"

- `{project-root}`: the root of the repository the user is working in.
- `{request}`: the error report, stack trace, or failing test, in the user's words.
- Add `--autonomous` when the arguments start with `--autonomous` (leave it out of the
  request), when the user asked for an unattended or headless run, or when you have no
  way to ask the user questions.

Then read `${CLAUDE_SKILL_DIR}/../loop-spec/SKILL.md` and follow it until the run ends.
If the command exits non-zero, its last line says what to do next.
