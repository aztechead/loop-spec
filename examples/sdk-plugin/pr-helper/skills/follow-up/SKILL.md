---
name: follow-up
description: Posts one status comment on each pull request loop-spec delivered. For deliver.after, which passes the PR URLs as arguments.
---

The arguments are pull-request URLs: $ARGUMENTS

For each URL:

1. Run `gh pr view <url> --json number,headRefOid,reviews,comments`.
2. Post exactly one comment:
   `gh pr comment <url> --body "pr-helper follow-up: head <first 7 characters of headRefOid>, <number of reviews plus comments> review item(s) on this PR."`

Do not push, edit files, or reply to or resolve review threads. Report each comment's
URL, which `gh pr comment` prints.
