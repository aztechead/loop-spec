"""Boundary checks: whether an accepted product satisfies its exit's postconditions.

Use `requirements_revision`/`plan_revision` to compute the identities every later
product binds to, `bound_ok` to check a product against the run's current revisions,
and `Boundary.check` to run exactly the ids `ROUTES[phase][exit]` requires and collect
every failure (never stopping at the first). `ROUTES` transcribes the route matrix in
docs/loop-spec/phase-interface-7.0.md; this module never picks a route itself, it only
answers whether the postconditions for a claimed exit hold. controller.py reads
`ROUTES[phase][exit]["next"]` to decide where to go, and reads `Boundary.unreviewed`/
`Boundary.weakened_assurance` after a passing check to fold into state and the result.
"""
import os
import re
from dataclasses import dataclass
from pathlib import Path

from . import budget as budget_module
from . import repo as repo_module
from .contract import load_config
from .ids import digest
from .jsonio import read_json

RETRY_LIMIT_DEFAULT = 3


def retry_limit() -> int:
    env = os.environ.get("LOOP_SPEC_STEP_RETRIES")
    return int(env) if env else RETRY_LIMIT_DEFAULT


def requirements_revision(spec_product: dict) -> str:
    # Open questions are excluded on purpose (phase-interface-7.0.md "Identities"):
    # a question still open is not part of what was approved.
    return digest({k: spec_product[k] for k in ("goal", "boundaries", "criteria", "decisions")})


def plan_revision(plan_product: dict) -> str:
    return digest({k: v for k, v in plan_product.items() if k not in ("inputsDigest", "boundTo")})


def bound_ok(product: dict, store, phase: str) -> str | None:
    bound_to = product.get("boundTo") or {}
    revisions = store.state["revisions"]
    if bound_to.get("requirements") != revisions.get("requirements"):
        return "bound to stale requirements revision"
    # The plan revision is only meaningful once a plan exists to bind to; SPEC and
    # PLAN's own products do not carry a "current plan" to compare against.
    if phase in ("execute", "verify", "iterate", "deliver") and bound_to.get("plan") != revisions.get("plan"):
        return "bound to stale plan revision"
    return None


@dataclass
class Failure:
    id: str
    message: str


# ROUTES[phase][exit] = {"requires": [ids], "next": (phase|None, mode), "backward": bool}
# mode is one of "fresh", "remediation", "rewind", "terminal", "pause". `next`'s phase
# is None for a terminal exit; ITERATE `rewind` also carries None here because its
# target phase is named per-gap in the product, not fixed by the exit (controller.py
# resolves it from `product["gaps"]`).
ROUTES: dict[str, dict[str, dict]] = {
    "spec": {
        "approved": {"requires": ["S1", "S2", "S3"], "next": ("plan", "fresh"), "backward": False},
        "needs answer": {"requires": ["S1"], "next": ("spec", "remediation"), "backward": False},
    },
    "plan": {
        "ready": {"requires": ["P1", "P2", "P3", "P4", "P5", "P6", "P7"], "next": ("execute", "fresh"), "backward": False},
        "spec gap": {"requires": ["P1", "T1"], "next": ("spec", "remediation"), "backward": True},
    },
    "execute": {
        "integrated": {"requires": ["E1", "E2", "E3", "E4", "E5", "E6", "E7", "E8", "E11", "!E9"], "next": ("verify", "fresh"), "backward": False},
        "no change": {"requires": ["E1", "E2", "E8", "E9"], "next": ("verify", "fresh"), "backward": False},
        "blocked": {"requires": ["E1", "E10"], "next": ("execute", "remediation"), "backward": False, "pause": True},
        "plan gap": {"requires": ["E1", "T1"], "next": ("plan", "remediation"), "backward": True},
    },
    "verify": {
        "passed": {"requires": ["V1", "V2", "V3", "V4", "V5", "V7", "V8"], "next": ("iterate", "fresh"), "backward": False},
        "implementation gap": {"requires": ["V1", "V2", "V8", "T1"], "next": ("execute", "remediation"), "backward": True},
        "plan gap": {"requires": ["V1", "V2", "V8", "T1"], "next": ("plan", "remediation"), "backward": True},
        "intent gap": {"requires": ["V1", "V2", "V8", "T1"], "next": ("spec", "remediation"), "backward": True},
        "evidence incomplete": {"requires": ["V1", "T1"], "next": ("verify", "remediation"), "backward": True},
        "blocked": {"requires": ["V1", "V2", "V6", "V8", "V9"], "next": ("verify", "remediation"), "backward": False, "pause": True},
    },
    "iterate": {
        "converged": {"requires": ["I1", "I5"], "next": ("deliver", "fresh"), "backward": False},
        "converged with caveats": {"requires": ["I1", "I5", "I6"], "next": ("deliver", "fresh"), "backward": False},
        "rewind": {"requires": ["I1", "I2", "I3"], "next": (None, "rewind"), "backward": True},
        "escalated": {"requires": ["I1", "I4"], "next": (None, "terminal"), "backward": False},
    },
    "deliver": {
        "delivered": {"requires": ["D1", "D2", "D3", "D4", "D7"], "next": (None, "terminal"), "backward": False},
        "partially delivered": {"requires": ["D4", "D5", "D7"], "next": (None, "terminal"), "backward": False},
        "delivery blocked": {"requires": ["D4"], "next": ("deliver", "remediation"), "backward": False, "pause": True},
    },
    "debug": {
        # Not runnable until M4 (run_entry refuses "debug"); the checks exist now so
        # postconditions.py needs no rework when the entry lands.
        "reproduced": {"requires": ["B1", "B2", "S1", "S2", "S3", "P1", "P2", "P3", "P4", "P5", "P6", "P7"], "next": ("execute", "fresh"), "backward": False},
        "blocked reproduction": {"requires": ["B3"], "next": ("debug", "remediation"), "backward": False, "pause": True},
    },
}

