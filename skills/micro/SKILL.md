---
name: micro
description: "Makes a small, well-defined code change (a one-file fix, a rename, a tiny tweak) and lands it as a verified PR in one short loop-spec pass. Use when the user asks for a small change to their code, such as changing a message or a default, renaming something, or fixing a one-file bug, even if they never mention loop-spec or a PR. Not for a feature that needs planning (cycle) or a bug that needs investigation (debug)."
argument-hint: "[--autonomous|--supervised] <request>"
---

Start (or resume) a loop-spec run from the repository. For a change across several
repositories cloned side by side in a directory that is not itself a repository, start
from that directory; when it has no `.loop-spec/workspace.json`, first write one listing
each clone the change spans: `{"repos": [{"name": "api", "path": "api"}, {"name": "web", "path": "web"}]}`.

    "${CLAUDE_SKILL_DIR}/../loop-spec/program/loop-spec" start --kind micro --request "{request}"

- `{request}`: the user's request.
- Add `--branch NAME` and `--title "..."` when the user names the branch or the PR
  title for this change.
- Add `--autonomous` if no one can answer questions during this run (a headless or
  unattended run, or arguments that start with `--autonomous`). Add `--supervised` instead
  when the arguments start with `--supervised`.
- When the request is long or holds quotes, backticks, or `$`, write it to a file and
  pass `--request-file <path>` instead of `--request`.

Then follow `${CLAUDE_SKILL_DIR}/../loop-spec/SKILL.md` until the run ends.
