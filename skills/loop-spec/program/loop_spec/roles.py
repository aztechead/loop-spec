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

from loop_spec.contract import ROLES_DIR, check_effort, load_config, resolve_role, role_meta, validate_request
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


def _json_object(path: Path) -> dict:
    # A registry or manifest another tool writes: unreadable, malformed, or not an
    # object reads as empty, so a bad file skips that source instead of failing the step.
    try:
        value = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def _bound_skill_candidates(project_root: Path, binding: str) -> list[Path]:
    candidates = [
        Path(project_root) / ".claude" / "skills" / binding / "SKILL.md",
        Path.home() / ".claude" / "skills" / binding / "SKILL.md",
        Path.home() / ".agents" / "skills" / binding / "SKILL.md",
    ]
    if ":" in binding:
        plugin, skill = binding.split(":", 1)
        # A plugin loaded by path (`claude --plugin-dir`, the Agent SDK's local plugins)
        # is in no registry, so the session that loads it names its directory here.
        for plugin_dir in filter(None, os.environ.get("LOOP_SPEC_PLUGIN_DIRS", "").split(os.pathsep)):
            name = _json_object(Path(plugin_dir) / ".claude-plugin" / "plugin.json").get("name") or Path(plugin_dir).name
            if name == plugin:
                candidates.append(Path(plugin_dir) / "skills" / skill / "SKILL.md")
        # The cache keeps every version a plugin was ever installed at, so the installed
        # one comes from Claude Code's own registry (this project's install first); the
        # cache glob, newest first, is only for a host without that registry.
        registry = Path.home() / ".claude" / "plugins" / "installed_plugins.json"
        installs = []
        plugins = _json_object(registry).get("plugins")
        for key, entries in (plugins.items() if isinstance(plugins, dict) else ()):
            if key.split("@", 1)[0] == plugin and isinstance(entries, list):
                installs.extend(e for e in entries if isinstance(e, dict) and isinstance(e.get("installPath"), str))
        installs.sort(key=lambda e: e.get("projectPath") != str(project_root))
        candidates.extend(Path(e["installPath"]) / "skills" / skill / "SKILL.md" for e in installs)
        pattern = str(Path.home() / ".claude" / "plugins" / "cache" / "*" / plugin / "*" / "skills" / skill / "SKILL.md")
        candidates.extend(sorted((Path(p) for p in glob.glob(pattern)), key=lambda c: c.stat().st_mtime, reverse=True))
    return candidates


def _read_skill(project_root: Path, binding: str) -> tuple[Path, str]:
    candidates = _bound_skill_candidates(project_root, binding)
    found = next((c for c in candidates if c.is_file()), None)
    if found is None:
        raise LoopSpecError(
            f"bound skill {binding} not found",
            repair="checked: " + "; ".join(str(c) for c in candidates),
        )
    # The harness substitutes these placeholders only in a skill it loads itself; the
    # program inlines the body into a prompt, so it resolves them for the bound skill.
    body = _strip_frontmatter(found.read_text()).replace("${CLAUDE_SKILL_DIR}", str(found.parent))
    plugin_root = found.parent.parent.parent  # <root>/skills/<skill>/SKILL.md
    if (plugin_root / ".claude-plugin" / "plugin.json").is_file():
        body = body.replace("${CLAUDE_PLUGIN_ROOT}", str(plugin_root))
    return found, body


def load_role(name: str, project_root: Path, binding: str | None = None) -> Role:
    """The role's prompt and schema; `binding` defaults to the project's (resolve_role).
    Each skill in config `roles.<name>.with` follows the method, whichever is bound."""
    if binding is None:
        binding = resolve_role(project_root, name)
    default_dir = ROLES_DIR / name
    # A borrowed skill supplies its own method, never its own schema (roadmap 8): the
    # program still validates the product against the DEFAULT role's shape, so a bound
    # skill cannot smuggle in an incompatible contract.
    default_schema = json.loads((default_dir / "schema.json").read_text())

    if binding == "default":
        source, body = "default", _strip_frontmatter((default_dir / "SKILL.md").read_text())
    else:
        found, body = _read_skill(project_root, binding)
        source = str(found)
    configured = load_config(project_root).get("roles", {}).get(name)
    for extra in configured.get("with", []) if isinstance(configured, dict) else []:
        body = body.rstrip() + f"\n\n### Also follow the `{extra}` skill\n\n" + _read_skill(project_root, extra)[1]
    return Role(name=name, body=body, schema=default_schema, source=source, version=digest_bytes(body.encode()))