ACCEPTED_REVIEW_LEVELS = {"controller-observed", "host-attested"}
_PERMISSION_DENIED_MARKER = "permission-denied"
_OFFLINE_CAUSE = re.compile(r"offline|network|unavailable|ENOTFOUND|Could not resolve", re.IGNORECASE)


def verified_head(store) -> str:
    # The single-repo convenience form: callers that already know there is exactly
    # one repo (result.py's verifiedSha, ITERATE's compact boundSha use) read its
    # head from here. A workspace run has no single "the" verified head; use
    # verified_heads() instead.
    execute = store.state["products"]["execute"]
    repo_entry = next(iter(store.state["repos"].values()))
    if execute["exit"] == "no change":
        return repo_entry["baseSha"]
    return next(iter(execute["product"]["heads"].values()))


def verified_heads(store) -> dict[str, str]:
    # LF-28: EXECUTE's own product always carries a head per repo it initialized,
    # touched or not (an untouched repo's head is already its base -- execute.py
    # only ever moves a repo's head when one of its tasks lands), so there is no
    # separate "no change" case to special-case here the way verified_head() does.
    return store.state["products"]["execute"]["product"]["heads"]


def review_evidence(store, task_id: str) -> tuple[str, str | None]:
    """The evidence level and step id for one EXECUTE task's review: E6 and
    result.py's `reviewed` field both need this. An external EXECUTE's whole
    product is one human-attested submission with no per-task review step; the
    default implementation instead runs one, whose own submission (steps.submit's
    evidence-level judgment) is the real evidence, and its id names it."""
    if store.state["implementations"]["phases"].get("execute") == "external":
        return "human-attested", None
    review_steps = (store.state.get("execute") or {}).get("tasks", {}).get(task_id, {}).get("reviewSteps") or []
    if not review_steps:
        return "unattested", None
    step_id = review_steps[-1]
    level = store.state["steps"]["submissions"].get(step_id, {}).get("evidenceLevel", "unattested")
    return level, step_id


def _check_supersedes(findings: list[dict], ledger: dict, repos: dict[str, Path]) -> str | None:
    reviewed_ranges = ledger.get("reviewedRanges", [])
    if not reviewed_ranges or not repos:
        return None  # nothing cleared yet for a finding to supersede
    # LF-28: a range's from/to belongs to the ONE repo it reviewed; diffing it
    # against a different repo's git history is meaningless, so files are tracked
    # per repo, never pooled across the workspace.
    touched_by_repo: dict[str, set[str]] = {}
    for reviewed_range in reviewed_ranges:
        repo_path = repos.get(reviewed_range.get("repo"))
        if repo_path is None:
            continue
        out = repo_module.run_git(repo_path, "diff", "--name-only", f"{reviewed_range['from']}..{reviewed_range['to']}")
        touched_by_repo.setdefault(reviewed_range["repo"], set()).update(line for line in out.splitlines() if line)
    known_ids = {f["id"] for f in ledger["findings"]} | {r["id"] for r in reviewed_ranges if "id" in r}
    # ponytail: a finding with no repo tag in a multi-repo product can't be matched
    # to one repo's touched files; a single-repo product needs no tag at all.
    single_repo = next(iter(repos)) if len(repos) == 1 else None
    for finding in findings:
        repo_name = finding.get("repo") or single_repo
        touched = touched_by_repo.get(repo_name, set()) if repo_name else set()
        path = finding.get("location", "").split(":", 1)[0]
        if path not in touched:
            continue
        supersedes = finding.get("supersedes")
        if not supersedes or supersedes.get("id") not in known_ids:
            return f"finding {finding.get('id')} touches previously reviewed code with no valid supersedes"
    return None


