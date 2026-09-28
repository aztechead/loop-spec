"""The plan's repo checks (lint, typecheck, format check) run by the program at each
repo's verified head (7.1.0).

Use `ensure_check_runs` wherever VERIFY needs them: default VERIFY before it prompts
the verifier (the runs are its input facts) and when it assembles its product, and the
controller before VERIFY's boundary check for every implementation (V10 reads only
these records). A record is reused only while its head, plan revision and baseline
capture all still match; otherwise the check runs again in a fresh checkout. This
module reports facts; `verify.py` turns a regression into a remediation and
`postconditions.py` checks V10.
"""
import uuid
from pathlib import Path

from loop_spec import baseline as baseline_module
from loop_spec import repo as repo_module


def plan_checks(store) -> list[dict]:
    plan = (store.state["products"].get("plan") or {}).get("product") or {}
    return list(plan.get("checks") or [])


def current_key(store, repo_name: str) -> dict | None:
    """What a check record for `repo_name` must match to stand for the current run."""
    execute = (store.state["products"].get("execute") or {}).get("product") or {}
    head = (execute.get("heads") or {}).get(repo_name)
    repo_baseline = baseline_module.repo_baseline_dict(store.state.get("baseline"), repo_name, store.state["repos"])
    if head is None or repo_baseline is None:
        return None
    return {"head": head, "planRevision": store.state["revisions"]["plan"], "baselineCapturedAt": repo_baseline["capturedAt"]}


def ensure_check_runs(store, paths) -> list[dict]:
    """Every plan check's current record, running what is missing or stale; returns
    the records as `{repo, command, head, comparison}` rows."""
    by_repo: dict[str, list[str]] = {}
    for check in plan_checks(store):
        by_repo.setdefault(check["repo"], []).append(check["command"])
    records = store.state.setdefault("checkRuns", {})
    prepare = store.state["products"]["plan"]["product"].get("prepare")
    changed = False
    for repo_name, commands in by_repo.items():
        key = current_key(store, repo_name)
        if key is None:
            continue
        repo_records = records.setdefault(repo_name, {})
        stale = [c for c in commands if {k: (repo_records.get(c) or {}).get(k) for k in key} != key]
        if not stale:
            continue
        repo_baseline = baseline_module.repo_baseline_dict(store.state.get("baseline"), repo_name, store.state["repos"])
        repo_path = Path(store.state["repos"][repo_name]["path"])
        # A fresh name per run: an interrupted run's leftover checkout is never reused.
        checkout = paths.checkouts_dir / f"check-{repo_name}-{key['head'][:12]}-{uuid.uuid4().hex[:8]}"
        repo_module.clean_checkout(repo_path, key["head"], checkout)
        try:
            if prepare:
                baseline_module.run_command(prepare, checkout, key["head"])
            for command in stale:
                run = baseline_module.run_command(command, checkout, key["head"])
                entry = baseline_module.BaselineEntry.from_dict(repo_baseline["entries"][command])
                comparison = baseline_module.compare_to_baseline(entry, run)
                repo_records[command] = {**key, "run": run.to_dict(), "comparison": comparison.to_dict()}
                changed = True
        finally:
            repo_module.remove_worktree(repo_path, checkout, force=True)
    if changed:
        store.save()
    return [{"repo": repo_name, "command": command, "head": records[repo_name][command]["head"],
             "comparison": records[repo_name][command]["comparison"], "run": records[repo_name][command]["run"]}
            for repo_name, commands in by_repo.items() for command in commands
            if command in records.get(repo_name, {})]
