"""Git, workspace, worktree, and PR-adoption facts for a project root.

Use `detect_workspace`/`init_in_place` to resolve what repo(s) a run operates on,
the `head_sha`/`commits_between`/`add_worktree`/... helpers for the git mechanics
every phase needs, `find_pr_reference`/`adopt_pr` to decide whether a request names
an existing PR to resume instead of a fresh branch, and `check_credentials` for the
DELIVER precondition. Every function here reports a fact or fails safe; none of them
choose a phase route (that is `postconditions.py`/`controller.py`).
"""
import fnmatch
import json
import re
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

from loop_spec.errors import LoopSpecError


def _git(repo: Path, *args: str) -> subprocess.CompletedProcess:
    # The only subprocess.run call site for git. A probe (is a branch present? is
    # one sha an ancestor of another?) reads a non-zero exit as a plain "no", so it
    # calls this directly; run_git wraps it with the raise for operations that are
    # only ever meant to succeed.
    return subprocess.run(
        ["git", "-C", str(repo), *args], capture_output=True, text=True, check=False
    )


def run_git(repo: Path, *args: str) -> str:
    proc = _git(repo, *args)
    if proc.returncode != 0:
        raise LoopSpecError(proc.stderr.strip() or f"git {' '.join(args)} failed", repair=f"run the command by hand in {repo}")
    return proc.stdout


# Package-manager lockfiles: generated, often most of a diff's bytes (uv.lock was 90%
# of every review prompt's diff in the 7.0.3 timing runs), and never reviewed line by
# line. A review diff names them by --stat instead of carrying their content.
LOCKFILES = ("uv.lock", "poetry.lock", "Pipfile.lock", "pdm.lock", "package-lock.json", "yarn.lock",
             "pnpm-lock.yaml", "bun.lockb", "Cargo.lock", "go.sum", "Gemfile.lock", "composer.lock")


def review_diff(repo: Path, rev_range: str) -> str:
    """`git diff <rev_range>` for a prompt: lockfile content left out, each changed
    lockfile named in a trailing `--stat` block so a reviewer still sees it moved."""
    excludes = [f":(exclude,glob)**/{name}" for name in LOCKFILES]
    diff = run_git(repo, "diff", rev_range, "--", ".", *excludes)
    stat = run_git(repo, "diff", "--stat", rev_range, "--", *[f":(glob)**/{name}" for name in LOCKFILES])
    if stat.strip():
        diff += "\n# lockfile changes (content omitted):\n" + stat
    return diff


def exclude_path(repo_path: Path, relative: str) -> None:
    """Add `relative` to this repo's own, never-committed exclude file, once.
    `--git-path` (not a hardcoded `.git/info/exclude`) resolves to the shared
    common dir from a linked worktree too, not a private per-worktree path that
    does not exist there. A non-repo `repo_path` just does nothing."""
    proc = _git(repo_path, "rev-parse", "--git-path", "info/exclude")
    if proc.returncode != 0:
        return
    raw = proc.stdout.strip()
    exclude_file = Path(raw) if Path(raw).is_absolute() else Path(repo_path) / raw
    exclude_file.parent.mkdir(parents=True, exist_ok=True)
    existing = exclude_file.read_text().splitlines() if exclude_file.is_file() else []
    if relative in existing:
        return
    with exclude_file.open("a") as f:
        f.write(relative + "\n")


def run_gh(repo: Path, *args: str) -> tuple[int, str, str]:
    try:
        proc = subprocess.run(["gh", *args], cwd=repo, capture_output=True, text=True, check=False)
    except OSError as exc:
        # gh missing from PATH is data for the caller (adopt_pr, check_credentials),
        # not a program error, so this never raises.
        return 127, "", str(exc)
    return proc.returncode, proc.stdout, proc.stderr


@dataclass
class Repo:
    name: str
    path: Path
    base_sha: str | None = None
    feature_branch: str | None = None
    default_branch: str | None = None


@dataclass
class Workspace:
    mode: Literal["single", "workspace", "none"]
    root: Path
    source: Literal["config", "discovered", "git", "none"]
    repos: list[Repo]


def detect_workspace(root: Path) -> Workspace:
    root = Path(root).resolve()
    config = root / ".loop-spec" / "workspace.json"
    if config.is_file():
        return _detect_config_workspace(root, config)

    if _git(root, "rev-parse", "--is-inside-work-tree").returncode == 0:
        toplevel = Path(run_git(root, "rev-parse", "--show-toplevel").strip())
        return Workspace(mode="single", root=toplevel, source="git", repos=[Repo(name=toplevel.name, path=toplevel)])

    discovered = [
        Repo(name=child.name, path=child)
        for child in sorted(root.iterdir())
        if not child.name.startswith(".") and child.is_dir() and (child / ".git").exists()
    ]
    if discovered:
        return Workspace(mode="workspace", root=root, source="discovered", repos=sorted(discovered, key=lambda r: r.name))

    return Workspace(mode="none", root=root, source="none", repos=[])