class Boundary:
    """One boundary check: which ids does `exit` require, and do they hold.

    `unreviewed` and `weakened_assurance` accumulate during `check()` (E6, V5) for the
    controller to read afterward and fold into state and the terminal result.
    """

    def __init__(self, store, paths, *, phase: str, product: dict, exit: str, project_root: Path) -> None:
        self.store = store
        self.paths = paths
        self.phase = phase
        self.product = product
        self.exit = exit
        self.project_root = Path(project_root)
        self.unreviewed: list[str] = []
        self.weakened_assurance: list[str] = []

    def check(self) -> list[Failure]:
        requires = ROUTES[self.phase][self.exit]["requires"]
        failures: list[Failure] = []
        for req_id in requires:
            if req_id.startswith("!"):
                base_id = req_id[1:]
                if getattr(self, f"_{base_id.lower()}")() is None:
                    failures.append(Failure(req_id, f"{base_id} must be false"))
                continue
            message = getattr(self, f"_{req_id.lower()}")()
            if message is not None:
                failures.append(Failure(req_id, message))
        return failures

    # -- shared helpers ------------------------------------------------------

    def _validates(self) -> list[str]:
        from .schema import load_schema, validate
        return validate(self.product, load_schema(self.phase))

    def _bound(self) -> str | None:
        return bound_ok(self.product, self.store, self.phase)

    def _repo_entries(self) -> dict:
        return self.store.state.get("repos") or {}

    def _first_repo_path(self) -> Path | None:
        repos = self._repo_entries()
        if not repos:
            return None
        return Path(next(iter(repos.values()))["path"])

    def _repo_paths(self) -> dict[str, Path]:
        return {name: Path(info["path"]) for name, info in self._repo_entries().items()}

    def _repo_head_or_error(self, name: str) -> tuple[str | None, str | None]:
        head = self.product["heads"].get(name)
        if head is None:
            return None, f"repo {name} has no head in the EXECUTE product"
        return head, None

    # -- S: SPEC ---------------------------------------------------------

    def _s1(self) -> str | None:
        errors = self._validates()
        return "; ".join(errors) if errors else None  # S1 has no binding: SPEC is the run's first product.

    def _s2(self) -> str | None:
        approval = self.store.state.get("approval")
        if approval is None:
            return "no approval record"
        if approval.get("revision") != requirements_revision(self.product):
            return "approval does not name this requirements revision"
        answered = self.store.state["questions"]["answered"].get(approval.get("questionId"))
        if answered is None:
            return "approval references a question with no recorded answer"
        if answered.get("by") not in ("human", "policy"):
            return "approval's answer was not recorded by a human or policy"
        return None

    def _s3(self) -> str | None:
        if "approval" in self.product or "approved" in self.product:
            return "the product declares its own approval; only the program writes it"
        approval = self.store.state.get("approval")
        if approval is None or approval.get("writer") != "program":
            return "no program-written approval record"
        return None

    # -- P: PLAN -----------------------------------------------------------

    def _p1(self) -> str | None:
        errors = self._validates()
        return "; ".join(errors) if errors else self._bound()

    def _p2(self) -> str | None:
        spec_product = self.store.state["products"]["spec"]["product"]
        covered = {cid for task in self.product["tasks"] for cid in task["criteria"]}
        missing = [c["id"] for c in spec_product["criteria"] if c["id"] not in covered]
        return f"criteria not covered by any task: {', '.join(missing)}" if missing else None

    def _p3(self) -> str | None:
        entries = (self.store.state.get("baseline") or {}).get("entries", {})
        for task in self.product["tasks"]:
            entry = entries.get(task["verify"])
            if task.get("featureAdded"):
                if entry is None or entry.get("status") != "no-baseline":
                    return f"task {task['id']}: featureAdded command was not recorded as no-baseline"
                continue
            if entry is None or entry.get("status") != "ran":
                return f"task {task['id']}: verify command has no baseline run"
            run = entry.get("run") or {}
            if run.get("errorClass") is not None or run.get("exitStatus") == 127:
                return f"task {task['id']}: baseline run for its verify command failed to execute"
        return None

    def _p4(self) -> str | None:
        baseline = self.store.state.get("baseline")
        if baseline is None:
            return "no baseline captured"
        repo_path = self._first_repo_path()
        repo_info = next(iter(self._repo_entries().values()), None)
        if repo_path is None or repo_info is None:
            return "no repo resolved to capture a baseline against"
        if baseline.get("baseSha") != repo_info.get("baseSha"):
            return "baseline was captured at a different base SHA"
        if baseline.get("prepare") != self.product.get("prepare"):
            return "baseline's prepare command does not match the plan's"
        prepare_run = baseline.get("prepareRun")
        if prepare_run is not None and prepare_run.get("exitStatus") != 0:
            return "baseline's prepare command failed"
        health = self.store.state.get("environmentHealth") or {}
        for entry in baseline.get("entries", {}).values():
            run = entry.get("run")
            if run and run.get("errorClass") is not None and entry["command"] not in health:
                return f"baseline command {entry['command']!r} failed with no recorded environment health"
        return None

    def _p5(self) -> str | None:
        tasks = {t["id"]: t for t in self.product["tasks"]}
        for task_id, task in tasks.items():
            for dep in task["dependsOn"]:
                if dep not in tasks:
                    return f"task {task_id} depends on unknown task {dep}"

        visiting: set[str] = set()
        visited: set[str] = set()

        def on_cycle(task_id: str) -> bool:
            if task_id in visiting:
                return True
            if task_id in visited:
                return False
            visiting.add(task_id)
            found = any(on_cycle(dep) for dep in tasks[task_id]["dependsOn"])
            visiting.discard(task_id)
            visited.add(task_id)
            return found

        for task_id in tasks:
            if on_cycle(task_id):
                return f"the task graph has a cycle reaching {task_id}"
        return None

    def _p6(self) -> str | None:
        repos = self._repo_entries()
        if not repos:
            return "no repo resolved for the plan"
        for task in self.product["tasks"]:
            if task["repo"] not in repos:
                return f"task {task['id']} names an unknown repo {task['repo']!r}"
        return None

    def _p7(self) -> str | None:
        critic = self.store.state.get("critic")
        if critic is None:
            return "no critic pass recorded"
        for finding in critic.get("findings", []):
            if finding.get("severity") != "Critical":
                continue
            disposition = finding.get("disposition")
            if disposition == "fixed":
                if critic.get("passes", 0) < 2:
                    return f"Critical finding {finding.get('id')} is fixed but the critic was not re-run"
            elif disposition == "rejected":
                if not finding.get("reason"):
                    return f"Critical finding {finding.get('id')} is rejected with no reason"
            else:
                return f"Critical finding {finding.get('id')} is {disposition}; only fixed (rechecked) or rejected with reason close it"
        return None

    # -- E: EXECUTE ----------------------------------------------------------

    def _e1(self) -> str | None:
        errors = self._validates()
        return "; ".join(errors) if errors else self._bound()

    def _e2(self) -> str | None:
        plan_product = self.store.state["products"]["plan"]["product"]
        by_id = {t["id"]: t for t in self.product["tasks"]}
        amendments = self.store.state.get("amendments") or {}
        for plan_task in plan_product["tasks"]:
            task = by_id.get(plan_task["id"])
            if task is None:
                return f"task {plan_task['id']} has no disposition in the EXECUTE product"
            if task["disposition"] == "already-satisfied" and not task.get("evidence"):
                return f"task {task['id']} is already-satisfied with no evidence"
            if task["disposition"] == "removed" and task["id"] not in amendments:
                return f"task {task['id']} is removed with no approved amendment"
        return None

    def _step_issued_at(self, step_id: str) -> str | None:
        path = self.paths.steps_dir / step_id / "step.json"
        return read_json(path).get("issuedAt") if path.is_file() else None

    def _e3_dispatch_ordering(self, execute_tasks: dict, task_id: str, dep_id: str) -> str | None:
        # An external EXECUTE product has no per-task dispatch timeline (execute.py
        # never ran), so there is nothing to order here beyond the disposition check
        # above; the default implementation's own state.execute.tasks records it.
        task_steps = execute_tasks.get(task_id, {}).get("implementSteps") or []
        dep_steps = execute_tasks.get(dep_id, {}).get("reviewSteps") or execute_tasks.get(dep_id, {}).get("implementSteps") or []
        if not task_steps or not dep_steps:
            return None
        submissions = self.store.state["steps"]["submissions"]
        task_started = self._step_issued_at(task_steps[0])
        dep_finished = submissions.get(dep_steps[-1], {}).get("submittedAt")
        if task_started and dep_finished and task_started < dep_finished:
            return f"task {task_id} was dispatched before its dependency {dep_id} finished"
        return None

    def _e3(self) -> str | None:
        by_id = {t["id"]: t for t in self.product["tasks"]}
        plan_tasks = {t["id"]: t for t in self.store.state["products"]["plan"]["product"]["tasks"]}
        execute_tasks = (self.store.state.get("execute") or {}).get("tasks", {})
        for task in self.product["tasks"]:
            if task["disposition"] != "done":
                continue
            plan_task = plan_tasks.get(task["id"])
            if plan_task is None:
                continue
            for dep_id in plan_task["dependsOn"]:
                dep_task = by_id.get(dep_id)
                if dep_task is None or dep_task["disposition"] not in ("done", "already-satisfied", "adopted"):
                    return f"task {task['id']} depends on {dep_id}, which has no accepted disposition"
                ordering_error = self._e3_dispatch_ordering(execute_tasks, task["id"], dep_id)
                if ordering_error:
                    return ordering_error
        return None

    def _e4(self) -> str | None:
        # A task's repo lives on the PLAN task; in a workspace, unioning every task's
        # commits against each repo's range rejected a correct two-repo product (LF-24).
        plan_repo = {t["id"]: t["repo"] for t in self.store.state["products"]["plan"]["product"]["tasks"]}
        for name, info in self._repo_entries().items():
            repo_path = Path(info["path"])
            head, error = self._repo_head_or_error(name)
            if error:
                return error
            task_commits = {
                repo_module.head_sha(repo_path, c) for t in self.product["tasks"]
                if t["disposition"] in ("done", "adopted") and plan_repo.get(t["id"]) == name
                for c in t["commits"]
            }
            actual = set(repo_module.commits_between(repo_path, info["baseSha"], head))
            if task_commits != actual:
                return f"repo {name}: task commits do not exactly cover base..head"
        return None

    def _e5(self) -> str | None:
        repos = self._repo_entries()
        # The EXECUTE task schema carries no "repo" field (only PLAN's does), so
        # the repo name for each task comes from the matching PLAN task, same as _e3.
        plan_tasks = {t["id"]: t for t in self.store.state["products"]["plan"]["product"]["tasks"]}
        for task in self.product["tasks"]:
            if task["disposition"] not in ("done", "adopted"):
                continue
            review = task.get("review")
            if review is None or review.get("verdict") != "pass":
                return f"task {task['id']} has no passing review"
            repo_path = Path(repos[plan_tasks[task["id"]]["repo"]]["path"])
            reviewed_from, reviewed_to = review["reviewedRange"]["from"], review["reviewedRange"]["to"]
            for commit in task["commits"]:
                sha = repo_module.head_sha(repo_path, commit)
                if not repo_module.is_ancestor(repo_path, reviewed_from, sha) or not repo_module.is_ancestor(repo_path, sha, reviewed_to):
                    return f"task {task['id']}: commit {commit} is outside its reviewed range"
            if task["disposition"] == "adopted" and not self.store.state.get("adoptedReview"):
                return f"task {task['id']} is adopted with no full range review recorded"
        return None

    def _e6(self) -> str | None:
        is_external = self.store.state["implementations"]["phases"].get("execute") == "external"
        accept_unattested = load_config(self.project_root).get("evidence", {}).get("review", {}).get("accept") == "unattested"
        for task in self.product["tasks"]:
            if task["disposition"] not in ("done", "adopted"):
                continue
            level, _ = review_evidence(self.store, task["id"])
            if level in ACCEPTED_REVIEW_LEVELS or (level == "human-attested" and is_external):
                continue
            if level == "unattested" and accept_unattested:
                self.weakened_assurance.append({"kind": "evidence.review.accept", "value": "unattested", "task": task["id"]})
                continue
            self.unreviewed.append(task["id"])
        if self.unreviewed:
            return f"tasks with an unaccepted review evidence level: {', '.join(self.unreviewed)}"
        return None

    def _e7(self) -> str | None:
        runs = self.store.state.get("executeRuns") or {}
        for task in self.product["tasks"]:
            if task["disposition"] not in ("done", "adopted"):
                continue
            record = runs.get(task["id"])
            if record is None:
                return f"task {task['id']} has no recorded verify re-run"
            verdict = record["comparison"]["verdict"]
            if verdict in ("regression", "featureAdded-failed", "mustFlip-failed", "baseline-error"):
                return f"task {task['id']}: verify comparison is {verdict}"
        return None

    def _e8(self) -> str | None:
        for name, info in self._repo_entries().items():
            repo_path = Path(info["path"])
            head, error = self._repo_head_or_error(name)
            if error:
                return error
            head_sha = repo_module.head_sha(repo_path, head)
            if not repo_module.is_ancestor(repo_path, info["baseSha"], head_sha):
                return f"repo {name}: head is not reachable from base"
            if repo_module.branch_sha(repo_path, info["featureBranch"]) != head_sha:
                return f"repo {name}: feature branch was moved out of band"
            last_known = info.get("lastKnownHead")
            if last_known and not repo_module.is_ancestor(repo_path, last_known, head_sha):
                return f"repo {name}: head is not a descendant of the last known head"
        return None

    def _e9(self) -> str | None:
        for name, info in self._repo_entries().items():
            head = self.product["heads"].get(name)
            if head and repo_module.commits_between(Path(info["path"]), info["baseSha"], head):
                return f"repo {name} has commits since base"
        for task in self.product["tasks"]:
            if task["disposition"] not in ("already-satisfied", "removed"):
                return f"task {task['id']} is not already-satisfied or removed on a no-change exit"
        return None

    def _e10(self) -> str | None:
        issues = self.product.get("issues") or []
        if not issues:
            return "no issues recorded for the blocked exit"
        has_permission_denied = any(_PERMISSION_DENIED_MARKER in i["text"] for i in issues)
        if self.store.state["phase"].get("retries", 0) < retry_limit() and not has_permission_denied:
            return f"blocked claimed before the retry limit ({retry_limit()}) or a permission-denied issue"
        return None

    def _e11(self) -> str | None:
        signals = (self.store.state.get("probes") or {}).get("securitySignals") or []
        if not signals:
            return None  # M2+: probes.securitySignals is empty at M1, so this always holds.
        # "files" lives on the PLAN task, not the EXECUTE task, same as _e5's repo lookup.
        plan_tasks = {t["id"]: t for t in self.store.state["products"]["plan"]["product"]["tasks"]}
        for task in self.product["tasks"]:
            touched = set(plan_tasks.get(task["id"], {}).get("files", [])) & set(signals)
            if not touched:
                continue
            covered = {d["signal"] for d in (task.get("review") or {}).get("securityDispositions", [])}
            if not touched.issubset(covered):
                return f"task {task['id']} touches a security signal with no disposition"
        return None

    # -- V: VERIFY ---------------------------------------------------------

    def _v1(self) -> str | None:
        errors = self._validates()
        return "; ".join(errors) if errors else self._bound()

    def _v2(self) -> str | None:
        spec_product = self.store.state["products"]["spec"]["product"]
        expected = {c["id"] for c in spec_product["criteria"]}
        seen = [v["criterion"] for v in self.product["verdicts"]]
        if set(seen) != expected or len(seen) != len(set(seen)):
            return "verdicts do not cover exactly the current criteria, once each"
        return None

    def _v3(self) -> str | None:
        heads = verified_heads(self.store)
        for verdict in self.product["verdicts"]:
            evidence = verdict.get("evidence")
            if evidence and evidence["sha"] != heads.get(evidence["repo"]):
                return f"criterion {verdict['criterion']}: evidence SHA is not the verified head for repo {evidence['repo']}"
        return None

    def _exceptions(self) -> set[str]:
        plan_product = self.store.state["products"]["plan"]["product"]
        declared = {e["criterion"] for e in plan_product.get("evidenceExceptions", [])}
        operator = set(self.store.state.get("verifyExceptionsThisAttempt") or [])
        return declared | operator

    def _v4(self) -> str | None:
        exceptions = self._exceptions()
        runs = self.store.state.get("verifyRuns") or {}
        for verdict in self.product["verdicts"]:
            if verdict["verdict"] not in ("pass", "fail") or verdict["criterion"] in exceptions:
                continue
            record = runs.get(verdict["criterion"])
            if record is None:
                return f"criterion {verdict['criterion']}: no matching re-run recorded"
            if not record.get("matched"):
                rerun = record.get("rerun") or {}
                rerun_exit = rerun.get("exitStatus")
                cwd_name = Path(rerun.get("cwd", "")).name
                note = "; an exit of 127 means the command was not found in the clean checkout" if rerun_exit == 127 else ""
                return (
                    f"criterion {verdict['criterion']}: the program's re-run differs from the claim: "
                    f"{record.get('reason')} (claimed exit {(verdict.get('evidence') or {}).get('exitStatus')}, "
                    f"re-run exit {rerun_exit} in {cwd_name}{note})"
                )
        return None

    def _v5(self) -> str | None:
        # Same two sources _exceptions() unions for V4's membership check, but V5's
        # own record needs each one's own reason and where it came from, not just the
        # criterion id: an entry here reads the same as E6's (kind/criterion/source/
        # reason), not a bare criterion string.
        plan_product = self.store.state["products"]["plan"]["product"]
        seen: set[str] = set()
        for exc in plan_product.get("evidenceExceptions", []):
            if exc["criterion"] in seen:
                continue
            seen.add(exc["criterion"])
            self.weakened_assurance.append(
                {"kind": "evidence.exception", "criterion": exc["criterion"], "source": "plan", "reason": exc["reason"]}
            )
        for exc in self.store.state.get("verifyExceptionsThisAttempt") or []:
            if exc["criterion"] in seen:
                continue
            seen.add(exc["criterion"])
            self.weakened_assurance.append(
                {"kind": "evidence.exception", "criterion": exc["criterion"], "source": "answer", "reason": exc.get("reason")}
            )
        return None

    def _v6(self) -> str | None:
        baseline = self.store.state.get("baseline") or {}
        runs = self.store.state.get("verifyRuns") or {}
        for verdict in self.product["verdicts"]:
            if verdict["verdict"] != "blocked":
                continue
            cause = verdict.get("cause") or ""
            observed = any(e.get("run", {}).get("errorClass") for e in baseline.get("entries", {}).values()) or \
                any(r.get("errorClass") for r in runs.values())
            if not cause or not observed:
                return f"criterion {verdict['criterion']}: blocked cause is not observed in a recorded run"
        return None

    def _v7(self) -> str | None:
        if any(v["verdict"] != "pass" for v in self.product["verdicts"]):
            return "not every verdict is pass"
        # LF-28: the first/delta rule is per repo -- a repo VERIFY is reviewing for
        # the first time must see its own full diff even if another repo in the
        # same workspace already has a reviewed history to continue from.
        ledger_ranges = self.store.state["ledger"]["reviewedRanges"]
        for reviewed_range in self.product["reviewedRanges"]:
            repo = reviewed_range["repo"]
            prior = [r for r in ledger_ranges if r.get("repo") == repo]
            if not prior:
                if not reviewed_range.get("full"):
                    return f"repo {repo}: first VERIFY pass must review the full diff"
            elif reviewed_range["from"] != prior[-1]["to"]:
                return f"repo {repo}: reviewed range does not continue from the last reviewed SHA"
        findings = self.product.get("findings", []) + self.store.state["ledger"]["findings"]
        if any(f["severity"] == "Critical" and f["disposition"] == "open" for f in findings):
            return "a Critical finding is open"
        return None

    def _v8(self) -> str | None:
        return _check_supersedes(self.product.get("findings", []), self.store.state["ledger"], self._repo_paths())

    def _v9(self) -> str | None:
        for verdict in self.product["verdicts"]:
            if verdict["verdict"] != "blocked" or not _OFFLINE_CAUSE.search(verdict.get("cause") or ""):
                continue
            if verdict["criterion"] not in (self.product.get("standInTried") or []):
                return f"criterion {verdict['criterion']}: offline cause claimed with no stand-in tried"
        return None

    # -- I: ITERATE ----------------------------------------------------------

    def _i1(self) -> str | None:
        errors = self._validates()
        if errors:
            return "; ".join(errors)
        bound_failure = self._bound()
        if bound_failure:
            return bound_failure
        heads = self.store.state["products"]["execute"]["product"]["heads"]
        bound_shas = self.product.get("boundShas") or {}
        for repo, head in heads.items():
            if bound_shas.get(repo) != head:
                return f"boundShas does not bind repo {repo} to the EXECUTE head"
        return None

    def _i2(self) -> str | None:
        for gap in self.product.get("gaps", []):
            if gap["target"] not in ("spec", "plan", "execute", "verify"):
                return f"gap names an unknown target {gap['target']!r}"
        return None

    def _i3(self) -> str | None:
        return None if budget_module.has_room(self.store) else "the rewind budget has no room"

    def _i4(self) -> str | None:
        rewind_refused = self.product.get("verdict") == "unmet" and not budget_module.has_room(self.store)
        unclosable_gap = any(g.get("target") is None for g in self.product.get("gaps", []))
        return None if (rewind_refused or unclosable_gap) else "escalated claimed with budget remaining and every gap routable"

    def _i5(self) -> str | None:
        verify_entry = self.store.state["products"]["verify"]
        if verify_entry["exit"] != "passed":
            return "VERIFY did not exit passed"
        if bound_ok(verify_entry["product"], self.store, "verify") is not None:
            return "VERIFY product is not bound to the current revisions"
        if self.product.get("verdict") != "met":
            return "ITERATE verdict is not met"
        if self.product.get("gaps"):
            return "ITERATE has open gaps against a met verdict"
        if self.exit == "converged" and any(f.get("disposition") == "open" for f in self.store.state["ledger"]["findings"]):
            return "a finding is open; converged allows none"
        return None

    def _i6(self) -> str | None:
        ledger_findings = {f["id"]: f for f in self.store.state["ledger"]["findings"]}
        if any(f["severity"] == "Critical" and f["disposition"] == "open" for f in ledger_findings.values()):
            return "a Critical finding is open"
        for finding_id in self.product.get("caveats", []):
            finding = ledger_findings.get(finding_id)
            if finding is None:
                return f"caveat {finding_id} is not a finding in the ledger"
            if finding["severity"] == "Critical":
                return f"caveat {finding_id} is Critical; only non-Critical findings may be caveats"
            if finding["disposition"] not in ("rejected", "deferred", "fixed"):
                return f"caveat {finding_id} has no recorded disposition"
        if self.exit == "converged with caveats" and not self.product.get("caveats"):
            return "converged with caveats needs at least one caveat"
        return None

    # -- D: DELIVER ----------------------------------------------------------

    def _d1(self) -> str | None:
        heads = self.store.state["products"]["execute"]["product"].get("heads", {})
        for entry in self.product["repos"]:
            if entry["state"] != "delivered":
                continue
            repo_info = self._repo_entries().get(entry["repo"])
            if repo_info is None:
                return f"repo {entry['repo']} is not a known repo"
            remote_sha = repo_module.remote_head(Path(repo_info["path"]), "origin", repo_info["featureBranch"])
            expected_head = heads.get(entry["repo"], entry["deliveredSha"])
            if remote_sha != entry["deliveredSha"] or entry["deliveredSha"] != expected_head:
                return f"repo {entry['repo']}: remote head, deliveredSha, and EXECUTE head do not all match"
        return None

    def _d2(self) -> str | None:
        import json as _json
        for entry in self.product["repos"]:
            if entry["state"] != "delivered" or entry.get("pr") is None:
                continue
            repo_info = self._repo_entries()[entry["repo"]]
            code, out, err = repo_module.run_gh(
                Path(repo_info["path"]), "pr", "view", str(entry["pr"]["number"]),
                "--json", "state,headRefName,headRefOid,baseRefName",
            )
            if code != 0:
                return f"repo {entry['repo']}: gh pr view failed: {err.strip() or code}"
            data = _json.loads(out)
            base = load_config(self.project_root).get("deliver", {}).get("base") or repo_module.default_branch(Path(repo_info["path"]))
            if data.get("state") != "OPEN" or data.get("headRefName") != entry["pr"]["headRef"] or \
               data.get("headRefOid") != entry["deliveredSha"] or data.get("baseRefName") != base:
                return f"repo {entry['repo']}: PR does not match the delivered identity"
        return None

    def _d3(self) -> str | None:
        if load_config(self.project_root).get("deliver", {}).get("readiness", "none") != "checks":
            return None
        for entry in self.product["repos"]:
            if entry["state"] != "delivered" or entry.get("pr") is None:
                continue
            repo_info = self._repo_entries()[entry["repo"]]
            code, _, err = repo_module.run_gh(Path(repo_info["path"]), "pr", "checks", str(entry["pr"]["number"]))
            if code != 0:
                return f"repo {entry['repo']}: required checks are not satisfied: {err.strip()}"
        return None

    def _d4(self) -> str | None:
        attempts = self.store.state.setdefault("deliverAttempts", {})
        for entry in self.product["repos"]:
            if entry.get("pr") is None:
                continue
            recorded = attempts.get(entry["repo"])
            if recorded is None:
                attempts[entry["repo"]] = entry["pr"]["number"]
            elif recorded != entry["pr"]["number"]:
                return f"repo {entry['repo']}: a different PR ({entry['pr']['number']}) than the first attempt ({recorded})"
        return None

    def _d5(self) -> str | None:
        states = [entry["state"] for entry in self.product["repos"]]
        if "delivered" not in states or all(s == "delivered" for s in states):
            return "partially delivered needs at least one delivered and one not-delivered repo"
        return None

    def _d6(self) -> str | None:
        for entry in self.product["repos"]:
            if entry.get("pr") is not None or entry["state"] != "skipped":
                return f"repo {entry['repo']}: a no-change head must open no PR and be skipped"
        return None

    def _d7(self) -> str | None:
        checks = self.store.state.get("credentialChecks") or {}
        for entry in self.product["repos"]:
            if entry["state"] == "skipped":
                continue
            check = checks.get(entry["repo"])
            if check is None or not (check.get("git_ok") and check.get("gh_ok")):
                return f"repo {entry['repo']}: credentials were not checked and ok before the remote write"
        return None

    # -- B: debug (checks implemented now; the entry lands at M4) ------------

    def _reproduction_run_holds(self, run: dict | None) -> str | None:
        # LF-23: the worker's own failureDigest comes from its own checkout, a
        # different path than the program's clean checkout that recorded `run` --
        # the two digests can never match (state.debug.claimedDigest records the
        # worker's claim instead, never compared). B1/B2 hold on what the program's
        # own run actually observed: it failed, it wasn't a spawn/lookup failure, and
        # it parsed at least one identity or fingerprint to flip later.
        if run is None:
            return "the reproduction did not run at base in a recorded run"
        exit_status = run.get("exitStatus")
        error_class = run.get("errorClass")
        if exit_status == 127 or error_class is not None:
            return (f"the reproduction could not run at base ({error_class or 'command not found'}): "
                    "use an absolute interpreter path and a command that runs from the checkout root")
        if exit_status == 0:
            return "the reproduction passed at base; it does not reproduce the report"
        if not (run.get("failureIdentities") or run.get("fingerprints")):
            return "the reproduction failed at base but recorded no parsed failure identity or fingerprint"
        return None

    def _b1(self) -> str | None:
        return self._reproduction_run_holds((self.store.state.get("debug") or {}).get("baseRun"))

    def _b2(self) -> str | None:
        if self.product.get("original") is None:
            return None
        if not self.product["reproduction"].get("reason"):
            return "a changed reproduction needs a stated reason"
        return self._reproduction_run_holds((self.store.state.get("debug") or {}).get("originalRun"))

    def _b3(self) -> str | None:
        if self.product.get("reproduction") is not None:
            return "a reproduction exists; blocked reproduction forbids one"
        return None

    # -- T1: shared budget -----------------------------------------------

    def _t1(self) -> str | None:
        return None if budget_module.has_room(self.store) else "the rewind budget has no room"
