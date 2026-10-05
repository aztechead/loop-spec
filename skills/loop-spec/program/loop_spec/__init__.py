"""loop-spec 8.x: a small helper that keeps a run's state and task graph on disk.

The method lives in the skills; this package only does what a model should not have
to re-derive each time: where a run's files are, which tasks are ready, git
worktrees and merges, running checks, and opening the pull request.
"""

VERSION = "8.1.0"
