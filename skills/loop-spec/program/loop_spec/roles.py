"""Load a role's prompt body and schema, and compose the prompt a lead or a
dispatched worker reads.

Use `load_role` to resolve a role name to its body and schema (the plugin's own
`skills/loop-spec/roles/<name>/` unless a project or user binds a different skill in
its place), and `compose_prompt` to turn that role plus one attempt's inputs into the
text a worker or the lead session actually reads. `CONTRACTS` is the per-role text
loop-spec always appends, independent of whatever body a bound skill supplies, so a
borrowed skill cannot drop the program's own requirements on its way in.
"""
import glob
import json
from dataclasses import dataclass
from pathlib import Path

from .errors import LoopSpecError
from .ids import digest_bytes

ROLE_NAMES = ["spec-writer", "planner", "plan-critic", "implementer", "code-reviewer", "verifier", "iterate-judge"]

# skills/loop-spec/roles/<name>/ sits next to program/, i.e. two levels above this
# file's own package directory (program/loop_spec/roles.py -> program -> loop-spec).
_ROLES_DIR = Path(__file__).resolve().parent.parent.parent / "roles"


@dataclass
class Role:
    name: str
    body: str
    schema: dict
    source: str  # "default", or the bound skill's SKILL.md path
    version: str


def _strip_frontmatter(text: str) -> str:
    # SKILL.md opens with a `---`-delimited YAML block (name, description, ...); the
    # role's body is everything after it -- the frontmatter is metadata for the
    # harness, not part of what a worker reads.
    if text.startswith("---\n"):
        end = text.find("\n---", 4)
        if end != -1:
            return text[end + 4:].lstrip("\n")
    return text


def _bound_skill_candidates(project_root: Path, binding: str) -> list[Path]:
    candidates = [
        Path(project_root) / ".claude" / "skills" / binding / "SKILL.md",
        Path.home() / ".claude" / "skills" / binding / "SKILL.md",
        Path.home() / ".agents" / "skills" / binding / "SKILL.md",
    ]
    if ":" in binding:
        plugin, skill = binding.split(":", 1)
        pattern = str(Path.home() / ".claude" / "plugins" / "cache" / "*" / plugin / "*" / "skills" / skill / "SKILL.md")
        candidates.extend(Path(p) for p in sorted(glob.glob(pattern)))
    return candidates


def load_role(name: str, project_root: Path, binding: str = "default") -> Role:
    default_dir = _ROLES_DIR / name
    default_schema = json.loads((default_dir / "schema.json").read_text())

    if binding == "default":
        body = _strip_frontmatter((default_dir / "SKILL.md").read_text())
        return Role(name=name, body=body, schema=default_schema, source="default", version=digest_bytes(body.encode()))

    candidates = _bound_skill_candidates(project_root, binding)
    found = next((c for c in candidates if c.is_file()), None)
    if found is None:
        raise LoopSpecError(
            f"bound skill {binding} not found",
            repair="checked: " + "; ".join(str(c) for c in candidates),
        )

    body = _strip_frontmatter(found.read_text())
    # A borrowed skill supplies its own method, never its own schema (roadmap 8): the
    # program still validates the product against the DEFAULT role's shape, so a bound
    # skill cannot smuggle in an incompatible contract.
    return Role(name=name, body=body, schema=default_schema, source=str(found), version=digest_bytes(body.encode()))


CONTRACTS: dict[str, str] = {
    "spec-writer": (
        "Interview with AskUserQuestion. Criteria ids are `AC-n`, each testable by a "
        "command; decisions carry ids; open questions stay out of the revision. The "
        "product never contains an approval -- the program asks the human for that "
        "itself. Declare `exit: \"approved\"` when the interview is done, or "
        "`\"needs answer\"` with the question in `openQuestions` when you cannot "
        "proceed without one."
    ),
    "planner": (
        "Every task names a repo, files, and a `verify` command that runs from the "
        "repo root of a bare checkout at the base SHA -- no relative-cwd assumptions "
        "-- plus the criteria it covers. Use `featureAdded` when the verify target "
        "does not exist at base, and `prepare` for environment setup. No task without "
        "a verify command; `dependsOn` is acyclic. Declare `exit: \"ready\"`, or "
        "`\"spec gap\"` naming the missing requirement."
    ),
    "plan-critic": (
        "Critical-only: a criterion no task covers, a verify command that cannot test "
        "what it claims, a destructive change with no boundary. No style advice. "
        "Output `{\"findings\": []}` when nothing is Critical."
    ),
    "implementer": (
        "One task, in the given worktree. Your shell does not start there: prefix every "
        "command with `cd <working directory> &&` or use `git -C <working directory>`, "
        "and never run `git reset`, `git checkout`, or `git clean` anywhere else; the "
        "user's own checkout is not yours to touch. Commit on the task branch with "
        "messages naming the task id, and run the task's verify command before finishing. "
        "Never weaken an existing assertion; when `inputs.flags.minimalDiff` is true, "
        "add no new broad assertions and keep the smallest diff. Report unresolved "
        "issues instead of guessing."
    ),
    "code-reviewer": (
        "Read the named range only. The verdict names the SHA reviewed. A finding on "
        "code a prior pass already cleared names what it supersedes. Critical means a "
        "show-stopper or an outright incorrect implementation -- the PR review catches "
        "the rest. One disposition per security signal in `inputs.probes.securitySignals` "
        "for files the range touches."
    ),
    "verifier": (
        "One verdict per criterion. Evidence is the command you ran, the SHA, the "
        "exit status, and the parsed failure identities. `blocked` only for a cause "
        "you actually observed, and only after trying an offline stand-in (say what "
        "you tried). Never `pass` on inference."
    ),
    "iterate-judge": (
        "Judge the delivered behavior against the ORIGINAL request text, not the "
        "checklist. Every gap names a target phase. `met` only with no gap."
    ),
}


def compose_prompt(role: Role, *, inputs: dict, result_path: Path, cwd: Path, phase: str) -> str:
    sections = [f"## Method\n{role.body}".rstrip()]

    contract = CONTRACTS.get(role.name)
    if contract:
        sections.append(f"## loop-spec contract\n{contract}")

    input_sections = []
    for key, value in inputs.items():
        if isinstance(value, (dict, list)):
            body = "```json\n" + json.dumps(value, indent=2, sort_keys=True) + "\n```"
        else:
            body = str(value)
        input_sections.append(f"### {key}\n{body}")
    sections.append("## Inputs\n\n" + "\n\n".join(input_sections))

    schema_json = json.dumps(role.schema, indent=2, sort_keys=True)
    sections.append(
        "## Output\n"
        f"Write ONE JSON file to {result_path} matching this schema:\n"
        f"```json\n{schema_json}\n```\n"
        f"Working directory: {cwd}. Do not write anywhere else except the working directory."
    )

    return "\n\n".join(sections)
