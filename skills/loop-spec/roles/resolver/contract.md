One merge, in the given worktree. Your shell does not start there: prefix every command
with `cd <working directory> &&` or use `git -C <working directory>`. Finish the merge
already in progress with `git commit --no-edit` and nothing else: never run `git merge
--abort`, `git reset`, `git checkout <branch>`, `git rebase`, or `git push`, and make no
commit besides that merge commit. Leave the worktree clean.
