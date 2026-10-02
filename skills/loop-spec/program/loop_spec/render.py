"""Markdown rendering for DELIVER: the PR body and the three rendered documents.

Use `pr_body` for the PR description GFM text, and `spec_md`/`plan_md`/
`verification_md` for the documents the state home keeps under the run; nothing
here is committed to the consumer's repository (the audit's R8: a docs commit after
VERIFY would push a head that is not the verified SHA). Every function reads
`store.state["products"]` and the ledger; none of them mutate anything.
"""
import re
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
    lines = ["| Criterion | Text | Verdict |", "| --- | --- | --- |"]
    for verdict in verify_product["verdicts"]:
        text = texts.get(verdict["criterion"], "").replace("|", "\\|").replace("\n", " ")
        lines.append(f"| {verdict['criterion']} | {text} | {verdict['verdict']} |")
    return lines


def test_commands(verify_product: dict) -> list[str]:
    """Each distinct evidence command once, in the order the verdicts name them."""
    seen = []
    for verdict in verify_product["verdicts"]:
        command = (verdict["evidence"] or {}).get("command")
        if command and command not in seen:
            seen.append(command)
    return seen


def _how_to_test(verify_product: dict) -> list[str]:
    commands = test_commands(verify_product)
    if not commands:
        return []
    lines = ["### How to test", "", "```sh"] + commands + ["```", ""]
    by_sha: dict[str, list[str]] = {}
    for verdict in verify_product["verdicts"]:
        sha = (verdict["evidence"] or {}).get("sha")
        if sha:
            by_sha.setdefault(sha, []).append(verdict["criterion"])
    if len(by_sha) == 1:
        lines += [f"Verified at {next(iter(by_sha))}", ""]
    elif by_sha:
        lines += ["Verified at:", ""] + [f"- {sha} ({', '.join(ids)})" for sha, ids in by_sha.items()] + [""]
    return lines


_CRITIC_TEXT_LIMIT = 300


def _cut(text: str) -> str:
    return text if len(text) <= _CRITIC_TEXT_LIMIT else text[:_CRITIC_TEXT_LIMIT - 3].rstrip() + "..."


def _section_marks(name: str) -> tuple[str, str]:
    return f"<!-- loop-spec:{name} -->", f"<!-- loop-spec:/{name} -->"


def pr_sections(store) -> dict[str, str]:
    """What fills a PR template's Summary-like and Test-like sections: the goal with the Why
    bullets, and the How-to-test commands with the SHA they were verified at."""
    spec = store.state["products"]["spec"]["product"]
    summary = "\n".join([spec["goal"], ""] + [f"- {d['text']}" for d in spec["decisions"]]).strip("\n")
    testing = "\n".join(_how_to_test(store.state["products"]["verify"]["product"])[2:]).strip("\n")
    return {"summary": summary, "testing": testing}


def sections_in(body: str) -> frozenset[str]:
    """The template sections a PR body already carries loop-spec's text in."""
    return frozenset(name for name in ("summary", "testing") if _section_marks(name)[0] in body)


