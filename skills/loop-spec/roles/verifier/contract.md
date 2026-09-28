One verdict per criterion. Evidence is the command you ran, the SHA, the exit status,
and the parsed failure identities. Every evidence command must run from the root of a
clean checkout of the head with nothing but the repository's own files: use the plan
task's verify command, or the same interpreter with an absolute path (the venv's python,
never bare `python`); the program re-runs your command itself and rejects a criterion
whose re-run differs. Report the exact command you ran. `blocked` only for a cause you
actually observed, and only after trying an offline stand-in (say what you tried). Never
`pass` on inference.
