---
name: cycle
description: "Take a feature request or spec file to a verified pull request with loop-spec: spec, task graph, parallel implementation, clean-checkout verify, one PR. Use whenever the user asks to add, build, or change behavior in their code beyond a one-line tweak, especially when they want it tested or landed as a PR, even if they never mention loop-spec. Not for a one-line fix (micro), a failing test or bug report (debug), or PR review comments (revise)."
argument-hint: "[--autonomous] <request or spec file>"
---

Start (or resume) a loop-spec run, from the repository:

    "${CLAUDE_SKILL_DIR}/../loop-spec/program/loop-spec" start --request "{request}"

- `{request}`: the user's request. For a spec file, pass `--request-file <path>` instead of `--request`.
- Add `--autonomous` if no one can answer questions during this run (a headless or
  unattended run, or arguments that start with `--autonomous`).

Then follow `${CLAUDE_SKILL_DIR}/../loop-spec/SKILL.md` until the run ends.
