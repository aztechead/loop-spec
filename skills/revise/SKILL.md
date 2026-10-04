---
name: revise
description: "Address review feedback on an open pull request with loop-spec: turn each review comment into a checked criterion, fix them on the PR's own branch, verify, and push. Use when a person or bot left review comments on a PR to resolve. Not for new work (cycle) or a bug found outside review (debug)."
argument-hint: "[--autonomous] <PR number or URL> [instruction]"
---

Start (or resume) a loop-spec run on the pull request:

    "${CLAUDE_SKILL_DIR}/../loop-spec/program/loop-spec" start --project-root "{project-root}" --pr "{pr}" --request "{instruction}"

- `{project-root}`: the root of the repository the user is working in.
- `{pr}`: the PR number or URL.
- `{instruction}`: anything the user said beyond the PR reference; leave `--request`
  out when there is nothing.
- Add `--autonomous` when the arguments start with `--autonomous` (leave it out of the
  request), when the user asked for an unattended or headless run, or when you have no
  way to ask the user questions.

Then read `${CLAUDE_SKILL_DIR}/../loop-spec/SKILL.md` and follow it until the run ends.
If the command exits non-zero, its last line says what to do next.