def _detect_config_workspace(root: Path, config: Path) -> Workspace:
    try:
        data = json.loads(config.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise LoopSpecError(f"workspace.json: invalid JSON in {config}", repair=f"fix the JSON in {config}") from exc

    raw_repos = data.get("repos") if isinstance(data, dict) else None
    if not isinstance(raw_repos, list):
        raise LoopSpecError(f"workspace.json: could not read .repos array in {config}", repair=f"add a .repos array of {{name, path}} to {config}")

    entries: list[tuple[str, str]] = []
    for item in raw_repos:
        if not isinstance(item, dict) or "name" not in item or "path" not in item:
            raise LoopSpecError(f"workspace.json: could not read .repos array in {config}", repair=f"add a .repos array of {{name, path}} to {config}")
        entries.append((str(item["name"]), str(item["path"])))

    if not entries:
        raise LoopSpecError(f"workspace.json: .repos is empty in {config}", repair=f"add at least one repo to {config}")

    names = [name for name, _ in entries]
    duplicates = sorted({name for name in names if names.count(name) > 1})
    if duplicates:
        raise LoopSpecError(f"workspace.json: duplicate repo name(s): {' '.join(duplicates)}", repair=f"give each repo a unique name in {config}")

    workspace_abs = root.resolve()
    repos: list[Repo] = []
    for name, path in entries:
        raw_path = Path(path)
        abs_path = raw_path if raw_path.is_absolute() else root / raw_path

        if not abs_path.is_dir():
            raise LoopSpecError(
                f"workspace.json: repo '{name}' invalid: path '{path}' does not exist or is not a directory",
                repair=f"fix the path for '{name}' in {config}",
            )
        if _git(abs_path, "rev-parse", "--is-inside-work-tree").returncode != 0:
            raise LoopSpecError(
                f"workspace.json: repo '{name}' invalid: path '{path}' is not inside a git work tree",
                repair=f"fix the path for '{name}' in {config}",
            )

        resolved_path = abs_path.resolve()
        repo_top = Path(run_git(abs_path, "rev-parse", "--show-toplevel").strip()).resolve()
        if resolved_path == workspace_abs:
            raise LoopSpecError(
                f"workspace.json: repo '{name}' invalid: workspace root cannot also be a workspace target; use single-repo mode for the root",
                repair=f"remove '{name}' from {config}, or drop workspace.json and use single-repo mode",
            )
        if resolved_path != repo_top:
            raise LoopSpecError(
                f"workspace.json: repo '{name}' invalid: path '{path}' must name the git repository root",
                repair=f"point '{name}' at {repo_top} in {config}",
            )
        repos.append(Repo(name=name, path=resolved_path))

    return Workspace(mode="workspace", root=workspace_abs, source="config", repos=repos)


def init_in_place(root: Path, default_branch: str = "main") -> Repo:
    root = Path(root)
    workspace = detect_workspace(root)
    if workspace.mode == "single":
        raise LoopSpecError("already a git repository; init-in-place is for an empty directory", repair=f"skip init-in-place; {root} is already a git repository")
    if workspace.mode == "workspace":
        raise LoopSpecError("no multi-repo init-in-place", repair="init each repo in the workspace individually, or point --project-root at a single repo")

    run_git(root, "init", "-b", default_branch)
    run_git(root, "commit", "--allow-empty", "-m", "chore: loop-spec init")
    resolved = root.resolve()
    return Repo(name=resolved.name, path=resolved, default_branch=default_branch)


def head_sha(repo: Path, ref: str = "HEAD") -> str:
    return run_git(repo, "rev-parse", ref).strip()


def default_branch(repo: Path) -> str:
    proc = _git(repo, "symbolic-ref", "refs/remotes/origin/HEAD")
    if proc.returncode == 0:
        return proc.stdout.strip().rsplit("/", 1)[-1]
    return run_git(repo, "rev-parse", "--abbrev-ref", "HEAD").strip()


def is_ancestor(repo: Path, ancestor_sha: str, descendant_sha: str) -> bool:
    return _git(repo, "merge-base", "--is-ancestor", ancestor_sha, descendant_sha).returncode == 0


def commits_between(repo: Path, base_sha: str, head_sha: str) -> list[str]:
    # --no-merges: a merge commit the program records while integrating two
    # same-wave siblings (execute.py's --no-ff fallback) is nobody's task
    # commit; E4/E5/the adopted range all enumerate commits through this same
    # function, so leaving merges out here keeps both sides of every
    # comparison (a task's own recorded commits vs. what is actually on the
    # branch) agreeing regardless of which path integrated a task.
    out = run_git(repo, "rev-list", "--reverse", "--no-merges", f"{base_sha}..{head_sha}")
    return [line for line in out.splitlines() if line]


def branch_sha(repo: Path, branch: str) -> str | None:
    proc = _git(repo, "rev-parse", "--verify", branch)
    return proc.stdout.strip() if proc.returncode == 0 else None


def create_feature_branch(repo: Path, name: str, at_sha: str) -> None:
    existing = branch_sha(repo, name)
    if existing is not None:
        if existing != at_sha:
            raise LoopSpecError(
                f"branch '{name}' already exists at a different commit",
                repair=f"delete branch '{name}' in {repo} or reuse the commit it already points at",
            )
        return
    run_git(repo, "branch", name, at_sha)


def add_worktree(repo: Path, dest: Path, *, branch: str | None = None, detach_at: str | None = None) -> Path:
    if (branch is None) == (detach_at is None):
        raise LoopSpecError("add_worktree requires exactly one of branch or detach_at", repair="pass exactly one of branch= or detach_at=")
    dest = Path(dest)
    if dest.exists():
        raise LoopSpecError(f"worktree destination already exists: {dest}", repair=f"remove {dest} or choose a different destination")

    if branch is not None:
        run_git(repo, "worktree", "add", str(dest), branch)
    else:
        run_git(repo, "worktree", "add", "--detach", str(dest), detach_at)
    return dest


def remove_worktree(repo: Path, dest: Path, *, force: bool = False) -> None:
    args = ["worktree", "remove"]
    if force:
        args.append("--force")
    args.append(str(dest))
    run_git(repo, *args)


def remove_worktrees(repo: Path, paths_root: Path, *, protected: set[Path] = frozenset()) -> tuple[list[str], list[dict]]:
    """Remove every worktree of `repo` under `paths_root` (a run's own feature
    dir) and prune. LF-39: a terminal run that keeps its worktrees leaves its
    feature branch checked out somewhere, so a LATER run's `git worktree add` of
    that same branch is refused as already in use. Never raises, on the listing
    itself (a repo that no longer exists or was never a real checkout, a test
    fixture's own stand-in) or on one worktree it cannot remove -- a terminal
    run's result must still get written either way; this is best-effort tidying,
    never a precondition for it.

    R5: a run's terminal result does not mean every worker process touching one
    of its worktrees has also terminated. `protected` names paths the caller
    already knows are unsafe (an open step's cwd, a quarantined one, both
    derived from state); this function additionally skips -- by actually
    looking, since the caller has no way to know without running git itself --
    any worktree that still has uncommitted changes. Returns (removed, skipped),
    the second a list of `{"path", "reason"}` for the caller's own cleanupBacklog."""
    paths_root = Path(paths_root).resolve()
    removed: list[str] = []
    skipped: list[dict] = []
    try:
        listing = run_git(repo, "worktree", "list", "--porcelain")
    except LoopSpecError:
        return removed, skipped
    for line in listing.splitlines():
        if not line.startswith("worktree "):
            continue
        wt_path = Path(line[len("worktree "):]).resolve()
        try:
            wt_path.relative_to(paths_root)
        except ValueError:
            continue
        if wt_path in protected:
            skipped.append({"path": str(wt_path), "reason": "open step or quarantined"})
            continue
        try:
            dirty = not is_clean(wt_path)
        except LoopSpecError:
            dirty = False  # can't tell (the worktree may already be half-gone); don't block on it
        if dirty:
            skipped.append({"path": str(wt_path), "reason": "uncommitted changes"})
            continue
        if _git(repo, "worktree", "remove", "--force", str(wt_path)).returncode == 0:
            removed.append(str(wt_path))
    _git(repo, "worktree", "prune")
    return removed, skipped


def clean_checkout(repo: Path, sha: str, dest: Path) -> Path:
    dest = Path(dest)
    if dest.exists():
        raise LoopSpecError(f"checkout destination already exists: {dest}", repair=f"remove {dest} or choose a different destination")
    run_git(repo, "worktree", "add", "--detach", str(dest), sha)
    return dest


def is_clean(worktree: Path) -> bool:
    return run_git(worktree, "status", "--porcelain").strip() == ""


def files_added_by(repo: Path, base_sha: str, head_sha: str) -> list[str]:
    out = run_git(repo, "log", "--diff-filter=A", "--name-only", "--format=", f"{base_sha}..{head_sha}")
    seen: list[str] = []
    for line in out.splitlines():
        line = line.strip()
        if line and line not in seen:
            seen.append(line)
    return seen


def remote_head(repo: Path, remote: str, branch: str) -> str | None:
    proc = _git(repo, "ls-remote", remote, f"refs/heads/{branch}")
    if proc.returncode != 0 or not proc.stdout.strip():
        return None
    return proc.stdout.split()[0]


def _nul_paths(text: str) -> list[str]:
    return [p for p in text.lstrip("\n").split("\0") if p]


def remote_extension(repo: Path, branch: str, verified: str, base: str, globs: list[str]) -> dict:
    """What origin's `branch` holds relative to the verified SHA (7.1.0). `state` is
    `absent`, `equal`, `diverged` (the remote head does not descend from `verified`),
    `extension` (it does) or `error` (the fetch failed). For an extension, `commits` are
    every commit in verified..head with every path each one touches in any parent's
    diff (renames as both sides), and `refused` names each path outside `globs` or
    changed by the verified change itself (base..verified, final tree)."""
    fetch = _git(repo, "fetch", "--no-tags", "origin", f"refs/heads/{branch}")
    if fetch.returncode != 0:
        if "couldn't find remote ref" in fetch.stderr:
            return {"state": "absent"}
        return {"state": "error", "why": fetch.stderr.strip() or "git fetch failed"}
    head = run_git(repo, "rev-parse", "FETCH_HEAD").strip()
    if head == verified:
        return {"state": "equal", "head": head}
    if not is_ancestor(repo, verified, head):
        return {"state": "diverged", "head": head}
    protected = set(_nul_paths(run_git(repo, "diff", "--name-only", "-z", "--no-renames", base, verified)))
    log = run_git(repo, "log", "-z", "--no-renames", "-m", "--name-only", "--format=%x01%H%x02%s", f"{verified}..{head}")
    commits: dict[str, dict] = {}
    for chunk in log.split("\x01"):
        if not chunk:
            continue
        header, _, rest = chunk.partition("\0")
        sha, _, subject = header.partition("\x02")
        entry = commits.setdefault(sha, {"sha": sha, "subject": subject, "paths": []})
        for path in _nul_paths(rest):
            if path not in entry["paths"]:
                entry["paths"].append(path)
    paths = sorted({p for c in commits.values() for p in c["paths"]})
    refused = [p for p in paths if p in protected or not any(fnmatch.fnmatchcase(p, g) for g in globs)]
    return {"state": "extension", "head": head, "commits": list(commits.values()), "paths": paths, "refused": refused}


def _worktree_holding(repo: Path, branch: str) -> Path | None:
    """The worktree that has `branch` checked out, if any (the main one included)."""
    current = None
    for line in run_git(repo, "worktree", "list", "--porcelain").splitlines():
        if line.startswith("worktree "):
            current = Path(line[len("worktree "):])
        elif line == f"branch refs/heads/{branch}":
            return current
    return None


def fetch_pr_head(repo: Path, head_ref: str, base_ref: str, head_sha: str, *, managed_root: Path) -> None:
    """Make an adopted PR's head usable from `repo`, including a fresh `--depth=1
    --single-branch` clone: fetch both branches into explicit remote-tracking refs
    (unshallowing a shallow clone so merge-base can see the fork point), then point a
    local `head_ref` branch at `head_sha`. Refuses instead of moving a branch someone
    has checked out or has commits on. `managed_root` is the state home: a worktree
    under it is a stale run's, safe to remove."""
    shallow = run_git(repo, "rev-parse", "--is-shallow-repository").strip() == "true"
    # ponytail: a full unshallow; a --deepen loop if a huge repository makes it slow.
    fetch = _git(repo, "fetch", "--no-tags", *(["--unshallow"] if shallow else []), "origin",
                 f"+refs/heads/{base_ref}:refs/remotes/origin/{base_ref}",
                 f"+refs/heads/{head_ref}:refs/remotes/origin/{head_ref}")
    if fetch.returncode != 0:
        raise LoopSpecError(f"could not fetch the PR's branches {head_ref} and {base_ref}: {fetch.stderr.strip()}",
                             repair="check the origin remote and git credentials, then re-run")
    fetched = run_git(repo, "rev-parse", f"refs/remotes/origin/{head_ref}").strip()
    if fetched != head_sha:
        raise LoopSpecError(f"the PR head {head_ref} moved during adoption: gh reported {head_sha[:12]}, origin has {fetched[:12]}",
                             repair="re-run the entry to adopt the new head")
    holder = _worktree_holding(repo, head_ref)
    if holder is not None:
        managed = Path(managed_root).resolve() in holder.resolve().parents
        raise LoopSpecError(
            f"branch {head_ref} is checked out in {holder}; the run needs its own worktree of it",
            repair=f"git worktree remove {holder}" if managed else f"git -C {holder} checkout --detach",
        )
    local = branch_sha(repo, f"refs/heads/{head_ref}")
    if local is None:
        run_git(repo, "branch", head_ref, head_sha)
    elif local != head_sha:
        if is_ancestor(repo, local, head_sha):
            raise LoopSpecError(f"local branch {head_ref} is at {local[:12]}, behind the PR head {head_sha[:12]}",
                                 repair=f"git -C {repo} branch -f {head_ref} origin/{head_ref}")
        raise LoopSpecError(f"local branch {head_ref} ({local[:12]}) has commits the PR head {head_sha[:12]} lacks",
                             repair=f"push {head_ref} to the PR or rename it, then re-run")


def origin_url(repo: Path) -> str | None:
    proc = _git(repo, "remote", "get-url", "origin")
    if proc.returncode != 0:
        return None
    return proc.stdout.strip() or None


@dataclass
class PrAdoption:
    adopt: bool
    number: int | None
    url: str | None
    branch: str | None
    base_branch: str | None
    head_sha: str | None
    reason: str


_PR_URL = re.compile(r"https://github\.com/[^\s]+?/pull/\d+\S*")
_PR_REF_PATTERNS = (re.compile(r"#(\d+)"), re.compile(r"\bPR\s+(\d+)\b", re.IGNORECASE), re.compile(r"\bpull/(\d+)\b", re.IGNORECASE))


def find_pr_reference(text: str) -> int | str | None:
    url_match = _PR_URL.search(text)
    if url_match:
        return url_match.group(0)
    for pattern in _PR_REF_PATTERNS:
        match = pattern.search(text)
        if match:
            return int(match.group(1))
    return None


def _no_adopt(reason: str) -> PrAdoption:
    return PrAdoption(adopt=False, number=None, url=None, branch=None, base_branch=None, head_sha=None, reason=reason)


def adopt_pr(repo: Path, ref: int | str) -> PrAdoption:
    if shutil.which("gh") is None:
        return _no_adopt("gh is not installed")

    code, out, err = run_gh(
        repo, "pr", "view", str(ref), "--json", "number,url,headRefName,baseRefName,state,isCrossRepository,headRefOid"
    )
    if code != 0:
        return _no_adopt(err.strip() or f"gh pr view failed (rc={code})")

    try:
        data = json.loads(out)
    except json.JSONDecodeError:
        return _no_adopt("gh pr view returned malformed JSON")

    state = data.get("state")
    if state != "OPEN":
        return _no_adopt(f"PR state is {state or 'unknown'}, not OPEN")
    if data.get("isCrossRepository"):
        return _no_adopt("PR head is a fork")

    number, url, branch, base = data.get("number"), data.get("url"), data.get("headRefName"), data.get("baseRefName")
    return PrAdoption(
        adopt=True, number=number, url=url, branch=branch, base_branch=base,
        head_sha=data.get("headRefOid"), reason=f"named open PR #{number} on {branch}",
    )


@dataclass
class CredentialStatus:
    git_ok: bool
    gh_ok: bool
    checked: list[str]
    failed_command: str | None
    repair: str | None


def check_credentials(repo: Path, remote: str = "origin") -> CredentialStatus:
    checked: list[str] = [f"git ls-remote --exit-code {remote} HEAD", "gh auth status"]

    git_ok = _git(repo, "ls-remote", "--exit-code", remote, "HEAD").returncode == 0
    failed_command: str | None = None
    repair: str | None = None
    if not git_ok:
        failed_command = f"git ls-remote {remote} HEAD"
        repair = f"run: git ls-remote {remote} and fix the credential helper"

    gh_code, _, _ = run_gh(repo, "auth", "status")
    gh_ok = gh_code == 0
    if not gh_ok and failed_command is None:
        # `gh auth refresh` is interactive, so there is no non-interactive refresh to
        # attempt for gh: the auth-status check above IS the attempt; the repair is
        # the interactive login the operator has to run themselves.
        failed_command = "gh auth status"
        repair = "run: gh auth login"

    return CredentialStatus(git_ok=git_ok, gh_ok=gh_ok, checked=checked, failed_command=failed_command, repair=repair)
