"""The review ledger (`store.state["ledger"]`): reviewed ranges and findings that
persist across VERIFY passes.

Use `record_range`/`record_findings` when a VERIFY product is accepted (any exit),
`open_findings`/`cleared_files` to answer what the next pass needs (V7/V8 read the
same ledger these write), and `disposition` when an operator or a later pass closes
a finding. Nothing here decides a route or an exit; `postconditions.py` reads this
ledger to check one.
"""
from pathlib import Path

from loop_spec import repo as repo_module
from loop_spec.errors import LoopSpecError
from loop_spec.ids import new_id, now_iso

_CLOSING = {"fixed", "rejected"}


def carried_forward(store, finding: dict, repo: str | None) -> dict | None:
    """The open ledger finding this reviewer finding repeats: same id, same repo, same
    location file path. Range ids never match (they never appear in `findings`)."""
    path = (finding.get("location") or "").split(":", 1)[0]
    for entry in store.state["ledger"]["findings"]:
        if entry["id"] == finding.get("id") and entry["disposition"] == "open" and entry.get("repo") == repo \
                and (entry.get("location") or "").split(":", 1)[0] == path:
            return entry
    return None


def valid_update(entry: dict, finding: dict) -> bool:
    """A carried-forward finding may stay open or close as fixed/rejected with a
    non-empty reason. Anything else is not a valid update."""
    d = finding.get("disposition")
    return d == "open" or (d in _CLOSING and bool((finding.get("reason") or "").strip()))


def effective_findings(store, product_findings: list[dict], repos: dict) -> list[dict]:
    """The ledger with the product's valid same-finding updates overlaid (virtually),
    plus the product's other findings. V7 reads this; nothing is written here."""
    single = next(iter(repos)) if len(repos) == 1 else None
    overlay: dict[str, dict] = {}
    extra: list[dict] = []
    for finding in product_findings:
        entry = carried_forward(store, finding, finding.get("repo") or single)
        if entry is not None and valid_update(entry, finding):
            overlay[entry["id"]] = {**entry, "disposition": finding["disposition"], "reason": finding.get("reason")}
        elif entry is None:
            extra.append(finding)
    return [overlay.get(e["id"], e) for e in store.state["ledger"]["findings"]] + extra


def record_range(store, *, repo: str, from_sha: str, to_sha: str, full: bool, sha: str, by_step: str | None,
                 reused_from: str | None = None) -> str:
    range_id = new_id("range")
    entry = {"id": range_id, "repo": repo, "from": from_sha, "to": to_sha, "full": full, "sha": sha, "byStep": by_step}
    if reused_from is not None:
        entry["reusedFrom"] = reused_from
    store.state["ledger"]["reviewedRanges"].append(entry)
    store.save()
    return range_id


def closed_echo(store, finding: dict, repo: str | None) -> dict | None:
    """A finding that repeats an already-closed ledger entry (same id, repo, location
    file, disposition) -- e.g. a caller that bypasses verify.py's own echo drop and
    reports a closed finding again. Not carried forward (carried_forward is open-only);
    recording it again would duplicate a settled entry rather than observe it."""
    path = (finding.get("location") or "").split(":", 1)[0]
    return next(
        (e for e in store.state["ledger"]["findings"]
         if e["id"] == finding.get("id") and e["disposition"] != "open" and e["disposition"] == finding.get("disposition")
         and e.get("repo") == repo and (e.get("location") or "").split(":", 1)[0] == path),
        None,
    )


def record_findings(store, findings: list[dict], *, sha: str, range_id: str) -> None:
    for finding in findings:
        entry = carried_forward(store, finding, finding.get("repo"))
        if entry is not None:
            entry.setdefault("observations", []).append(
                {"sha": sha, "rangeId": range_id, "at": now_iso(), "cause": finding.get("cause")})
            if valid_update(entry, finding) and finding.get("disposition") in _CLOSING:
                entry["disposition"] = finding["disposition"]
                entry["reason"] = finding.get("reason")
            continue
        if closed_echo(store, finding, finding.get("repo")) is not None:
            continue
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