def pr_body(store, repo_name: str | None = None, siblings: list[tuple[str, str]] | None = None,
            number: int | None = None, omit: frozenset[str] = frozenset()) -> str:
    """The generated PR description, between markers so `merge_body` can refresh it without
    touching what a person wrote around it. `siblings` is (repo, PR url) for the run's other
    delivered repos; `number` is an adopted PR's number, for the owner line. `omit` names the
    sections (`summary`, `testing`) a filled PR template already carries, so they are not
    written twice (7.9.0 live run)."""
    spec = store.state["products"]["spec"]["product"]
    verify_product = store.state["products"]["verify"]["product"]
    findings = store.state["ledger"]["findings"]

    lines = [BODY_BEGIN, f"## {spec['goal']}", ""]
    if spec["decisions"] and "summary" not in omit:
        lines += ["### Why", ""] + [f"- {d['text']}" for d in spec["decisions"]] + [""]
    if spec["boundaries"]:
        lines += ["### Boundaries", ""] + [f"- {b}" for b in spec["boundaries"]] + [""]
    lines += ["### Acceptance", ""] + _criteria_table(spec, verify_product) + [""]
    if "testing" not in omit:
        lines += _how_to_test(verify_product)
    if spec["openQuestions"]:
        lines += ["### Open questions", ""] + [f"- {q['text']}" for q in spec["openQuestions"]] + [""]

    if findings:
        # No finding id: it names a record in the operator's state home, which no reviewer has.
        lines += ["### Findings", "", "| Severity | Disposition | Cause |", "| --- | --- | --- |"]
        lines += [f"| {f['severity']} | {f['disposition']} | {f['cause']} |" for f in findings]
        lines.append("")

    # 7.1.0: a Critical PLAN-critic finding the run rejected is a decision a reviewer
    # should see; only the accepted plan's own critic pass counts.
    critic = store.state.get("critic") or {}
    if critic.get("planRevision") is not None and critic.get("planRevision") == store.state["revisions"].get("plan"):
        rejected = [f for f in critic.get("findings", []) if f.get("severity") == "Critical" and f.get("disposition") == "rejected"]
        if rejected:
            lines += ["### Plan critic", "", "Critical findings on the delivered plan that the run rejected, with the reason:", ""]
            lines += [f"- {f['id']} at {f['location']}: {_cut(f['cause'])} Rejected: {_cut(f.get('reason') or '(no reason recorded)')}"
                      for f in rejected]
            lines.append("")

    if siblings:
        lines += ["### Related PRs", ""] + [f"- {name}: {url}" for name, url in siblings] + [""]
    issue = store.state.get("issue") or {}
    if repo_name is not None and issue.get("repo") == repo_name and issue.get("number"):
        lines += [f"Closes #{issue['number']}", ""]
    login = (store.state.get("operator") or {}).get("login")
    if login:
        follow_up = f"`/loop-spec:revise {number}`" if number else "`/loop-spec:revise` with this PR's number"
        lines += [f"Opened by loop-spec for @{login}; review follow-up: {follow_up}", ""]

    outstanding = result_module.outstanding(store)
    lines += [f"### Outstanding\n{', '.join(outstanding) if outstanding else 'none'}", ""]
    lines.append(f"{_GENERATED_LINE} {VERSION}")
    lines.append(BODY_END)
    return "\n".join(lines) + "\n"


def merge_body(existing: str, generated: str, sections: dict[str, str] | None = None) -> str:
    """`generated` placed into a PR body a person may have edited: between its markers when
    it has them; around a pre-7.9 generated body (from its first `## ` line to its
    `Generated with loop-spec` line), keeping the text outside; else after the human text.
    Each of `sections` replaces the text between that template section's own markers."""
    for name, text in (sections or {}).items():
        begin, end = _section_marks(name)
        b, e = existing.find(begin), existing.find(end)
        if b != -1 and e > b:
            existing = existing[:b + len(begin)] + "\n" + text + "\n" + existing[e:]
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


_HEADING = re.compile(r"^#{1,6}\s+(.*?)\s*$")
_SUMMARY_HEADING = re.compile(r"summary|description|overview|what|changes", re.IGNORECASE)
_TEST_HEADING = re.compile(r"test|verification", re.IGNORECASE)
_COMMENT = re.compile(r"<!--.*?-->", re.DOTALL)


def fill_template(template: str, store) -> str:
    """The PR template with each placeholder-only Summary-like section filled with the goal
    and the Why bullets, and each Test-like section with the How-to-test commands, each
    between its own markers so a later delivery refreshes it. A section that has any other
    content (a checklist, text) stays as written."""
    fills = pr_sections(store)
    lines = template.split("\n")
    out, i = [], 0
    while i < len(lines):
        out.append(lines[i])
        m = _HEADING.match(lines[i])
        i += 1
        if not m:
            continue
        j = i
        while j < len(lines) and not _HEADING.match(lines[j]):
            j += 1
        section = "\n".join(lines[i:j])
        name = "testing" if _TEST_HEADING.search(m.group(1)) else "summary" if _SUMMARY_HEADING.search(m.group(1)) else None
        if name and fills[name] and not _COMMENT.sub("", section).strip():
            begin, end = _section_marks(name)
            out += ["", begin, fills[name], end, ""]
            i = j
    return "\n".join(out)
