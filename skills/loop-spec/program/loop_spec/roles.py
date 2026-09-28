"""Load a role's prompt body and schema, and compose the prompt a lead or a
dispatched worker reads.

Use `load_role` to resolve a role name to its body and schema (the plugin's own
`skills/loop-spec/roles/<name>/` unless a project or user binds a different skill in
its place), `compose_prompt` to turn that role plus one attempt's inputs into the
text a worker or the lead session actually reads, and `resolve_model` for the model
every role's dispatch request carries (the role's own frontmatter default when nothing
overrides it). `role_contract` is the per-role text loop-spec always appends,
independent of whatever body a bound skill supplies, so a borrowed skill cannot drop
the program's own requirements on its way in; `principles` is the first-principles
stance every role's prompt carries the same way.
"""
import glob
import json
import os
from dataclasses import dataclass
from pathlib import Path

from loop_spec.contract import ROLES_DIR, check_effort, load_config, role_meta
from loop_spec.errors import LoopSpecError
from loop_spec.ids import digest_bytes
from loop_spec.jsonio import render_json



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
    default_dir = ROLES_DIR / name
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


# 7.5.0: with nothing overriding it, a dispatched role runs at the `model` and `effort` its
# own SKILL.md frontmatter names (contract.role_meta). Judgment (routing, critique, review,
# the ITERATE verdict) runs on Opus at its default medium, which matches Opus 5 at high;
# the router's first-fit rules need only low. Implementation and evidence run on Sonnet
# at high, since Sonnet at medium or low scopes its work to the letter of the prompt.
# Aliases, so each resolves to the newest of its family. Lead roles name none: a lead
# step runs in the lead's own session, at that session's model and effort.


def _dispatch_setting(project_root: Path, role: str, key: str, env_name: str) -> str | None:
    # env first, then config roles.<role>.<key> when that role is bound as an object
    # rather than a plain binding string (an explicit null there inherits the caller's
    # own), else the role's default.
    env = os.environ.get(env_name)
    if env:
        return env
    configured = load_config(project_root).get("roles", {}).get(role)
    if isinstance(configured, dict) and key in configured:
        return configured[key]
    return role_meta(role).get(key)


def resolve_effort(project_root: Path, role: str) -> str | None:
    """The same lookup as resolve_model, for effort: env LOOP_SPEC_EFFORT_<ROLE>, then
    config roles.<role>.effort (load_config validates it), else the role's default."""
    name = "LOOP_SPEC_EFFORT_" + role.upper().replace("-", "_")
    if os.environ.get(name):
        check_effort(os.environ[name], name)
    return _dispatch_setting(project_root, role, "effort", name)


def dispatch_settings(project_root: Path, role: str) -> dict:
    """What a role's step request carries for whoever dispatches its worker."""
    return {"model": resolve_model(project_root, role), "effort": resolve_effort(project_root, role)}


def resolve_model(project_root: Path, role: str) -> str | None:
    # LOOP_SPEC_MODEL_<ROLE>, hyphens to underscores, upper; see _dispatch_setting.
    return _dispatch_setting(project_root, role, "model", "LOOP_SPEC_MODEL_" + role.upper().replace("-", "_"))


def role_contract(name: str) -> str:
    """The text loop-spec always appends to a role's prompt: `contract.md` in the default
    role directory, read whatever skill a project binds in its place, so a borrowed skill
    cannot drop the program's own requirements. Empty for a role with none."""
    return _unwrapped(ROLES_DIR / name / "contract.md")


def principles() -> str:
    """The first-principles stance every role's prompt carries, ahead of its method:
    `roles/principles.md`, read whatever skill is bound, like `role_contract`."""
    return _unwrapped(ROLES_DIR / "principles.md")


def _unwrapped(path: Path) -> str:
    # The file is wrapped for its editors; the prompt carries each paragraph as one line.
    paragraphs = path.read_text().strip().split("\n\n") if path.is_file() else []
    return "\n\n".join(" ".join(p.split("\n")) for p in paragraphs)


def repo_map(repos) -> dict:
    """`inputs.repos` for a role that writes or checks a PLAN: each repo's name, path,
    base (where the baseline runs) and start (the code this run begins from: an adopted
    PR's head, else the base). `startSha` is `lastKnownHead`, which holds only because
    nothing advances `lastKnownHead` after the run's repos are resolved. `codePath` is
    a clean checkout of the code to read, at `codeSha` (7.4.2); the repo's own path when
    the program made none."""
    items = repos.items() if isinstance(repos, dict) else ((r.get("name"), r) for r in repos)
    out = {}
    for name, info in items:
        start = info.get("lastKnownHead") or info.get("baseSha")
        code = info.get("codeCheckout") or {}
        out[name] = {"path": info["path"], "baseSha": info.get("baseSha"), "startSha": start,
                     "codePath": code.get("path") or info["path"], "codeSha": code.get("sha") or start}
    return out


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
        f"## First principles\n{principles()}",
        f"## Method\n{role.body}".rstrip(),
    ]

    contract = role_contract(role.name)
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
