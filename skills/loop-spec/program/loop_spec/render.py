"""Markdown rendering for DELIVER: the PR body and the three committed artifacts.

Use `pr_body` for the PR description GFM text, and `spec_md`/`plan_md`/
`verification_md` for the files `deliver.py` commits under `docs/loop-spec/<slug>/`
when `.loop-spec/config.json` sets `commitArtifacts: true`. Every function reads
`store.state["products"]` and the ledger; none of them mutate anything.
"""
from . import VERSION


def spec_md(store) -> str:
    spec = store.state["products"]["spec"]["product"]
    lines = [f"# {spec['goal']}", ""]
    if spec["boundaries"]:
        lines += ["## Boundaries", ""]
        lines += [f"- {b}" for b in spec["boundaries"]]
        lines.append("")
    lines += ["## Acceptance criteria", ""]
    lines += [f"- **{c['id']}**: {c['text']}" for c in spec["criteria"]]
    if spec["decisions"]:
        lines += ["", "## Decisions", ""]
        lines += [f"- **{d['id']}**: {d['text']}" for d in spec["decisions"]]
    if spec["openQuestions"]:
        lines += ["", "## Open questions", ""]
        lines += [f"- **{q['id']}**: {q['text']}" for q in spec["openQuestions"]]
    return "\n".join(lines) + "\n"


def plan_md(store) -> str:
    plan = store.state["products"]["plan"]["product"]
    lines = ["# Plan", "", "| Task | Title | Verify | Criteria |", "| --- | --- | --- | --- |"]
    for task in plan["tasks"]:
        lines.append(f"| {task['id']} | {task['title']} | `{task['verify']}` | {', '.join(task['criteria'])} |")
    return "\n".join(lines) + "\n"


def _acceptance_table(verify_product: dict) -> list[str]:
    lines = ["| Criterion | Verdict | Command | SHA |", "| --- | --- | --- | --- |"]
    for verdict in verify_product["verdicts"]:
        evidence = verdict["evidence"] or {}
        lines.append(f"| {verdict['criterion']} | {verdict['verdict']} | "
                     f"`{evidence.get('command', '')}` | {evidence.get('sha', '')} |")
    return lines


def verification_md(store) -> str:
    verify_product = store.state["products"]["verify"]["product"]
    lines = ["# Verification", ""] + _acceptance_table(verify_product)
    findings = store.state["ledger"]["findings"]
    if findings:
        lines += ["", "## Findings", "", "| ID | Severity | Disposition | Cause |", "| --- | --- | --- | --- |"]
        lines += [f"| {f['id']} | {f['severity']} | {f['disposition']} | {f['cause']} |" for f in findings]
    return "\n".join(lines) + "\n"


def pr_body(store) -> str:
    spec = store.state["products"]["spec"]["product"]
    verify_product = store.state["products"]["verify"]["product"]
    findings = store.state["ledger"]["findings"]

    lines = [f"## {spec['goal']}", ""]
    if spec["boundaries"]:
        lines += ["### Boundaries", ""] + [f"- {b}" for b in spec["boundaries"]] + [""]
    lines += ["### Acceptance", ""] + _acceptance_table(verify_product) + [""]

    if findings:
        lines += ["### Findings", "", "| ID | Severity | Disposition | Cause |", "| --- | --- | --- | --- |"]
        lines += [f"| {f['id']} | {f['severity']} | {f['disposition']} | {f['cause']} |" for f in findings]
        lines.append("")

    open_findings = [f["id"] for f in findings if f["disposition"] == "open"]
    iterate_product = (store.state["products"].get("iterate") or {}).get("product") or {}
    unmet_gaps = [gap["text"] for gap in iterate_product.get("gaps", [])]
    outstanding = open_findings + unmet_gaps
    lines += [f"### Outstanding\n{', '.join(outstanding) if outstanding else 'none'}", ""]
    lines += [f"Rewinds used: {store.state['budget']['spent']}/{store.state['budget']['limit']}", ""]
    lines.append(f"Generated with loop-spec {VERSION}")
    return "\n".join(lines) + "\n"
