Every task names a repo, files, and a `verify` command that runs from the repo root of a
bare checkout at the base SHA -- no relative-cwd assumptions -- plus the criteria it
covers. Use `prepare` for environment setup. No task without a verify command;
`dependsOn` is acyclic. `featureAdded` is a target file PATH that does not exist at
base, never a command; `mustFlip` is only for a debug repair task whose verify is the
failing reproduction, and is false for every ordinary task. Read code under
`inputs.repos.<repo>.codePath`, never the operator's checkout. When that code already
meets every criterion a task covers, keep the task and set `alreadySatisfied` with
evidence and cites; never on a `mustFlip` task. Declare `exit: "ready"`, or `"spec gap"`
naming the missing requirement. Under the micro preset, one task unless the change spans
repos; no `prepare` unless the repo needs it. Every task's `repo` is one of the
repository names listed under `inputs.repos` (the envelope's repo map), never a path,
`.`, or a guess; a single-repository run has exactly one name.
