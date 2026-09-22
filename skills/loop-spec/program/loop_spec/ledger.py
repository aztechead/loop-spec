"""The review ledger (`store.state["ledger"]`): reviewed ranges and findings that
persist across VERIFY passes.

Use `record_range`/`record_findings` when a VERIFY product is accepted (any exit),
`open_findings`/`cleared_files` to answer what the next pass needs (V7/V8 read the
same ledger these write), and `disposition` when an operator or a later pass closes
a finding. Nothing here decides a route or an exit; `postconditions.py` reads this
ledger to check one.
"""
from pathlib import Path

from . import repo as repo_module
from .errors import LoopSpecError
from .ids import new_id


def record_range(store, *, from_sha: str, to_sha: str, full: bool, sha: str, by_step: str) -> str:
    range_id = new_id("range")
    store.state["ledger"]["reviewedRanges"].append({
        "id": range_id, "from": from_sha, "to": to_sha, "full": full, "sha": sha, "byStep": by_step,
    })
    store.save()
    return range_id


def record_findings(store, findings: list[dict], *, sha: str, range_id: str) -> None:
    for finding in findings:
        store.state["ledger"]["findings"].append({**finding, "sha": sha, "rangeId": range_id})
    store.save()


def open_findings(store) -> list[dict]:
    return [f for f in store.state["ledger"]["findings"] if f["disposition"] == "open"]


def cleared_files(store, repo: Path) -> set[str]:
    touched: set[str] = set()
    for reviewed_range in store.state["ledger"]["reviewedRanges"]:
        out = repo_module.run_git(repo, "diff", "--name-only", f"{reviewed_range['from']}..{reviewed_range['to']}")
        touched.update(line for line in out.splitlines() if line)
    return touched


def disposition(store, finding_id: str, disposition_value: str, reason: str | None) -> None:
    finding = next((f for f in store.state["ledger"]["findings"] if f["id"] == finding_id), None)
    if finding is None:
        raise LoopSpecError(f"no ledger finding {finding_id}", repair="check `loop-spec status` for open findings")
    finding["disposition"] = disposition_value
    finding["reason"] = reason
    store.save()
