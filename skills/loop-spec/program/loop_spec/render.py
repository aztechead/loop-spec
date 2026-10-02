"""Markdown rendering for DELIVER: the PR body and the three rendered documents.

Use `pr_body` for the PR description GFM text, and `spec_md`/`plan_md`/
`verification_md` for the documents the state home keeps under the run; nothing
here is committed to the consumer's repository (the audit's R8: a docs commit after
VERIFY would push a head that is not the verified SHA). Every function reads
`store.state["products"]` and the ledger; none of them mutate anything.
"""
from pathlib import Path

from loop_spec import VERSION
from loop_spec import repo as repo_module
from loop_spec import result as result_module


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


BODY_BEGIN = "<!-- loop-spec:begin -->"
BODY_END = "<!-- loop-spec:end -->"
_GENERATED_LINE = "Generated with loop-spec"


def _criteria_table(spec: dict, verify_product: dict) -> list[str]:
    texts = {c["id"]: c["text"] for c in spec["criteria"]}
    lines = ["| Criterion | Text | Verdict | Command | SHA |", "| --- | --- | --- | --- | --- |"]
    for verdict in verify_product["verdicts"]:
        evidence = verdict["evidence"] or {}
        text = texts.get(verdict["criterion"], "").replace("|", "\\|").replace("\n", " ")
        lines.append(f"| {verdict['criterion']} | {text} | {verdict['verdict']} | "
                     f"`{evidence.get('command', '')}` | {evidence.get('sha', '')} |")
    return lines


def pr_body(store, repo_name: str | None = None, siblings: list[tuple[str, str]] | None = None) -> str:
    """The generated PR description, between markers so `merge_body` can refresh it without
    touching what a person wrote around it. `siblings` is (repo, PR url) for the run's other
    delivered repos."""
    spec = store.state["products"]["spec"]["product"]
    verify_product = store.state["products"]["verify"]["product"]
    findings = store.state["ledger"]["findings"]

    lines = [BODY_BEGIN, f"## {spec['goal']}", ""]
    if spec["decisions"]:
        lines += ["### Why", ""] + [f"- {d['text']}" for d in spec["decisions"]] + [""]
    if spec["boundaries"]:
        lines += ["### Boundaries", ""] + [f"- {b}" for b in spec["boundaries"]] + [""]
    lines += ["### Acceptance", ""] + _criteria_table(spec, verify_product) + [""]
    if spec["openQuestions"]:
        lines += ["### Open questions", ""] + [f"- {q['text']}" for q in spec["openQuestions"]] + [""]

    if findings:
        lines += ["### Findings", "", "| ID | Severity | Disposition | Cause |", "| --- | --- | --- | --- |"]
        lines += [f"| {f['id']} | {f['severity']} | {f['disposition']} | {f['cause']} |" for f in findings]
        lines.append("")

    # 7.1.0: a Critical PLAN-critic finding the run rejected is a decision a reviewer
    # should see; only the accepted plan's own critic pass counts.
    critic = store.state.get("critic") or {}
    if critic.get("planRevision") is not None and critic.get("planRevision") == store.state["revisions"].get("plan"):
        rejected = [f for f in critic.get("findings", []) if f.get("severity") == "Critical" and f.get("disposition") == "rejected"]
        if rejected:
            lines += ["### Plan critic", "", "Critical findings on the delivered plan that the run rejected, with the reason:", ""]
            lines += [f"- {f['id']} at {f['location']}: {f['cause']} Rejected: {f.get('reason') or '(no reason recorded)'}"
                      for f in rejected]
            lines.append("")

    if siblings:
        lines += ["### Related PRs", ""] + [f"- {name}: {url}" for name, url in siblings] + [""]
    issue = store.state.get("issue") or {}
    if repo_name is not None and issue.get("repo") == repo_name and issue.get("number"):
        lines += [f"Closes #{issue['number']}", ""]
    login = (store.state.get("operator") or {}).get("login")
    if login:
        lines += [f"Opened by loop-spec for @{login}; review follow-up: `/loop-spec:revise <pr>`", ""]

    outstanding = result_module.outstanding(store)
    lines += [f"### Outstanding\n{', '.join(outstanding) if outstanding else 'none'}", ""]
    lines.append(f"{_GENERATED_LINE} {VERSION}")
    lines.append(BODY_END)
    return "\n".join(lines) + "\n"


def merge_body(existing: str, generated: str) -> str:
    """`generated` placed into a PR body a person may have edited: between its markers when
    it has them; around a pre-7.9 generated body (from its first `## ` line to its
    `Generated with loop-spec` line), keeping the text outside; else after the human text."""
    generated = generated.strip("\n")
    begin, end = existing.find(BODY_BEGIN), existing.find(BODY_END)
    if begin != -1 and end > begin:
        return existing[:begin] + generated + existing[end + len(BODY_END):]
    lines = existing.split("\n")
    start = next((i for i, line in enumerate(lines) if line.startswith("## ")), None)
    last = next((i for i in range(len(lines) - 1, -1, -1) if lines[i].startswith(_GENERATED_LINE)), None)
    if start is not None and last is not None and start <= last:
        before, after = "\n".join(lines[:start]).rstrip(), "\n".join(lines[last + 1:]).strip("\n")
        return (before + "\n\n" if before else "") + generated + ("\n\n" + after if after else "") + "\n"
    return existing.rstrip() + "\n\n" + generated + "\n"


_PR_TEMPLATES = (".github/pull_request_template.md", ".github/PULL_REQUEST_TEMPLATE.md",
                 "docs/pull_request_template.md", "pull_request_template.md", "PULL_REQUEST_TEMPLATE.md")


def pr_template(worktree: Path, sha: str) -> str | None:
    """The repository's PR template as committed at `sha` (never the working tree), else None."""
    for name in _PR_TEMPLATES:
        proc = repo_module._git(worktree, "show", f"{sha}:{name}")
        if proc.returncode == 0:
            return proc.stdout
    return None