# 7.5.0: with nothing overriding it, a dispatched role runs at the `model` and `effort` its
# own SKILL.md frontmatter names (contract.role_meta). Judgment (routing, critique, review,
# the ITERATE verdict) runs on Opus at its default medium, which matches Opus 5 at high;
# the router's first-fit rules need only low. Implementation and evidence run on Sonnet
# at high: below it, Sonnet 5.5 can stop to check in before a coding task is done or
# report a change without running a check, and a worker has no one to check in with.
# Aliases, so each resolves to the newest of its family. Lead roles name none: a lead
# step runs in the lead's own session, at that session's model and effort.


def _dispatch_setting(project_root: Path, role: str, key: str, env_name: str,
                      phase_env: str | None = None) -> str | None:
    # env first, then config roles.<role>.<key> when that role is bound as an object
    # rather than a plain binding string (an explicit null there inherits the caller's
    # own), then the phase-wide env (`phase_env`, as 6.x's LOOP_SPEC_PHASE_MODEL_<PHASE>),
    # else the role's default.
    env = os.environ.get(env_name)
    if env:
        return env
    configured = load_config(project_root).get("roles", {}).get(role)
    if isinstance(configured, dict) and key in configured:
        return configured[key]
    if phase_env and os.environ.get(phase_env):
        return os.environ[phase_env]
    return role_meta(role).get(key)


def resolve_effort(project_root: Path, role: str) -> str | None:
    """The same lookup as resolve_model, for effort: env LOOP_SPEC_EFFORT_<ROLE>, then
    config roles.<role>.effort (load_config validates it), else the role's default."""
    name = "LOOP_SPEC_EFFORT_" + role.upper().replace("-", "_")
    if os.environ.get(name):
        check_effort(os.environ[name], name)
    return _dispatch_setting(project_root, role, "effort", name)


def dispatch_settings(project_root: Path, role: str, phase: str | None = None) -> dict:
    """What a role's step request carries for whoever dispatches its worker, or, for a
    lead step, for an SDK runner that switches the lead's model (examples/sdk-plugin)."""
    return {"model": resolve_model(project_root, role, phase), "effort": resolve_effort(project_root, role)}


def resolve_model(project_root: Path, role: str, phase: str | None = None) -> str | None:
    # LOOP_SPEC_MODEL_<ROLE>, hyphens to underscores, upper; then LOOP_SPEC_PHASE_MODEL_<PHASE>
    # for the phase the step runs in; see _dispatch_setting.
    return _dispatch_setting(project_root, role, "model", "LOOP_SPEC_MODEL_" + role.upper().replace("-", "_"),
                             ("LOOP_SPEC_PHASE_MODEL_" + phase.upper()) if phase else None)


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


def step_request(kind: str, role_name: str, phase: str, *, project_root: Path, ctx: dict, cwd, prompt: str,
                 result_path, schema: dict, postconditions: list | None = None,
                 retry_of: str | None = None, reason: str | None = None) -> dict:
    """A step request in the contract's `step` shape, validated; raises naming the phase and role."""
    request = {
        "kind": kind, "role": role_name, "phase": phase, "cwd": str(cwd), "prompt": prompt,
        "resultPath": str(result_path), "schema": schema, "postconditions": postconditions or [],
        "attempt": ctx["attempt"]["id"], "inputsDigest": ctx["inputs"]["digest"],
        "retryOf": retry_of, "reason": reason, **dispatch_settings(project_root, role_name, phase),
    }
    errors = validate_request("step", request)
    if errors:
        raise LoopSpecError(f"{phase} built an invalid {role_name} step request: " + "; ".join(errors),
                            repair=f"fix the {role_name} request builder in {phase}")
    return request
