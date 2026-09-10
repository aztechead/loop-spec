#!/usr/bin/env bash
# Preserve feature documents outside the branch with recoverable publication.
# Usage: artifact-sink.sh store|recover <feature_dir> <repo_root>
#
# A store or recover that finds Git's index already locked (its owning process
# died mid-write) refuses -- exit 1, "Git index is locked" -- rather than delete
# a lock it does not own. Confirm no Git process still owns it, then clear the
# stale lock yourself (`git`'s own guidance): rm <repo_root>/.git/index.lock (or
# the path `git rev-parse --git-path index.lock` names, for a worktree or an
# alternate GIT_DIR), and retry.
set -euo pipefail
exec python3 "$(dirname "${BASH_SOURCE[0]}")/artifact_sink.py" "$@"
