"""Terminal result: the schema-1 record every full/micro run ends with.

Use `write` whenever the controller reaches a terminal classification (converged,
converged-with-caveats, no-change, escalated, failed) or a pause (`paused`, which
writes the result file for the operator to read but leaves `state.result` unset so
the run is still resumable after the answer).
"""
import shutil
import subprocess
from pathlib import Path

from loop_spec import VERSION
from loop_spec.events import marker_result
from loop_spec.ids import now_iso
from loop_spec.jsonio import atomic_write_json
from loop_spec.postconditions import bound_ok, review_evidence, verified_head
from loop_spec.schema import validate_or_raise

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


def _verification_status(store) -> str:
    # R7: independent of the run's classification -- VERIFY can pass on a run that
    # later escalates in ITERATE, and a converged run's VERIFY entry can be stale
    # relative to what actually got delivered after a rewind.
    verify_entry = store.state["products"].get("verify")
    if verify_entry is None:
        return "not-run"
    if verify_entry["exit"] == "passed" and bound_ok(verify_entry["product"], store, "verify") is None:
        return "passed"
    return "failed"


def _outstanding(store) -> list[str]:
    # Same computation as render.py's pr_body "Outstanding" section: every open
    # ledger finding plus every gap ITERATE never closed.
    open_findings = [f["id"] for f in store.state["ledger"]["findings"] if f["disposition"] == "open"]
    iterate_product = (store.state["products"].get("iterate") or {}).get("product") or {}
    unmet_gaps = [gap["text"] for gap in iterate_product.get("gaps", [])]
    return open_findings + unmet_gaps


def write(store, paths, classification: str, *, reason: str | None = None, summary: str | None = None,
          partially_delivered: bool = False) -> Path:
    run = store.state["run"]
    repos = store.state.get("repos") or {}
    first_repo = next(iter(repos.values()), None)
    execute_entry = store.state["products"].get("execute")
    deliver_entry = store.state["products"].get("deliver")

    # R7: `converged` is true only for a result 6.9 would also have called
    # converged -- a draft left for human sign-off (converged-with-caveats) is not
    # that, whatever its own workDelivered value.
    converged = classification in ("converged", "no-change")

    pr_url, prs, delivery = None, [], None
    if deliver_entry is not None:
        delivery = {"targets": deliver_entry["product"].get("repos", [])}
        for entry in delivery["targets"]:
            if entry.get("pr"):
                prs.append({"repo": entry["repo"], "number": entry["pr"]["number"], "url": entry["pr"]["url"]})
                if entry.get("state") == "delivered":
                    pr_url = pr_url or entry["pr"]["url"]

    # workDelivered is a delivery fact, not a label: true whenever any target
    # actually reached "delivered", including a partial draft on an escalated run.
    work_delivered = any(entry.get("state") == "delivered" for entry in delivery["targets"]) if delivery else False
    # LF-58: any route to a terminal result (a stop after a partial DELIVER, too)
    # reports partial publication from the per-repo facts, not the caller's flag alone.
    if work_delivered and any(entry.get("state") == "failed" for entry in delivery["targets"]):
        partially_delivered = True

    warnings = [f.get("cause") or f.get("id", "") for f in store.state["ledger"]["findings"] if f.get("disposition") in ("deferred", "open")]

    # A workspace's several repos have no single "the" verified SHA; only a
    # single-repo run's head means anything as one value.
    verified_sha = None
    if execute_entry is not None and len(repos) == 1:
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
            "status": _verification_status(store),
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
        "reviewed": {t: {"level": level, "stepId": step_id}
                     for t in _accepted_tasks(execute_entry)
                     for level, step_id in [review_evidence(store, t)]},
        "unreviewed": store.state.get("unreviewed", []),
        "outstanding": _outstanding(store),
        "blocked": [],
        "partiallyDelivered": partially_delivered,
        "weakenedAssurance": store.state.get("weakenedAssurance", []) + store.state.get("attestationWaivers", []),
        "cleanupBacklog": store.state["steps"]["quarantined"] + store.state.get("cleanupBacklog", []),
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
