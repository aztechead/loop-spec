---
name: revise
description: "Addresses review feedback on an open pull request with loop-spec: turns each review comment into a checked criterion, fixes them on the PR's own branch, verifies, and pushes. Use when a person or bot left review comments on a PR to resolve. Not for new work (cycle) or a bug found outside review (debug)."
argument-hint: "[--autonomous|--supervised] <PR number or URL> [instruction]"
---

Start (or resume) a loop-spec run on the pull request:

    "${CLAUDE_SKILL_DIR}/../loop-spec/program/loop-spec" start --pr "{pr}" --request "{instruction}"

- `{pr}`: the PR number or URL.
- `{instruction}`: anything the user said beyond the PR reference; leave `--request`
  out when there is nothing.
- Add `--autonomous` if no one can answer questions during this run (a headless or
  unattended run, or arguments that start with `--autonomous`). Add `--supervised` instead
  when the arguments start with `--supervised`.
- When the instruction is long or holds quotes, backticks, or `$`, write it to a file
  and pass `--request-file <path>` instead of `--request`.

Then follow `${CLAUDE_SKILL_DIR}/../loop-spec/SKILL.md` until the run ends.
