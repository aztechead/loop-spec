"""State-home and per-feature path resolution.

Use `state_home` to find where durable run state lives (explicit flag beats
LOOP_SPEC_HOME beats the ~/.loop-spec default), `repo_id` to namespace state per
repository, `feature_dir` for one feature's directory under that namespace,
`FeaturePaths` for every file a single feature's run touches inside it, and
`ensure_results_dir` before any model-written result path under `results_dir`.
"""
import os
import re
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

from loop_spec import repo as repo_module
from loop_spec.ids import digest_bytes


def state_home(explicit: str | None = None) -> Path:
    # A stub passes the host's data-directory placeholder verbatim; on a host that does
    # not substitute it (a skills install, a headless run without the plugin) the value
    # still contains "${", and a literal directory of that name would scatter state.
    if explicit and "${" not in explicit:
        home = Path(explicit)
    else:
        env = os.environ.get("LOOP_SPEC_HOME")
        home = Path(env) if env else Path.home() / ".loop-spec"
    home.mkdir(parents=True, exist_ok=True)
    return home


def _git_out(project_root: Path, *args: str) -> str | None:
    try:
        result = subprocess.run(["git", *args], cwd=project_root, capture_output=True, text=True, check=True)
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
    return result.stdout.strip()


def repo_id(project_root: Path) -> str:
    project_root = Path(project_root)
    # Identity comes from the repository's first root commit, never from a remote URL:
    # a live run that added `origin` mid-cycle changed its state key and lost its run
    # (finding LF-04). A root commit is stable across remotes, renames, and clones. A
    # directory without a git history (a workspace root, an empty dir before
    # init-in-place) keys on its realpath.
    pinned = _git_out(project_root, "config", "--local", "--get", "loop-spec.repoId")
    if pinned:
        return pinned
    roots = (_git_out(project_root, "rev-list", "--max-parents=0", "HEAD") or "").split()
    canonical = sorted(roots)[0] if roots else str(project_root.resolve())
    full = digest_bytes(canonical.encode())  # "sha256:<64 hex>"
    rid = full.split(":", 1)[1][:16]
    if roots and _git_out(project_root, "rev-parse", "--is-shallow-repository") == "true":
        # LF-74: a shallow clone's "root" is its graft, and adopting a PR unshallows the
        # clone mid-run, which would move every later call to another state key. Pin
        # the first answer in the clone's own config so it outlives the unshallow.
        _git_out(project_root, "config", "--local", "loop-spec.repoId", rid)
    return rid


@dataclass
class FeaturePaths:
    """Every path one feature's run touches, derived from its root directory."""

    root: Path
    # LF-27: a live run's model, under Claude Code's default permission mode,
    # cannot write anywhere under ~/.claude/... (the state home lives there) even
    # with the Write tool allow-listed -- optional so a caller with no project
    # root (a scan of past slugs, most existing tests) still gets a valid,
    # writable results_dir, falling back to under root itself.
    project_root: Path | None = None
    state_json: Path = field(init=False)
    events_jsonl: Path = field(init=False)
    attempts_dir: Path = field(init=False)
    steps_dir: Path = field(init=False)
    worktrees_dir: Path = field(init=False)
    checkouts_dir: Path = field(init=False)
    result_json: Path = field(init=False)
    last_result_json: Path = field(init=False)
    results_dir: Path = field(init=False)

    def __post_init__(self) -> None:
        self.root = Path(self.root)
        self.project_root = Path(self.project_root) if self.project_root is not None else self.root
        self.state_json = self.root / "state.json"
        self.events_jsonl = self.root / "events.jsonl"
        self.attempts_dir = self.root / "attempts"
        self.steps_dir = self.root / "steps"
        self.worktrees_dir = self.root / "worktrees"
        self.checkouts_dir = self.root / "checkouts"
        self.result_json = self.root / "result.json"
        self.last_result_json = self.root.parent / "last-result.json"
        # root's own last path component IS the slug (feature_dir returns
        # home/repo_id/slug) -- no separate slug field needed to namespace this.
        self.results_dir = self.project_root / ".loop-spec" / "results" / self.root.name

    def feature_worktree(self, repo: str) -> Path:
        """EXECUTE's checkout of `repo`'s feature branch, where its integrated commits
        live; task generations get their own worktrees, never this one."""
        return self.worktrees_dir / "feature" / repo


def ensure_results_dir(paths: FeaturePaths) -> Path:
    """Create `paths.results_dir` and, for a git project root, keep `.loop-spec/`
    out of `git status` via the repo's own (never committed) exclude file -- a
    workspace root that is not a repo just gets the directory. Call before any
    model-written result path under it; both effects are idempotent."""
    paths.results_dir.mkdir(parents=True, exist_ok=True)
    repo_module.exclude_path(paths.project_root, ".loop-spec/")
    return paths.results_dir


def feature_dir(home: Path, repo_id_: str, slug: str) -> Path:
    return Path(home) / repo_id_ / slug


_SLUG_WORD = re.compile(r"[a-z0-9]+")


def slug_from_request(text: str) -> str:
    words = _SLUG_WORD.findall(text.lower())
    slug = "-".join(words)[:40].rstrip("-")
    return slug or "feature"
