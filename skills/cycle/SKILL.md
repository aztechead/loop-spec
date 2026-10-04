---
name: cycle
description: "Take a feature request or spec file to a verified pull request with loop-spec: spec, task graph, parallel implementation, clean-checkout verify, one PR. Use whenever the user asks to add, build, or change behavior in their code beyond a one-line tweak, especially when they want it tested or landed as a PR, even if they never mention loop-spec. Not for a one-line fix (micro), a failing test or bug report (debug), or PR review comments (revise)."
argument-hint: "[--autonomous] <request or spec file>"
---

Start (or resume) a loop-spec run from the repository root:

    "${CLAUDE_SKILL_DIR}/../loop-spec/program/loop-spec" start --project-root "{project-root}" --request "{request}"

- `{project-root}`: the root of the repository the user is working in.
- `{request}`: the user's request. For a spec file, pass `--request-file <path>` instead of `--request`.
- Add `--autonomous` when the arguments start with `--autonomous` (leave it out of the
  request), when the user asked for an unattended or headless run, or when you have no
  way to ask the user questions.

Then read `${CLAUDE_SKILL_DIR}/../loop-spec/SKILL.md` and follow it until the run ends.
If the command exits non-zero, its last line says what to do next.
