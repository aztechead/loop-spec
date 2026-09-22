"""Terminal result: the schema-1 record every full/micro run ends with.

Use `write` whenever the controller reaches a terminal classification (converged,
converged-with-caveats, no-change, escalated, failed) or a pause (`paused`, which
writes the result file for the operator to read but leaves `state.result` unset so
the run is still resumable after the answer).
"""
import shutil
import subprocess
from pathlib import Path

from . import VERSION
from .events import marker_result
from .ids import now_iso
from .jsonio import atomic_write_json
from .schema import validate_or_raise

_STATUS = {
    "converged": "completed", "converged-with-caveats": "completed", "no-change": "completed",
    "escalated": "escalated", "failed": "failed", "paused": "paused",
}
_OUTCOME = {
    "converged": "delivered", "converged-with-caveats": "delivered-draft", "no-change": "no-change-needed",
    "escalated": "escalated", "failed": "failed", "paused": "paused",
}


def _host_versions() -> dict:
    versions = {}
    for name, args in (("claude", ["claude", "--version"]), ("python3", ["python3", "--version"]), ("git", ["git", "--version"])):
        if shutil.which(args[0]) is None:
            versions[name] = None
            continue
        try:
            proc = subprocess.run(args, capture_output=True, text=True, timeout=10, check=False)
            versions[name] = (proc.stdout or proc.stderr).strip() or None
        except (OSError, subprocess.TimeoutExpired):
            versions[name] = None
    return versions


def _accepted_tasks(execute_entry: dict | None) -> list[str]:
    if execute_entry is None:
        return []
    return [t["id"] for t in execute_entry["product"]["tasks"] if t["disposition"] in ("done", "adopted")]


def write(store, paths, classification: str, *, reason: str | None = None, summary: str | None = None,
          partially_delivered: bool = False) -> Path:
    run = store.state["run"]
    repos = store.state.get("repos") or {}
    first_repo = next(iter(repos.values()), None)
    execute_entry = store.state["products"].get("execute")
    deliver_entry = store.state["products"].get("deliver")

    converged = classification in ("converged", "converged-with-caveats", "no-change")
    work_delivered = converged and classification != "no-change"

    pr_url, prs, delivery = None, [], None
    if deliver_entry is not None:
        delivery = deliver_entry["product"]
        for entry in delivery.get("repos", []):
            if entry.get("pr"):
                prs.append({"repo": entry["repo"], "number": entry["pr"]["number"], "url": entry["pr"]["url"]})
                pr_url = pr_url or entry["pr"]["url"]

    warnings = [f.get("cause") or f.get("id", "") for f in store.state["ledger"]["findings"] if f.get("disposition") in ("deferred", "open")]

    verified_sha = None
    if execute_entry is not None:
        from .postconditions import verified_head
        verified_sha = verified_head(store)

    request_text = store.state["request"]["text"] or ""
    record = {
        "schema": 1,
        "loopSpecVersion": VERSION,
        "cycleType": run.get("cycleType"),
        "slug": run.get("slug"),
        "status": _STATUS[classification],
        "outcome": _OUTCOME[classification],
        "reason": reason,
        "summary": summary or f"{run.get('cycleType', 'run')} {classification} at {store.state['phase']['current']}",
        "noChangeReason": "already-satisfied" if classification == "no-change" else None,
        "phaseReached": store.state["phase"]["current"],
        "branch": first_repo["featureBranch"] if first_repo else None,
        "baseBranch": first_repo["defaultBranch"] if first_repo else None,
        "prUrl": pr_url,
        "checkpointPrUrl": None,
        "delivery": delivery,
        "converged": converged,
        "workDelivered": work_delivered,
        "iterations": {"used": store.state["budget"]["spent"], "max": store.state["budget"]["limit"]},
        "warnings": warnings,
        "autonomous": store.state["questions"].get("policy") == "default",
        "feature_title": request_text.splitlines()[0] if request_text else "",
        "createdAt": run.get("createdAt"),
        "finishedAt": now_iso(),
        "verification": {
            "status": "passed" if converged else "not-run",
            "command": None,
        },
        "implementationConverged": converged,
        "eligibleTargets": [{"branch": info["featureBranch"], "targetSha": verified_sha} for info in repos.values()] if verified_sha else [],
        "retryable": classification == "failed",
        "retryPhase": store.state["phase"]["current"] if classification == "failed" else None,
        "verifiedSha": verified_sha,
        "result": classification,
        "rewinds": len(store.state["budget"]["transitions"]),
        "prs": prs,
        "reviewed": {t: execute_entry["evidenceLevel"] for t in _accepted_tasks(execute_entry)},
        "unreviewed": store.state.get("unreviewed", []),
        "outstanding": [],
        "blocked": [],
        "partiallyDelivered": partially_delivered,
        "weakenedAssurance": store.state.get("weakenedAssurance", []),
        "cleanupBacklog": store.state["steps"]["quarantined"],
        "implementations": store.state["implementations"],
        "policyAnsweredQuestions": store.state["questions"]["policyAnswered"],
        "hostVersions": _host_versions(),
    }
    validate_or_raise(record, "result")
    atomic_write_json(paths.result_json, record)
    if classification != "paused":
        # A pause is resumable: last-result.json must keep pointing at whatever the
        # PRIOR terminal run produced (or nothing), not this in-progress one.
        atomic_write_json(paths.last_result_json, record)
        store.state["result"] = {"classification": classification, "path": str(paths.result_json), "writtenAt": record["finishedAt"]}
    marker_result(paths, record)
    store.save()
    return paths.result_json
