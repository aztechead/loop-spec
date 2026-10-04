"""Thin wrappers over git and gh. Every subprocess call to either goes through here."""
import json
import subprocess
from pathlib import Path

from loop_spec.errors import LoopSpecError


def git(repo: Path, *args: str) -> subprocess.CompletedProcess:
    """Run git in `repo`; the caller reads the exit code."""
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, check=False)


def run_git(repo: Path, *args: str, repair: str = "") -> str:
    """Run git in `repo` and return stdout, or raise with git's own message."""
    proc = git(repo, *args)
    if proc.returncode != 0:
        raise LoopSpecError(f"git {' '.join(args)} failed: {proc.stderr.strip()}", repair or f"run it by hand in {repo} to see why")
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
    """The main worktree of the repository holding `start`, even from a subdirectory or linked worktree."""
    proc = git(start, "rev-parse", "--path-format=absolute", "--git-common-dir")
    if proc.returncode != 0:
        raise LoopSpecError(f"{start} is not inside a git repository", "run `git init` and commit once")
    return Path(proc.stdout.strip()).parent


def has_origin(repo: Path) -> bool:
    return git(repo, "remote", "get-url", "origin").returncode == 0


def default_branch(repo: Path) -> str:
    proc = git(repo, "symbolic-ref", "--short", "refs/remotes/origin/HEAD")
    if proc.returncode != 0 and has_origin(repo) and git(repo, "remote", "set-head", "origin", "--auto").returncode == 0:
        proc = git(repo, "symbolic-ref", "--short", "refs/remotes/origin/HEAD")
    if proc.returncode == 0:
        return proc.stdout.strip().removeprefix("origin/")
    current = run_git(repo, "rev-parse", "--abbrev-ref", "HEAD")
    if current == "HEAD":
        raise LoopSpecError("cannot tell the base branch: HEAD is detached and origin names none", "pass --base <branch>")
    return current


def fetch(repo: Path, *refspecs: str) -> subprocess.CompletedProcess:
    return git(repo, "fetch", "--no-tags", "origin", *refspecs)


def tracking(branch: str) -> str:
    return f"+refs/heads/{branch}:refs/remotes/origin/{branch}"


def resolve_base(repo: Path, branch: str) -> str:
    """The SHA a run starts from: origin's tip of `branch` when there is an origin, else the local branch."""
    if has_origin(repo) and fetch(repo, tracking(branch)).returncode == 0:
        return head(repo, f"refs/remotes/origin/{branch}")
    return head(repo, f"refs/heads/{branch}")


def checkout_pr_branch(repo: Path, dest: Path, branch: str, base: str) -> str:
    """Fetch an open PR's branch and its base in one call, fast-forward the local PR
    branch (git refuses if it has its own commits or is checked out elsewhere), and
    check it out at `dest`. Returns the base's SHA."""
    proc = fetch(repo, tracking(base), tracking(branch), f"refs/heads/{branch}:refs/heads/{branch}")
    if proc.returncode != 0:
        raise LoopSpecError(f"could not fetch the PR branch {branch}: {proc.stderr.strip()}",
                            f"if local {branch} has commits the PR lacks, push or drop them; if it is checked out, switch that checkout away")
    add_worktree(repo, dest, branch)
    return head(repo, f"refs/remotes/origin/{base}")


def is_ancestor(repo: Path, ancestor: str, descendant: str) -> bool:
    return git(repo, "merge-base", "--is-ancestor", ancestor, descendant).returncode == 0


def remote_tip(repo: Path, branch: str) -> str | None:
    """origin's `branch` as last fetched, or None when origin has no such branch."""
    proc = git(repo, "rev-parse", "--verify", "--quiet", f"refs/remotes/origin/{branch}")
    return proc.stdout.strip() if proc.returncode == 0 else None


def instruction_files(repo: Path, ref: str) -> list[str]:
    """The repository's instructions for agents and contributors at `ref`: every
    CLAUDE.md and AGENTS.md, and CONTRIBUTING* at the root."""
    paths = run_git(repo, "ls-tree", "-r", "--name-only", ref).splitlines()
    return [p for p in paths
            if Path(p).name in ("CLAUDE.md", "AGENTS.md") or ("/" not in p and p.startswith("CONTRIBUTING"))]


def branch_exists(repo: Path, name: str) -> bool:
    return git(repo, "rev-parse", "--verify", "--quiet", f"refs/heads/{name}").returncode == 0


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


def remove_worktree(repo: Path, dest: Path, *, force: bool = False) -> bool:
    """Remove a worktree. Without `force`, git keeps one with changes and this returns False."""
    return git(repo, "worktree", "remove", *(["--force"] if force else []), str(dest)).returncode == 0


def dirty(worktree: Path) -> list[str]:
    out = run_git(worktree, "status", "--porcelain")
    return [line[3:] for line in out.splitlines() if line]


def require_clean(worktree: Path, what: str, repair: str) -> None:
    changed = dirty(worktree)
    if changed:
        raise LoopSpecError(f"{what} has uncommitted changes: {', '.join(changed[:5])}", repair)


def head(worktree: Path, ref: str = "HEAD") -> str:
    return run_git(worktree, "rev-parse", ref)


def commits(repo: Path, rev_range: str) -> list[str]:
    out = run_git(repo, "rev-list", "--reverse", rev_range)
    return out.split() if out else []
