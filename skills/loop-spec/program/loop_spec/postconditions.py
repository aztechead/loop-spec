"""Boundary checks: whether an accepted product satisfies its exit's postconditions.

Use `requirements_revision`/`plan_revision` to compute the identities every later
product binds to, `bound_ok` to check a product against the run's current revisions,
and `Boundary.check` to run exactly the ids `ROUTES[phase][exit]` requires and collect
every failure (never stopping at the first). `ROUTES` transcribes the route matrix in
docs/loop-spec/phase-interface-7.0.md; this module never picks a route itself, it only
answers whether the postconditions for a claimed exit hold. It also holds the facts
about an adopted PR that the checks and the phases share (`start_sha`,
`adopted_commits`, `adoptable_task_ids`). controller.py reads
`ROUTES[phase][exit]["next"]` to decide where to go, and reads `Boundary.unreviewed`/
`Boundary.weakened_assurance` after a passing check to fold into state and the result.
"""
import json
import os
import re
from dataclasses import dataclass
from pathlib import Path

from loop_spec import baseline as baseline_module
from loop_spec import budget as budget_module
from loop_spec import ledger as ledger_module
from loop_spec import repo as repo_module
from loop_spec import repo_checks
from loop_spec.contract import load_config
from loop_spec.ids import digest
from loop_spec.jsonio import read_json, render_json

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
        "ready": {"requires": ["P1", "P2", "P3", "P4", "P5", "P6", "P7", "P8"], "next": ("execute", "fresh"), "backward": False},
        "spec gap": {"requires": ["P1", "T1"], "next": ("spec", "remediation"), "backward": True},
    },
    "execute": {
        "integrated": {"requires": ["E1", "E2", "E3", "E4", "E5", "E6", "E7", "E8", "E11", "!E9"], "next": ("verify", "fresh"), "backward": False},
        "no change": {"requires": ["E1", "E2", "E8", "E9"], "next": ("verify", "fresh"), "backward": False},
        "blocked": {"requires": ["E1", "E10"], "next": ("execute", "remediation"), "backward": False, "pause": True},
        "plan gap": {"requires": ["E1", "T1"], "next": ("plan", "remediation"), "backward": True},
    },
    "verify": {
        "passed": {"requires": ["V1", "V2", "V3", "V4", "V5", "V7", "V8", "V10"], "next": ("iterate", "fresh"), "backward": False},
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
        "delivered": {"requires": ["D1", "D2", "D3", "D4", "D6", "D7", "D8"], "next": (None, "terminal"), "backward": False},
        "partially delivered": {"requires": ["D1", "D2", "D4", "D5", "D7", "D8"], "next": (None, "terminal"), "backward": False},
        "delivery blocked": {"requires": ["D4"], "next": ("deliver", "remediation"), "backward": False, "pause": True},
    },
    "debug": {
        # Not runnable until M4 (run_entry refuses "debug"); the checks exist now so
        # postconditions.py needs no rework when the entry lands.
        "reproduced": {"requires": ["B1", "B2", "S1", "S2", "S3", "P1", "P2", "P3", "P4", "P5", "P6", "P7", "P8"], "next": ("execute", "fresh"), "backward": False},
        "blocked reproduction": {"requires": ["B3"], "next": ("debug", "remediation"), "backward": False, "pause": True},
    },
    # 7.3.0: an auto run's first phase. "routed" hands the run to the chosen entry
    # (controller._hand_off), so its next phase is named by the product, not here.
    "route": {
        "routed": {"requires": ["A1", "A2"], "next": (None, "routed"), "backward": False},
    },
    "direct": {
        "done": {"requires": ["X1", "X2"], "next": (None, "terminal"), "backward": False},
        "incomplete": {"requires": ["X1"], "next": (None, "terminal"), "backward": False},
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
    # A no-change head is the start commit: the base, or an adopted PR's head (E9).
    return next(iter(store.state["products"]["execute"]["product"]["heads"].values()))


def verified_heads(store) -> dict[str, str]:
    # LF-28: EXECUTE's own product always carries a head per repo it initialized,
    # touched or not (an untouched repo's head is its start commit -- execute.py
    # only ever moves a repo's head when one of its tasks lands).
    return store.state["products"]["execute"]["product"]["heads"]


def start_sha(state: dict, repo_name: str) -> str:
    """The commit a repo's work starts from: an adopted PR's head in its own repo, else
    the repo's base. PLAN reads code there and E9 judges "no change" from it."""
    adoption = state.get("adoption") or {}
    return adoption["headSha"] if adoption.get("repo") == repo_name else state["repos"][repo_name]["baseSha"]


# LF-52/4.8: a plan task's identity, for EXECUTE's plan reconciliation and for
# deciding whether a reviser's carried-forward task is still the delivered one.
PLAN_IDENTITY_FIELDS = ("title", "files", "repo", "verify", "criteria", "dependsOn", "featureAdded", "mustFlip")


def adoptable_task_ids(state: dict, plan_tasks: list[dict]) -> set[str]:
    """LF-38: the plan tasks the adopted PR already delivered. Each matches the
    delivering run's prior plan task field for field and lives in the adopted repo
    (a workspace's other repos have no adopted commits). EXECUTE marks them
    `adopted`; the controller runs the adopted-range review only when one exists."""
    adoption = state.get("adoption") or {}
    prior_plan = (adoption.get("prior") or {}).get("plan")
    if not prior_plan:
        return set()
    prior = {t["id"]: t for t in prior_plan["tasks"]}
    return {t["id"] for t in plan_tasks
            if t["id"] in prior and t["repo"] == adoption.get("repo")
            and all(t.get(f) == prior[t["id"]].get(f) for f in PLAN_IDENTITY_FIELDS)}


def adopted_commits(store, repo_name: str, repo_path: Path) -> set[str]:
    """The adopted PR's commits (adoption.baseSha..headSha) when this run adopted one
    in `repo_name`; empty otherwise. E4 and EXECUTE's unmapped-commits pause both
    treat them as already accounted for (LF-44)."""
    adoption = store.state.get("adoption")
    if not adoption or adoption.get("repo") != repo_name:
        return set()
    return set(repo_module.commits_between(repo_path, adoption["baseSha"], adoption["headSha"]))


def ran_default(store, phase: str) -> bool:
    """D4: a product field that names evidence (a step id, a retry count, the signals a
    reviewer was shown) is read only when the phase ran its default implementation; an
    external product cannot vouch for its own evidence. Same test as review_evidence's."""
    return store.state["implementations"]["phases"].get(phase) != "external"


def review_evidence(store, task: dict) -> tuple[str, str | None]:
    """The evidence level and step id for one EXECUTE task's review: E6 and
    result.py's `reviewed` field both need this. An external EXECUTE's whole
    product is one human-attested submission with no per-task review step; the
    default implementation instead runs one, whose own submission (steps.submit's
    evidence-level judgment) is the real evidence, and its id names it."""
    if store.state["implementations"]["phases"].get("execute") == "external":
        return "human-attested", None
    if task.get("disposition") == "adopted":
        # LF-42: an adopted task never had a review step of its own; the adopted
        # range review (issued before EXECUTE's first attempt) is its evidence.
        step_id = store.state["phase"].get("adoptedReviewStepId")
        if step_id is None:
            return "unattested", None
        return store.state["steps"]["submissions"].get(step_id, {}).get("evidenceLevel", "unattested"), step_id
    review_steps = (task.get("steps") or {}).get("review") or []
    if not review_steps:
        return "unattested", None
    step_id = review_steps[-1]
    # The level is the core's record of that step's submission, so a product cannot
    # claim more than its step earned; an unknown id reads as unattested.
    level = store.state["steps"]["submissions"].get(step_id, {}).get("evidenceLevel", "unattested")
    return level, step_id


_CLOSE_OUT_ID = re.compile(r"C-\d+")


def close_outs(store) -> dict[str, dict]:
    """LF-55: the close-out registry, by id in registration order. The controller
    registers one entry per `execute` gap of each accepted ITERATE rewind and is the
    only writer of an entry's status; an EXECUTE product must disposition every one."""
    return {e["id"]: e for e in store.state.get("closeOuts") or []}


def close_out_view(entry: dict) -> dict:
    """The obligation a close-out's review is bound to. The default EXECUTE passes
    this as the review's `closeOut` input, and E6 finds its exact rendering in the
    attested prompt, so a review issued for another obligation never closes this one."""
    return {"id": entry["id"], "text": entry["text"], "repo": entry["repo"], "source": entry["source"]}


def task_repos(store) -> dict[str, str]:
    """Each EXECUTE task id's repo: a plan task's from PLAN, a close-out's from the registry."""
    repos = {t["id"]: t["repo"] for t in store.state["products"]["plan"]["product"]["tasks"]}
    repos.update({cid: e["repo"] for cid, e in close_outs(store).items()})
    return repos


def resolved_exceptions(store) -> set[str]:
    """The criteria VERIFY may skip re-running and re-checking, from PLAN's own
    declared exceptions plus any the operator approved this attempt. Shared by
    Boundary._exceptions (V4/V5) and controller._run_verify_reruns: R10 needs this
    resolved and consulted BEFORE a re-run is ever scheduled, not just checked
    afterward at Boundary time -- an approved non-repeatable command must never
    execute a second time to find out it was exempt."""
    plan_product = store.state["products"]["plan"]["product"]
    declared = {e["criterion"] for e in plan_product.get("evidenceExceptions", [])}
    operator = {e["criterion"] for e in (store.state.get("verifyExceptionsThisAttempt") or [])}
    return declared | operator


def _check_supersedes(store, findings: list[dict], repos: dict[str, Path]) -> str | None:
    ledger = store.state["ledger"]
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
        # LF-50: a finding carried forward from an open ledger entry (same id,
        # repo, location file) needs no supersedes -- it is not new content on
        # cleared code, it is the same finding still open.
        entry = ledger_module.carried_forward(store, finding, repo_name)
        if entry is not None and ledger_module.valid_update(entry, finding):
            continue
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
        from loop_spec.schema import load_schema, validate
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

    def _p3_form(self) -> str | None:
        # LF-53: commands run as argv with no shell; checked before any baseline run
        # (the controller's pre-capture gate calls this) and for featureAdded tasks,
        # whose verify command the baseline never runs.
        prepare = self.product.get("prepare")
        if prepare is not None and (why := baseline_module.shell_syntax(prepare)):
            return f"prepare command {why}; commands run as argv with no shell"
        for task in self.product["tasks"]:
            if why := baseline_module.shell_syntax(task["verify"]):
                return f"task {task['id']}: verify command {why}; commands run as argv with no shell"
        for check in self.product.get("checks") or []:
            if why := baseline_module.shell_syntax(check["command"]):
                return f"check {check['command']!r}: {why}; commands run as argv with no shell"
        return None

    def _p3(self) -> str | None:
        if (form := self._p3_form()) is not None:
            return form
        # R3: each task's own repo has its own baseline entries -- a task's verify
        # command is only ever looked up against the repo it actually names.
        baseline_state = self.store.state.get("baseline")
        repos = self._repo_entries()
        for task in self.product["tasks"]:
            repo_dict = baseline_module.repo_baseline_dict(baseline_state, task["repo"], repos)
            entries = (repo_dict or {}).get("entries", {})
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
        for check in self.product.get("checks") or []:
            repo_dict = baseline_module.repo_baseline_dict(baseline_state, check["repo"], repos)
            entry = (repo_dict or {}).get("entries", {}).get(check["command"])
            if entry is None or entry.get("status") != "ran" or entry.get("run") is None:
                return f"check {check['command']!r} in {check['repo']}: no baseline run"
            if entry["run"].get("errorClass") is not None or entry["run"].get("exitStatus") == 127:
                return f"check {check['command']!r} in {check['repo']}: its baseline run failed to execute"
        return None

    def _p4(self) -> str | None:
        # R3: every repo the plan's own tasks touch needs its own baseline, at
        # its own base SHA, with its own prepare/environment-health facts -- not
        # only the workspace's first repo.
        baseline_state = self.store.state.get("baseline")
        if baseline_state is None:
            return "no baseline captured"
        repos = self._repo_entries()
        health = self.store.state.get("environmentHealth") or {}
        touched_repos = {t["repo"] for t in self.product["tasks"]}
        for repo_name in touched_repos:
            repo_info = repos.get(repo_name)
            if repo_info is None:
                return f"no repo resolved to capture a baseline against for {repo_name!r}"
            repo_dict = baseline_module.repo_baseline_dict(baseline_state, repo_name, repos)
            if repo_dict is None:
                return f"no baseline captured for repo {repo_name!r}"
            if repo_dict.get("baseSha") != repo_info.get("baseSha"):
                return f"baseline for repo {repo_name!r} was captured at a different base SHA"
            if repo_dict.get("prepare") != self.product.get("prepare"):
                return f"baseline for repo {repo_name!r}: prepare command does not match the plan's"
            prepare_run = repo_dict.get("prepareRun")
            if prepare_run is not None and prepare_run.get("exitStatus") != 0:
                return f"baseline for repo {repo_name!r}: prepare command failed"
            repo_health = health.get(repo_name, {})
            for entry in repo_dict.get("entries", {}).values():
                run = entry.get("run")
                if run and run.get("errorClass") is not None and entry["command"] not in repo_health:
                    return f"repo {repo_name!r} baseline command {entry['command']!r} failed with no recorded environment health"
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
        # 7.1.0: a repo check runs in a repo some task changes, once per (repo, command),
        # and never shares a command with a featureAdded task there (the baseline keys a
        # command once: it cannot both run at base and have no base run).
        task_repos = {t["repo"] for t in self.product["tasks"]}
        feature_added = {(t["repo"], t["verify"]) for t in self.product["tasks"] if t.get("featureAdded")}
        seen = set()
        for check in self.product.get("checks") or []:
            key = (check["repo"], check["command"])
            if check["repo"] not in task_repos:
                return f"check {check['command']!r} names repo {check['repo']!r}, which no task changes"
            if key in seen:
                return f"check {check['command']!r} is listed twice for repo {check['repo']!r}"
            if key in feature_added:
                return f"check {check['command']!r} is also a featureAdded task's verify command; use a different command for the check"
            seen.add(key)
        return None

    def _p8(self) -> str | None:
        # 7.2.0: the program checks the facts of each existing-code entry (repo, tasks,
        # cites that resolve); whether reuse was the right call is the critic's.
        repos = self._repo_entries()
        task_ids = {t["id"] for t in self.product["tasks"]}
        # A re-plan after EXECUTE also resolves cites at the heads EXECUTE published.
        execute_heads = ((self.store.state["products"].get("execute") or {}).get("product") or {}).get("heads") or {}
        for entry in self.product.get("existingCode") or []:
            if entry["repo"] not in repos:
                return f"existingCode {entry['concept']!r} names an unknown repo {entry['repo']!r}"
            unknown = [t for t in entry["tasks"] if t not in task_ids]
            if unknown:
                return f"existingCode {entry['concept']!r} names tasks not in the plan: {', '.join(unknown)}"
            if entry["decision"] != "new" and not entry["cites"]:
                return f"existingCode {entry['concept']!r} is {entry['decision']} but cites no code"
            info = repos[entry["repo"]]
            shas = [start_sha(self.store.state, entry["repo"])]
            if execute_heads.get(entry["repo"]):
                shas.append(execute_heads[entry["repo"]])  # code an earlier task of this run added
            for cite in entry["cites"]:
                first, last = (int(n) for n in cite["lines"].split("-"))
                texts = [shown.stdout for sha in shas
                         if (shown := repo_module._git(Path(info["path"]), "show", f"{sha}:{cite['path']}")).returncode == 0]
                if not texts:
                    return f"existingCode {entry['concept']!r} cites {cite['path']}, which does not exist at the repo's start commit"
                if not any(1 <= first <= last <= len(text.splitlines()) for text in texts):
                    return f"existingCode {entry['concept']!r} cites {cite['path']}:{cite['lines']}, outside the file"
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
        ids = [t["id"] for t in self.product["tasks"]]
        duplicate = next((tid for tid in ids if ids.count(tid) > 1), None)
        if duplicate:
            return f"task {duplicate} appears more than once in the EXECUTE product"
        registry = close_outs(self.store)
        unknown = next((tid for tid in ids if _CLOSE_OUT_ID.fullmatch(tid) and tid not in registry), None)
        if unknown:
            return f"task {unknown} is not a registered close-out"
        for cid, entry in registry.items():
            source = f"ITERATE {entry['source']['attemptId']} gap {entry['source']['gapIndex']}"
            task = by_id.get(cid)
            if task is None:
                return f"close-out {cid} (from {source}) has no disposition in the EXECUTE product"
            if task["disposition"] not in ("done", "already-satisfied"):
                return f"close-out {cid} (from {source}) is {task['disposition']}; only done or already-satisfied closes it"
            if (task["disposition"] == "done") != bool(task["commits"]):
                return f"close-out {cid} (from {source}): done needs commits and already-satisfied has none"
            closure = entry.get("closure")
            if closure is None:
                continue
            # A closure stays in every later product. A done one keeps its commits and
            # accepted review; a no-change one may carry a fresh review at a new head
            # (E6 binds it), since its old proof covered only the old head.
            if task["disposition"] != closure["disposition"] or task["commits"] != closure["commits"]:
                return f"close-out {cid} was closed as {closure['disposition']}; a later product must carry the same disposition and commits"
            review = task.get("review") or {}
            if closure["disposition"] == "done" and (review.get("reviewedRange"), review.get("verdict")) != (closure["reviewedRange"], closure["verdict"]):
                return f"close-out {cid}: its review is not the one its closure accepted"
        return None

    def _step_issued_at(self, step_id: str) -> str | None:
        path = self.paths.steps_dir / step_id / "step.json"
        return read_json(path).get("issuedAt") if path.is_file() else None

    def _e3_dispatch_ordering(self, steps_by_task: dict, task_id: str, dep_id: str) -> str | None:
        # An external EXECUTE product has no per-task dispatch timeline (execute.py
        # never ran), so there is nothing to order here beyond the disposition check
        # above; the default implementation publishes each task's step ids.
        task_steps = steps_by_task.get(task_id, {}).get("implement") or []
        dep_steps = steps_by_task.get(dep_id, {}).get("review") or steps_by_task.get(dep_id, {}).get("implement") or []
        if not task_steps or not dep_steps:
            return None
        submissions = self.store.state["steps"]["submissions"]
        task_started = self._step_issued_at(task_steps[0])
        dep_finished = submissions.get(dep_steps[-1], {}).get("submittedAt")
        if task_started is None:
            return f"task {task_id} names implement step {task_steps[0]}, which the program never issued"
        if dep_finished is None:
            return f"task {dep_id} names step {dep_steps[-1]}, which has no recorded submission"
        if task_started < dep_finished:
            return f"task {task_id} was dispatched before its dependency {dep_id} finished"
        return None

    def _e3(self) -> str | None:
        by_id = {t["id"]: t for t in self.product["tasks"]}
        plan_tasks = {t["id"]: t for t in self.store.state["products"]["plan"]["product"]["tasks"]}
        steps_by_task = ({t["id"]: t.get("steps") or {} for t in self.product["tasks"]}
                         if ran_default(self.store, "execute") else {})
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
                ordering_error = self._e3_dispatch_ordering(steps_by_task, task["id"], dep_id)
                if ordering_error:
                    return ordering_error
        return None

    def _e4(self) -> str | None:
        # A task's repo lives on the PLAN task; in a workspace, unioning every task's
        # commits against each repo's range rejected a correct two-repo product (LF-24).
        plan_repo = task_repos(self.store)
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
            # LF-44: in a revise run the adopted PR's own commits are covered by the
            # adoption (and its full-range review, E5), whether or not the reviser
            # carried the delivering plan's tasks forward to claim them.
            adopted = adopted_commits(self.store, name, repo_path)
            if task_commits - adopted != actual - adopted:
                return f"repo {name}: task commits do not exactly cover base..head"
        return None

    def _e5(self) -> str | None:
        repos = self._repo_entries()
        # The EXECUTE task schema carries no "repo" field (only PLAN's does), so
        # the repo name for each task comes from the matching PLAN task, same as _e3.
        repo_of = task_repos(self.store)
        for task in self.product["tasks"]:
            if task["disposition"] not in ("done", "adopted"):
                continue
            review = task.get("review")
            if review is None or review.get("verdict") != "pass":
                return f"task {task['id']} has no passing review"
            repo_path = Path(repos[repo_of[task["id"]]]["path"])
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
        registry = close_outs(self.store)
        for task in self.product["tasks"]:
            no_change_close_out = task["id"] in registry and task["disposition"] == "already-satisfied"
            if task["disposition"] not in ("done", "adopted") and not no_change_close_out:
                continue
            if no_change_close_out:
                failure = self._no_change_proof(registry[task["id"]], task, is_external)
                if failure:
                    return failure
            level, _ = review_evidence(self.store, task)
            if level in ACCEPTED_REVIEW_LEVELS or (level == "human-attested" and is_external):
                continue
            if level == "unattested" and accept_unattested:
                self.weakened_assurance.append({"kind": "evidence.review.accept", "value": "unattested", "task": task["id"]})
                continue
            self.unreviewed.append(task["id"])
        if self.unreviewed:
            return f"tasks with an unaccepted review evidence level: {', '.join(self.unreviewed)}"
        return None

    def _no_change_proof(self, entry: dict, task: dict, is_external: bool) -> str | None:
        # LF-55: an implementer's claim never closes a close-out. Its proof is a
        # passing review of the empty range at the head this product exits on,
        # issued for this obligation; a proof at an older head is stale.
        cid = entry["id"]
        review = task.get("review")
        if review is None or review.get("verdict") != "pass":
            return f"close-out {cid} is already-satisfied with no passing review"
        repo_path = Path(self._repo_entries()[entry["repo"]]["path"])
        head = self.product["heads"].get(entry["repo"])
        reviewed = review["reviewedRange"]
        shas = {repo_module.head_sha(repo_path, sha) for sha in (reviewed["from"], reviewed["to"], head) if sha}
        if head is None or len(shas) != 1:
            return f"close-out {cid}: its no-change review covers {reviewed['from'][:12]}..{reviewed['to'][:12]}, not the empty range at head {str(head)[:12]}"
        if is_external:
            return None
        _, step_id = review_evidence(self.store, task)
        step_path = self.paths.steps_dir / str(step_id) / "step.json"
        prompt = read_json(step_path).get("prompt", "") if step_id and step_path.is_file() else ""
        if render_json(close_out_view(entry)) not in prompt:
            return f"close-out {cid}: its review step was not issued for this close-out"
        return None

    def _e7(self) -> str | None:
        runs = self.store.state.get("executeRuns") or {}
        registry = close_outs(self.store)
        for task in self.product["tasks"]:
            # A close-out has no verify command; its review is its proof (LF-55).
            if task["disposition"] not in ("done", "adopted") or task["id"] in registry:
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
            if head and repo_module.commits_between(Path(info["path"]), start_sha(self.store.state, name), head):
                return f"repo {name} has commits since its start commit"
        for task in self.product["tasks"]:
            if task["disposition"] not in ("already-satisfied", "removed"):
                return f"task {task['id']} is not already-satisfied or removed on a no-change exit"
        return None

    def _e10(self) -> str | None:
        issues = self.product.get("issues") or []
        if not issues:
            return "no issues recorded for the blocked exit"
        has_permission_denied = any(_PERMISSION_DENIED_MARKER in i["text"] for i in issues)
        # A task that exhausted its own per-step retries is what E10 means by "up to
        # the per-step retry limit"; counting only the phase's product rejections made
        # a correctly blocked product re-run three empty attempts first (LF-40).
        step_retries_exhausted = ran_default(self.store, "execute") and any(
            i.get("retries", 0) > retry_limit() for i in issues
        )
        if (self.store.state["phase"].get("retries", 0) < retry_limit() and not has_permission_denied
                and not step_retries_exhausted):
            return f"blocked claimed before the retry limit ({retry_limit()}) or a permission-denied issue"
        return None

    def _e11(self) -> str | None:
        # 7.1.1: the signals are the ones the program probed on the task's own diff at
        # review time, close-outs included; the default EXECUTE publishes that set.
        if not ran_default(self.store, "execute"):
            return None
        for task in self.product["tasks"]:
            flagged = {signal["file"] for signal in task.get("securitySignals") or []}
            covered = {d["signal"] for d in (task.get("review") or {}).get("securityDispositions", [])}
            if not flagged <= covered:
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
        return resolved_exceptions(self.store)

    def _v4(self) -> str | None:
        exceptions = self._exceptions()
        runs = self.store.state.get("verifyRuns") or {}
        for verdict in self.product["verdicts"]:
            if verdict["verdict"] not in ("pass", "fail"):
                continue
            # LF-53: checked before the exception skip, so an evidence exception never
            # admits a command the no-shell runner would split wrongly.
            command = (verdict.get("evidence") or {}).get("command")
            if command is not None and (why := baseline_module.shell_syntax(command)):
                return f"criterion {verdict['criterion']}: evidence command {why}; commands run as argv with no shell"
            if verdict["criterion"] in exceptions:
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
        entries = baseline_module.all_baseline_entries(self.store.state.get("baseline"))
        runs = self.store.state.get("verifyRuns") or {}
        for verdict in self.product["verdicts"]:
            if verdict["verdict"] != "blocked":
                continue
            cause = verdict.get("cause") or ""
            observed = any((e.get("run") or {}).get("errorClass") for e in entries) or \
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
                # LF-47: a final pass reviews base..head in full, same as a first
                # pass -- its own "from" is the repo's base SHA, not the prior
                # entry's "to", and that is not a failure to continue from it.
                repo_info = self._repo_entries().get(repo, {})
                is_full_from_base = bool(reviewed_range.get("full")) and reviewed_range["from"] == repo_info.get("baseSha")
                if not is_full_from_base:
                    return f"repo {repo}: reviewed range does not continue from the last reviewed SHA"
        findings = ledger_module.effective_findings(self.store, self.product.get("findings", []), self._repo_paths())
        if any(f["severity"] == "Critical" and f["disposition"] == "open" for f in findings):
            return "a Critical finding is open"
        return None

    def _v8(self) -> str | None:
        return _check_supersedes(self.store, self.product.get("findings", []), self._repo_paths())

    def _v9(self) -> str | None:
        for verdict in self.product["verdicts"]:
            if verdict["verdict"] != "blocked" or not _OFFLINE_CAUSE.search(verdict.get("cause") or ""):
                continue
            if verdict["criterion"] not in (self.product.get("standInTried") or []):
                return f"criterion {verdict['criterion']}: offline cause claimed with no stand-in tried"
        return None

    def _v10(self) -> str | None:
        # 7.1.0: every plan repo check ran, by the program, at its repo's verified head
        # against the current plan and baseline, with no new diagnostic.
        records = self.store.state.get("checkRuns") or {}
        for check in repo_checks.plan_checks(self.store):
            key = repo_checks.current_key(self.store, check["repo"])
            record = (records.get(check["repo"]) or {}).get(check["command"])
            if key is None or record is None or any(record.get(k) != v for k, v in key.items()):
                return f"check {check['command']!r} in {check['repo']}: no program run at the verified head"
            comparison = record["comparison"]
            if comparison["verdict"] != "no-regression":
                return (f"check {check['command']!r} in {check['repo']} is {comparison['verdict']} at "
                        f"{key['head'][:12]}: {comparison['detail']}")
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
        repos = sorted(self.store.state.get("repos") or {})
        for i, gap in enumerate(self.product.get("gaps", [])):
            if gap["target"] not in ("spec", "plan", "execute", "verify"):
                return f"gap names an unknown target {gap['target']!r}"
            # LF-55: an execute gap becomes a close-out in one repo; never a guessed one.
            if gap["target"] == "execute":
                repo = gap.get("repo")
                if repo is not None and repo not in repos:
                    return f"gap {i} names an unknown repo {repo!r}; name one of {', '.join(repos)}"
                if repo is None and len(repos) != 1:
                    return f"gap {i} targets EXECUTE with no repo; name one of {', '.join(repos)}"
        return None

    def _i3(self) -> str | None:
        return None if budget_module.has_room(self.store) else "the rewind budget has no room"

    def _i4(self) -> str | None:
        rewind_refused = self.product.get("verdict") == "unmet" and not budget_module.has_room(self.store)
        unclosable_gap = self.product.get("verdict") == "unmet" and not self.product.get("gaps")
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
            if entry["deliveredSha"] != expected_head:
                return f"repo {entry['repo']}: deliveredSha is not the EXECUTE head"
            if self._observed_head(entry, repo_info) != remote_sha:
                return f"repo {entry['repo']}: the remote head is neither the verified SHA nor its accepted extension"
        return None

    def _observed_head(self, entry: dict, repo_info: dict) -> str | None:
        """The one head D1 and D2 both hold a delivered repo to: the verified SHA, or
        (7.1.0) the head of an accepted extension, recomputed now and equal in every
        recorded fact to what the product claims."""
        accepted = entry.get("acceptedRemote")
        if accepted is None:
            return entry["deliveredSha"]
        globs = (load_config(self.project_root).get("deliver") or {}).get("acceptRemotePaths") or []
        worktree = self.paths.feature_worktree(entry["repo"])
        where = worktree if worktree.is_dir() else Path(repo_info["path"])
        ext = repo_module.remote_extension(where, repo_info["featureBranch"], entry["deliveredSha"], repo_info["baseSha"], globs)
        if ext["state"] != "extension" or ext["refused"] or \
                {k: ext[k] for k in ("head", "commits", "paths")} != accepted:
            return None
        return ext["head"]

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
            observed = entry["deliveredSha"] if entry.get("acceptedRemote") is None else entry["acceptedRemote"]["head"]
            if data.get("state") != "OPEN" or data.get("headRefName") != entry["pr"]["headRef"] or \
               data.get("headRefOid") != observed or entry["pr"]["headSha"] != observed or data.get("baseRefName") != base:
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
        if self.store.state["products"]["execute"]["exit"] != "no change":
            return None
        adoption = self.store.state.get("adoption") or {}
        heads = verified_heads(self.store)
        for entry in self.product["repos"]:
            if entry["state"] != "skipped" or entry.get("deliveredSha") is not None:
                return f"repo {entry['repo']}: a no-change head must be skipped with nothing delivered"
            pr = entry.get("pr")
            if pr is None:
                continue
            if entry["repo"] != adoption.get("repo") or pr["number"] != adoption.get("number") \
                    or pr["headSha"] != heads.get(entry["repo"]):
                return f"repo {entry['repo']}: a no-change row names a PR only for the adopted PR at the verified head"
            # The same read D2 makes: the PR must still be open at the head VERIFY saw.
            code, out, err = repo_module.run_gh(Path(self._repo_entries()[entry["repo"]]["path"]), "pr", "view",
                                                str(pr["number"]), "--json", "state,headRefOid")
            if code != 0:
                return f"repo {entry['repo']}: gh pr view failed: {err.strip() or code}"
            data = json.loads(out)
            if data.get("state") != "OPEN" or data.get("headRefOid") != pr["headSha"]:
                return (f"repo {entry['repo']}: PR #{pr['number']} is no longer open at the verified head "
                        f"{pr['headSha'][:12]}; stop and re-run the entry to adopt its current head")
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

    def _d8(self) -> str | None:
        # R6: D1/D2/D3/D7 all silently skip a row that is not "state: delivered"
        # (D2 further skips a delivered row with no PR) -- a product can report a
        # touched, committed repo as "skipped" with a null PR and every other D
        # check falls quiet. This is the one check that looks at what EXECUTE
        # actually touched and refuses a DELIVER product that hides or duplicates
        # any of it.
        plan_repo = task_repos(self.store)
        execute_tasks = self.store.state["products"]["execute"]["product"]["tasks"]
        required = {
            plan_repo[t["id"]] for t in execute_tasks
            if t["disposition"] in ("done", "adopted") and t["commits"] and t["id"] in plan_repo
        }
        seen: dict[str, dict] = {}
        for entry in self.product["repos"]:
            if entry["repo"] in seen:
                return f"repo {entry['repo']}: appears more than once in DELIVER's repos"
            seen[entry["repo"]] = entry
        missing = required - seen.keys()
        if missing:
            return f"repo {sorted(missing)[0]}: touched by EXECUTE but missing from DELIVER's repos"
        for name, entry in seen.items():
            if name in required and entry["state"] == "skipped":
                return f"repo {name}: touched by EXECUTE but reported skipped"
            if entry["state"] == "delivered" and entry.get("pr") is None:
                return f"repo {name}: delivered with no PR"
        if self.exit == "delivered":
            for name in required:
                if seen[name]["state"] != "delivered":
                    return f"repo {name}: touched by EXECUTE but not delivered"
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

    def _b1_form(self) -> str | None:
        reproduction = self.product.get("reproduction")
        why = reproduction is not None and baseline_module.shell_syntax(reproduction["command"])
        return f"reproduction command {why}; commands run as argv with no shell" if why else None

    def _b2_form(self) -> str | None:
        original = self.product.get("original")
        why = original is not None and baseline_module.shell_syntax(original["command"])
        return f"original command {why}; commands run as argv with no shell" if why else None

    def _b1(self) -> str | None:
        if (form := self._b1_form()) is not None:
            return form
        return self._reproduction_run_holds((self.store.state.get("debugRuns") or {}).get("baseRun"))

    def _b2(self) -> str | None:
        if self.product.get("original") is None:
            return None
        if (form := self._b2_form()) is not None:
            return form
        if not self.product["reproduction"].get("reason"):
            return "a changed reproduction needs a stated reason"
        return self._reproduction_run_holds((self.store.state.get("debugRuns") or {}).get("originalRun"))

    def _b3(self) -> str | None:
        if self.product.get("reproduction") is not None:
            return "a reproduction exists; blocked reproduction forbids one"
        return None

    # -- A: ROUTE (7.3.0) -------------------------------------------------

    def _route_facts(self) -> list[dict]:
        return (self.store.state.get("routeFacts") or {}).get("prRefs") or []

    def _a1(self) -> str | None:
        from loop_spec.entries import ROUTABLE
        if self.product["entry"] not in ROUTABLE:
            return f"route-refused:unknown-entry: {self.product['entry']!r} is not one of {', '.join(ROUTABLE)}"
        return None

    def _a2(self) -> str | None:
        from loop_spec.entries import ENTRIES
        entry, pr = ENTRIES.get(self.product["entry"]), self.product["pr"]
        if entry is None:
            return None  # A1's refusal
        matches = [r for r in self._route_facts() if r["adoptable"] and r["number"] == pr]
        if entry.takes == "pr" and not matches:
            return f"route-refused:pr-not-adoptable: {entry.name} needs a PR the request names and the program could adopt; #{pr} is not one"
        if entry.takes == "request" and pr is not None and not matches:
            return f"route-refused:pr-not-named: #{pr} is not an adoptable PR the request names"
        if len({r["repo"] for r in matches}) > 1:
            return f"route-refused:pr-ambiguous: #{pr} is open in more than one workspace repository"
        return None

    # -- X: DIRECT (7.3.0) ------------------------------------------------

    def _x1(self) -> str | None:
        errors = self._validates()
        return "; ".join(errors) if errors else None

    def _x2(self) -> str | None:
        repos = self._repo_paths()
        for action in self.product["actions"]:
            if action["kind"] not in ("push", "pr"):
                continue
            path = repos.get(action["repo"] or "")
            if path is None or not action["sha"]:
                return f"a {action['kind']} action must name a workspace repo and its SHA: {action['detail']}"
            if action["kind"] == "push":
                if not action["ref"]:
                    return f"a push action must name its branch: {action['detail']}"
                remote = repo_module.remote_head(path, "origin", action["ref"])
                if remote != action["sha"]:
                    return f"origin/{action['ref']} is at {(remote or 'nothing')[:12]}, not the claimed push {action['sha'][:12]}"
            else:
                if not action["url"]:
                    return f"a pr action must name the PR's URL: {action['detail']}"
                code, out, err = repo_module.run_gh(path, "pr", "view", action["url"], "--json", "headRefOid")
                head = json.loads(out).get("headRefOid") if code == 0 else None
                if head != action["sha"]:
                    return f"PR {action['url']} head is {(head or err.strip() or 'unreadable')[:40]}, not the claimed {action['sha'][:12]}"
        return None

    # -- T1: shared budget -----------------------------------------------

    def _t1(self) -> str | None:
        return None if budget_module.has_room(self.store) else "the rewind budget has no room"
