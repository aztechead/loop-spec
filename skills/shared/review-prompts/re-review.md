# Scoped re-review

Use after a fix round. This is not a fresh task review: a previous review
produced findings; the implementer attempted to fix them. Verdict each
finding against the fix diff only.

## Inputs (paths, not pasted diffs)

- The task brief file
- The implementer report file (fix reports appended)
- The review package for `FIX_BASE..HEAD` from `lib/dispatch-files.sh package`
  (`FIX_BASE` is the HEAD the previous review saw, never `HEAD~1`)

## Job

1. Read the package once. Do not re-run git for that range if the file exists.
2. For each prior finding: addressed, still open, or plan-mandated.
3. Inspect the fix diff for new breakage.
4. Do not re-read the whole task. Do not spawn a subagent.
5. Return JSON:
   `{ "verdict": "pass"|"rework"|"block", "findings": [...], "unverified": [] }`
