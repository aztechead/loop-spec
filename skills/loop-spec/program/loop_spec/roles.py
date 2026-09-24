"""Load a role's prompt body and schema, and compose the prompt a lead or a
dispatched worker reads.

Use `load_role` to resolve a role name to its body and schema (the plugin's own
`skills/loop-spec/roles/<name>/` unless a project or user binds a different skill in
its place), `compose_prompt` to turn that role plus one attempt's inputs into the
text a worker or the lead session actually reads, and `resolve_model` for the model
every role's dispatch request carries. `CONTRACTS` is the per-role text loop-spec
always appends, independent of whatever body a bound skill supplies, so a borrowed
skill cannot drop the program's own requirements on its way in.
"""
import glob
import json
import os
from dataclasses import dataclass
from pathlib import Path

from loop_spec.contract import load_config
from loop_spec.errors import LoopSpecError
from loop_spec.ids import digest_bytes
from loop_spec.jsonio import render_json

# skills/loop-spec/roles/<name>/ sits next to program/, i.e. two levels above this
# file's own package directory (program/loop_spec/roles.py -> program -> loop-spec).
_ROLES_DIR = Path(__file__).resolve().parent.parent.parent / "roles"

# The role registry is the roles directory itself: a role is a skill dir with a schema.
ROLE_NAMES = sorted(d.name for d in _ROLES_DIR.iterdir() if (d / "schema.json").is_file())


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


def resolve_model(project_root: Path, role: str) -> str | None:
    # env first (LOOP_SPEC_MODEL_<ROLE>, hyphens to underscores, upper -- the
    # same key defaults.py's SPEC/PLAN lead dispatch already read before this),
    # then config.json's own roles.<role>.model when that role is bound as an
    # object rather than a plain binding string, else no override (the caller's
    # own default model applies).
    env = os.environ.get("LOOP_SPEC_MODEL_" + role.upper().replace("-", "_"))
    if env:
        return env
    configured = load_config(project_root).get("roles", {}).get(role)
    return configured.get("model") if isinstance(configured, dict) else None


# A debug or revise task can slip a path or a guess into `repo`; the planner
# contract already named this, so it is shared rather than restated per role.
REPO_NAME_RULE = (
    "Every task's `repo` is one of the repository names listed under "
    "`inputs.repos` (the envelope's repo map), never a path, `.`, or a "
    "guess; a single-repository run has exactly one name."
)

CONTRACTS: dict[str, str] = {
    "spec-writer": (
        "Interview with AskUserQuestion when you can ask and the inputs leave something "
        "open. Criteria ids are `AC-n`, each testable by a "
        "command; decisions carry ids; open questions stay out of the revision. Every "
        "criterion is a property of the code at the verified head that one command can "
        "show (a test, a script, a grep); never a fact about delivery, pull requests, "
        "CI, or branches: DELIVER's own checks cover those and are not criteria. The "
        "product never contains an approval -- the program asks the human for that "
        "itself. Declare `exit: \"approved\"` when the interview is done, or "
        "`\"needs answer\"` with the question in `openQuestions` when you cannot "
        "proceed without one. When `inputs.entry.payload.preset` is `micro`, write "
        "the fewest criteria that prove the change (usually one or two), no open "
        "questions unless the request is ambiguous, and declare `approved` without "
        "an interview unless a boundary is unclear."
    ),
    "planner": (
        "Every task names a repo, files, and a `verify` command that runs from the "
        "repo root of a bare checkout at the base SHA -- no relative-cwd assumptions "
        "-- plus the criteria it covers. Use `prepare` for environment setup. No task without "
        "a verify command; `dependsOn` is acyclic. `featureAdded` is a target file "
        "PATH that does not exist at base, never a command; `mustFlip` is only for a "
        "debug repair task whose verify is the failing reproduction, and is false for "
        "every ordinary task. Declare `exit: \"ready\"`, or `\"spec gap\"` naming the "
        "missing requirement. Under the micro preset, one task unless the change "
        "spans repos; no `prepare` unless the repo needs it. " + REPO_NAME_RULE
    ),
    "plan-critic": (
        "Critical-only: a criterion no task covers, a criterion that no command can "
        "prove at the head (delivery, PR, CI, or branch facts), a verify command that "
        "cannot test what it claims, a destructive change with no boundary, a task "
        "marked `mustFlip` that is not a debug repair, `featureAdded` that is not a "
        "path or names a path present at base, or a verify command with a relative "
        "interpreter path that a clean checkout will not have, or an `existingCode` "
        "entry marked `new` for behavior cited or named code already implements. No style advice. "
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
        "issues instead of guessing. A close-out task (`inputs.closeOut`) has no verify "
        "command: make the change its text describes, run the relevant tests yourself, "
        "and commit; if its text is already true at the head, commit nothing and start "
        "your summary with `already satisfied:`, and a reviewer confirms it."
    ),
    "code-reviewer": (
        "Read the named range only. The verdict names the SHA reviewed. A finding on "
        "code a prior pass already cleared names what it supersedes. Critical means a "
        "show-stopper or an outright incorrect implementation -- the PR review catches "
        "the rest. One disposition per entry in the probe findings' `securitySignals`, "
        "naming its file, when you were given any. Under the micro preset the range is small: "
        "still read all of it; a Critical is still Critical."
    ),
    "verifier": (
        "One verdict per criterion. Evidence is the command you ran, the SHA, the "
        "exit status, and the parsed failure identities. Every evidence command must "
        "run from the root of a clean checkout of the head with nothing but the "
        "repository's own files: use the plan task's verify command, or the same "
        "interpreter with an absolute path (the venv's python, never bare `python`); "
        "the program re-runs your command itself and rejects a criterion whose re-run "
        "differs. Report the exact command you ran. `blocked` only for a cause you "
        "actually observed, and only after trying an offline stand-in (say what you "
        "tried). Never `pass` on inference."
    ),
    "iterate-judge": (
        "Judge the delivered behavior against the ORIGINAL request text, not the "
        "checklist. Every gap names a target phase. `met` only with no gap. In a "
        "workspace an `execute` gap names its `repo`."
    ),
    "debugger": (
        "You do not repair anything. You modify no file. Your product is the "
        "reproduction (a command that fails at base from a clean checkout root, "
        "with absolute interpreter paths, e.g. the venv's python, never bare "
        "`python`), the diagnosis (which side is wrong and why), and the compact "
        "SPEC and PLAN whose single task carries the repair for EXECUTE to do. If "
        "you already edited a file while investigating, revert it and say so. "
        "Reproduce before you diagnose; diagnose with one checked hypothesis at a "
        "time, never a fix on one you have not checked. " + REPO_NAME_RULE
    ),
    "reviser": REPO_NAME_RULE,
}


