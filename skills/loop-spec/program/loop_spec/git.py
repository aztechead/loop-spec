"""Thin wrappers over git and gh. Every subprocess call to either goes through here."""
import json
import subprocess
from pathlib import Path

from loop_spec.errors import LoopSpecError


def git(repo: Path, *args: str) -> subprocess.CompletedProcess:
    """Run git in `repo`; the caller reads the exit code."""
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=False)


def run_git(repo: Path, *args: str) -> str:
    """Run git in `repo` and return stdout, or raise with git's own message."""
    proc = git(repo, *args)
    if proc.returncode != 0:
        raise LoopSpecError(f"git {' '.join(args)} failed: {proc.stderr.strip()}", f"run it by hand in {repo} to see why")
    return proc.stdout.strip()


def gh(repo: Path, *args: str) -> tuple[int, str, str]:
    try:
        proc = subprocess.run(["gh", *args], cwd=repo, capture_output=True, text=True, check=False)
    except OSError as exc:
        return 127, "", f"gh is not available: {exc}"
    return proc.returncode, proc.stdout, proc.stderr


def gh_json(repo: Path, *args: str):
    code, out, err = gh(repo, *args)
    if code != 0:
        raise LoopSpecError(f"gh {' '.join(args)} failed: {err.strip()}", "check `gh auth status` and the origin remote")
    return json.loads(out)


def project_root(start: Path) -> Path:
    """The main worktree of the repository holding `start`, even from a linked worktree."""
    proc = git(start, "rev-parse", "--path-format=absolute", "--git-common-dir")
    if proc.returncode != 0:
        raise LoopSpecError(f"{start} is not inside a git repository", "run `git init` and commit once, or pass --project-root")
    return Path(proc.stdout.strip()).parent


def has_origin(repo: Path) -> bool:
    return git(repo, "remote", "get-url", "origin").returncode == 0


def default_branch(repo: Path) -> str:
    proc = git(repo, "symbolic-ref", "--short", "refs/remotes/origin/HEAD")
    if proc.returncode == 0:
        return proc.stdout.strip().removeprefix("origin/")
    proc = git(repo, "ls-remote", "--symref", "origin", "HEAD")
    for line in proc.stdout.splitlines() if proc.returncode == 0 else []:
        if line.startswith("ref:"):
            return line.split("\t", 1)[0].removeprefix("ref:").strip().removeprefix("refs/heads/")
    current = run_git(repo, "rev-parse", "--abbrev-ref", "HEAD")
    if current == "HEAD":
        raise LoopSpecError("cannot tell the base branch: HEAD is detached and origin names none", "pass --base <branch>")
    return current


def resolve_base(repo: Path, branch: str) -> str:
    """The SHA a run starts from: origin's tip of `branch` when there is an origin, else the local branch."""
    if has_origin(repo):
        proc = git(repo, "fetch", "--no-tags", "origin", f"+refs/heads/{branch}:refs/remotes/origin/{branch}")
        if proc.returncode == 0:
            return run_git(repo, "rev-parse", f"refs/remotes/origin/{branch}")
    return run_git(repo, "rev-parse", f"refs/heads/{branch}")


def branch_exists(repo: Path, name: str) -> bool:
    return git(repo, "rev-parse", "--verify", "--quiet", f"refs/heads/{name}").returncode == 0


def free_branch(repo: Path, name: str) -> str:
    """`name`, or `name-2`, `name-3`, ... when a local branch already has it."""
    candidate, n = name, 1
    while branch_exists(repo, candidate):
        n += 1
        candidate = f"{name}-{n}"
    return candidate


def exclude(repo: Path, pattern: str) -> None:
    """Keep `pattern` out of `git status` through the repository's own, never-committed exclude file."""
    raw = run_git(repo, "rev-parse", "--git-path", "info/exclude")
    path = Path(raw) if Path(raw).is_absolute() else repo / raw
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = path.read_text().splitlines() if path.is_file() else []
    if pattern not in lines:
        with path.open("a") as f:
            f.write(pattern + "\n")


def add_worktree(repo: Path, dest: Path, ref: str, *, new_branch: str | None = None, detach: bool = False) -> None:
    """Check `ref` out at `dest`: on a new branch, detached, or (neither) as the existing branch `ref`."""
    args = ["worktree", "add", "--quiet"]
    if new_branch:
        args += ["-b", new_branch]
    elif detach:
        args.append("--detach")
    run_git(repo, *args, str(dest), ref)


def remove_worktree(repo: Path, dest: Path) -> bool:
    """Remove a clean worktree; a dirty one is kept and False is returned."""
    if not dest.exists():
        git(repo, "worktree", "prune")
        return True
    if dirty(dest):
        return False
    run_git(repo, "worktree", "remove", "--force", str(dest))
    return True


def dirty(worktree: Path) -> list[str]:
    out = run_git(worktree, "status", "--porcelain", "--untracked-files=normal")
    return [line[3:] for line in out.splitlines() if line]


def head(worktree: Path, ref: str = "HEAD") -> str:
    return run_git(worktree, "rev-parse", ref)


def commits(repo: Path, rev_range: str) -> list[str]:
    out = run_git(repo, "rev-list", "--reverse", rev_range)
    return out.split() if out else []
