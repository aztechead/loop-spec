---
name: debug
description: "Reproduces and fixes a specific failure with loop-spec: confirms the bug at the start commit, finds the root cause, fixes it with a regression test, and delivers a verified PR. Use whenever the user pastes a stack trace, names a failing test, or reports something broke or regressed. Not for new features (cycle) or problems with the machine or tools outside the repository."
argument-hint: "[--autonomous|--supervised] <error, stack trace, or failing test>"
---

Start (or resume) a loop-spec run from the repository, or, for a change across
repositories, from the workspace root (the directory holding `.loop-spec/workspace.json`):

    "${CLAUDE_SKILL_DIR}/../loop-spec/program/loop-spec" start --kind debug --request "{request}"

- `{request}`: the error report, stack trace, or failing test, in the user's words.
- Add `--branch NAME` and `--title "..."` when the user names the branch or the PR
  title for this change.
- Add `--autonomous` if no one can answer questions during this run (a headless or
  unattended run, or arguments that start with `--autonomous`). Add `--supervised` instead
  when the arguments start with `--supervised`.
- When the request is long or holds quotes, backticks, or `$`, write it to a file and
  pass `--request-file <path>` instead of `--request`.

Then follow `${CLAUDE_SKILL_DIR}/../loop-spec/SKILL.md` until the run ends.
