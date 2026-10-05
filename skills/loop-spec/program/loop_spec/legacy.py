"""What hosts and monitors built for 7.x read outside the repository, kept 1:1.

7.x kept a run's state under a state home, `$LOOP_SPEC_HOME` or `~/.loop-spec`:

    <home>/<repo id>/<slug>/events.jsonl    every event record (phases.py appends here too)
    <home>/<repo id>/<slug>/result.json     the schema-1 result
    <home>/<repo id>/last-result.json       the latest run's result in this repository

The repo id is 7.x's: the first 16 hex digits of the SHA-256 of the repository's first
root commit (or of its real path when it has none), pinned in git config for a shallow
clone. The run's own directory keeps copies of events.jsonl and result.json too.

`record` builds 7.x's schema-1 result from an 8.x run: 7.x's fields, plus `assumptions`,
`decisions`, `criteria`, `criteriaSha`, and `caveats`. Where 8.x has no
counterpart (attested review steps, a findings ledger, alternate implementations), a
field holds the value 7.x gave a run without one. The 8.x additions, the PR's CI outcome
and reviewer verdicts, ride on the delivery target as extra fields.
"""
import hashlib
import os
import platform
import shutil
import subprocess
from datetime import datetime, timezone
from functools import cache
from pathlib import Path

from loop_spec import VERSION, git
from loop_spec.deliver import title
from loop_spec.runs import write_json

CYCLE_TYPES = {"cycle": "full", "micro": "micro", "debug": "debug", "revise": "revise"}
STATUS = {"converged": "completed", "converged-with-caveats": "completed", "no-change": "completed",
          "escalated": "escalated", "failed": "failed"}
OUTCOME = {"converged": "delivered", "converged-with-caveats": "delivered-draft", "no-change": "no-change-needed",
           "escalated": "escalated", "failed": "failed"}


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def state_home() -> Path:
    env = os.environ.get("LOOP_SPEC_HOME")
    return Path(env) if env else Path.home() / ".loop-spec"


@cache
def repo_id(project: Path) -> str:
    pinned = git.config_get(project, "loop-spec.repoId")
    if pinned:
        return pinned
    roots = git.root_commits(project)
    canonical = sorted(roots)[0] if roots else str(project.resolve())
    rid = hashlib.sha256(canonical.encode()).hexdigest()[:16]
    if roots and git.is_shallow(project):
        # A shallow clone's root is its graft; unshallowing would move the id.
        git.config_set(project, "loop-spec.repoId", rid)
    return rid


def run_dir(run) -> Path:
    return state_home() / repo_id(run.project) / run.slug


def classification(run, status: str) -> str:
    """7.x's `result`: a completed run whose PR is a draft converged with caveats."""
    if status == "completed":
        return "converged" if (run.state.get("delivered") or {}).get("verified", True) else "converged-with-caveats"
    return status


def _host_versions() -> dict:
    claude = None
    if shutil.which("claude"):
        try:
            proc = subprocess.run(["claude", "--version"], capture_output=True, text=True, timeout=10, check=False)
            claude = (proc.stdout or proc.stderr).strip() or None
        except (OSError, subprocess.TimeoutExpired):
            pass
    return {"claude": claude, "python3": f"Python {platform.python_version()}", "git": git.version()}


def record(run, status: str, summary: str, head: str | None, phase: str, kept: list[str]) -> dict:
    """The schema-1 result 7.x wrote, for an 8.x run ending with `status` at `phase`."""
    s = run.state
    result = classification(run, status)
    delivered, pr = s.get("delivered"), s.get("pr") or {}
    caveats = (s.get("iterate") or {}).get("caveats")
    feedback = s.get("feedback") or {}
    verify = s.get("verify")
    verified_sha = head if run.verified_at(head) else None
    repo = run.project.name
    delivery = None
    if delivered:
        delivery = {"targets": [{"repo": repo, "pr": {"number": pr.get("number"), "url": pr.get("url")},
                                 "deliveredSha": delivered["sha"], "caveats": [caveats] if caveats else [],
                                 "state": "delivered", "ci": feedback.get("ci"),
                                 "reviews": feedback.get("verdicts", {})}]}
    shows_pr = bool(delivered) or (result == "no-change" and pr.get("url"))
    ids = {c.get("id") for c in (run.spec or {}).get("criteria", [])}
    criteria = [{"id": r["name"], "passed": r.get("exit") == 0 or r.get("preexisting", False),
                 "checked": r.get("command") is not None}
                for r in (verify or {}).get("results", []) if r["name"] in ids]
    rewinds = s.get("rewinds", 0)
    done = [tid for tid, t in s.get("tasks", {}).items() if t.get("status") == "done"]
    return {
        "schema": 1,
        "loopSpecVersion": VERSION,
        "cycleType": CYCLE_TYPES.get(s.get("kind"), s.get("kind")),
        "slug": run.slug,
        "status": STATUS[result],
        "outcome": OUTCOME[result],
        "reason": summary if result in ("escalated", "failed") else None,
        "summary": summary,
        "noChangeReason": ("diagnostic-only" if s.get("kind") == "debug" else "already-satisfied")
        if result == "no-change" else None,
        "phaseReached": phase,
        "branch": s.get("branch"),
        "baseBranch": (s.get("base") or {}).get("branch"),
        "prUrl": pr.get("url") if shows_pr else None,
        "checkpointPrUrl": None,
        "delivery": delivery,
        "converged": result in ("converged", "no-change"),
        "workDelivered": bool(delivered),
        "iterations": {"used": rewinds, "max": None},
        "warnings": [caveats] if caveats else [],
        "caveats": [caveats] if caveats else [],
        "assumptions": (run.spec or {}).get("assumptions", []),
        "decisions": (run.spec or {}).get("decisions", []),
        "criteria": criteria,
        "criteriaSha": (verify or {}).get("sha"),
        "autonomous": run.mode in ("autonomous", "supervised"),
        "feature_title": title(run),
        "createdAt": s.get("createdAt"),
        "finishedAt": now_iso(),
        "verification": {"status": "not-run" if not verify else ("passed" if verified_sha else "failed"),
                         "command": None},
        "implementationConverged": result in ("converged", "converged-with-caveats", "no-change") or (
            phase == "deliver" and (s.get("iterate") or {}).get("sha") == head),
        "eligibleTargets": [{"branch": s.get("branch"), "targetSha": verified_sha}] if verified_sha else [],
        "retryable": result == "failed",
        "retryPhase": phase if result == "failed" else None,
        "verifiedSha": verified_sha,
        "result": result,
        "rewinds": rewinds,
        "prs": [{"repo": repo, "number": pr.get("number"), "url": pr.get("url")}] if delivered else [],
        "after": [],
        # 8.x reviews the whole change at ITERATE, not each task through an attested step.
        "reviewed": {tid: {"level": "unattested", "stepId": None} for tid in done},
        "unreviewed": [],
        "outstanding": [],
        "blocked": [],
        "partiallyDelivered": False,
        "weakenedAssurance": ["delivered without a passing verify"] if delivered and not delivered.get("verified") else [],
        "cleanupBacklog": kept,
        "implementations": {},
        "policyAnsweredQuestions": [],
        "hostVersions": _host_versions(),
    }



def publish(run, result: dict) -> Path:
    """Write the result where 7.x hosts read it; returns the state-home result path."""
    path = run_dir(run) / "result.json"
    write_json(path, result)
    write_json(path.parent.parent / "last-result.json", result)
    return path