def repo_map(repos) -> dict:
    """`inputs.repos` for a role that writes or checks a PLAN: each repo's name, path,
    base (where the baseline runs) and start (the code this run begins from: an adopted
    PR's head, else the base). `startSha` is `lastKnownHead`, which holds only because
    nothing advances `lastKnownHead` after the run's repos are resolved."""
    items = repos.items() if isinstance(repos, dict) else ((r.get("name"), r) for r in repos)
    return {name: {"path": info["path"], "baseSha": info.get("baseSha"),
                   "startSha": info.get("lastKnownHead") or info.get("baseSha")} for name, info in items}


def compose_prompt(role: Role, *, inputs: dict, result_path: Path, cwd: Path, phase: str) -> str:
    # The Agent tool has no working-directory parameter, so a worker starts in the
    # lead's checkout; three live workers edited, reset, or checked out there before
    # reading the cwd line at the bottom of the prompt (LF-08, LF-15, LF-20). It is the
    # first thing they read now.
    sections = [
        f"WORKING DIRECTORY: {cwd}\n"
        f"Every command you run starts with `cd {cwd} &&` (or uses `git -C {cwd}`). "
        "Never run git checkout, reset, clean, or commit in any other directory; the "
        "directory you were started in belongs to the user.",
        f"## Method\n{role.body}".rstrip(),
    ]

    contract = CONTRACTS.get(role.name)
    if contract:
        sections.append(f"## loop-spec contract\n{contract}")

    input_sections = []
    for key, value in inputs.items():
        if isinstance(value, (dict, list)):
            body = "```json\n" + render_json(value) + "\n```"
        elif value is None or isinstance(value, bool):
            body = json.dumps(value)  # the worker reads JSON, not Python's None/True
        else:
            # A diff ends with its own newline; kept, it made three newlines before the
            # next header, a run every observed dispatch collapsed in transit, so no
            # review step with a later input could attest (LF-56). Only the section's
            # trailing framing is trimmed; its interior lines stay exact.
            body = str(value).rstrip("\n")
        input_sections.append(f"### {key}\n{body}")
    sections.append("## Inputs\n\n" + "\n\n".join(input_sections))

    schema_json = render_json(role.schema)
    sections.append(
        "## Output\n"
        f"Write ONE JSON file to {result_path} matching this schema:\n"
        f"```json\n{schema_json}\n```\n"
        f"Working directory: {cwd}. Do not write anywhere else except the working directory."
    )

    return "\n\n".join(sections)
