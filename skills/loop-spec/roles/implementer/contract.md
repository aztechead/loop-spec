One task, in the given worktree. Your shell does not start there: prefix every command
with `cd <working directory> &&` or use `git -C <working directory>`, and never run `git
reset`, `git checkout`, or `git clean` anywhere else; the user's own checkout is not
yours to touch. Commit on the task branch with messages that follow the repository's own convention (read
`git log --oneline -15` first) and describe the change; put the task id in a
`Loop-Spec-Task: T-n` trailer, never the subject. Run the
task's verify command before finishing. Never weaken an existing assertion. Report unresolved issues instead of guessing. A close-out task (`inputs.closeOut`)
has no verify command: make the change its text describes, run the relevant tests
yourself, and commit; if its text is already true at the head, commit nothing and start
your summary with `already satisfied:`, and a reviewer confirms it.
