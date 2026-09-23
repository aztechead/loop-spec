"""Failure-identity parsing, output normalization, and baseline capture/comparison.

Use the `parse_*`/`detect_runner` functions to turn a test runner's raw output into
stable failure identities, `run_command` to execute one command and record everything
a later comparison needs, `capture_baseline` to run a plan's commands once at the base
commit, and `compare_to_baseline`/`evidence_matches` to decide whether a later run at
a candidate commit regressed, satisfies a featureAdded/mustFlip task, or matches a
claimed VERIFY result. None of these functions choose a phase route; they report facts
for `postconditions.py` to check.
"""
import hashlib
import re
import pathlib
import shlex
import subprocess
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Literal

from loop_spec import repo as repo_module
from loop_spec.errors import LoopSpecError
from loop_spec.ids import digest_bytes, now_iso

# ---------------------------------------------------------------------------
# Failure identity parsers
# ---------------------------------------------------------------------------

_PYTEST_LINE = re.compile(r"^(?:FAILED|ERROR)\s+(\S+)")


def parse_pytest(text: str) -> list[str]:
    identities = {m.group(1) for line in text.splitlines() if (m := _PYTEST_LINE.match(line.strip()))}
    return sorted(identities)


# simplicity: parse_vitest_jest and parse_go_test share a "header line sets context,
# match line emits an identity" shape (duplication-scan flags ~11 similar lines). A
# shared scanner would need callbacks for the bullet/checkmark split and the "."-vs-"
# >"-join that make them behave differently, trading two readable 10-line parsers for
# one generic one; upgrade to a shared helper only once a third parser needs the same
# shape.
_JS_FAIL_HEADER = re.compile(r"^\s*FAIL\s+(\S+)")
_JS_CHECK_MARK = re.compile(r"^\s*[✕×]\s+(.+?)(?:\s+\(\d+(?:\.\d+)?\s*m?s\))?\s*$")
_JS_BULLET = re.compile(r"^\s*●\s+(.+?)\s*$")


def parse_vitest_jest(text: str) -> list[str]:
    identities = []
    current_fail_path = None
    for line in text.splitlines():
        header = _JS_FAIL_HEADER.match(line)
        if header:
            current_fail_path = header.group(1)
            continue
        bullet = _JS_BULLET.match(line)
        if bullet:
            name = bullet.group(1).replace(" › ", " > ")
            identities.append(f"{current_fail_path} > {name}" if current_fail_path else name)
            continue
        mark = _JS_CHECK_MARK.match(line)
        if mark:
            identities.append(mark.group(1))
    return sorted(set(identities))


_GO_PKG_SUMMARY = re.compile(r"^FAIL\t(\S+)")
_GO_FAIL = re.compile(r"^--- FAIL: (\S+)")


def parse_go_test(text: str) -> list[str]:
    identities = []
    current_pkg = None
    for line in text.splitlines():
        pkg = _GO_PKG_SUMMARY.match(line)
        if pkg:
            current_pkg = pkg.group(1)
            continue
        fail = _GO_FAIL.match(line)
        if fail:
            name = fail.group(1)
            identities.append(f"{current_pkg}.{name}" if current_pkg else name)
    return sorted(set(identities))


_CARGO_LINE = re.compile(r"^test\s+(\S+)\s+\.\.\.\s+FAILED\s*$")


def parse_cargo_test(text: str) -> list[str]:
    identities = {m.group(1) for line in text.splitlines() if (m := _CARGO_LINE.match(line.strip()))}
    return sorted(identities)


# Repo checks (lint, typecheck, format check): one identity per diagnostic, "<path>:
# <message>", with the line/column dropped so an unrelated edit above a pre-existing
# diagnostic does not make it look new. Supported output shapes, each tested: ruff
# `--output-format concise`, mypy, flake8 (`path:line[:col]: message`), tsc
# `--pretty false` (`path(line,col): message`), and `ruff format --check`
# (`Would reformat: path`). Anything else falls back to fingerprints.
_DIAG_COLON = re.compile(r"^(\S+?\.\w+):\d+(?::\d+)?:?\s+(.+)$")
_DIAG_TSC = re.compile(r"^(\S+?\.\w+)\(\d+,\d+\):\s+(.+)$")
_DIAG_REFORMAT = re.compile(r"^Would reformat:\s+(\S+)$")


def parse_diagnostics(text: str, root: str = "") -> list[str]:
    identities = set()
    prefix = root.rstrip("/") + "/" if root else None
    for raw in text.splitlines():
        line = _ANSI.sub("", raw).strip()
        if m := _DIAG_REFORMAT.match(line):
            path, message = m.group(1), "would reformat"
        elif m := (_DIAG_COLON.match(line) or _DIAG_TSC.match(line)):
            path, message = m.group(1), " ".join(m.group(2).split())
        else:
            continue
        if prefix and path.startswith(prefix):
            path = path[len(prefix):]
        identities.add(f"{path}: {message}")
    return sorted(identities)


PARSERS = {
    "pytest": parse_pytest,
    "vitest": parse_vitest_jest,
    "jest": parse_vitest_jest,
    "go": parse_go_test,
    "cargo": parse_cargo_test,
    "diagnostics": parse_diagnostics,
}
_DIAGNOSTIC_TOOLS = {"ruff", "mypy", "tsc", "flake8"}


def _parse(runner: str, output: str, root: Path) -> list[str]:
    if runner == "diagnostics":
        return parse_diagnostics(output, str(root))
    return PARSERS[runner](output)


def detect_runner(command: str) -> str | None:
    try:
        tokens = shlex.split(command)
    except ValueError:
        return None
    if not tokens:
        return None
    # Runners are usually invoked through a path (a venv's python, node_modules/.bin/jest,
    # npx), so match on the basename and let `python -m pytest` appear anywhere after
    # `npx`/`uv run`-style prefixes: a baseline that misses its parser falls back to
    # fingerprints and loses test identities (live finding LF-02).
    names = [pathlib.PurePath(t).name for t in tokens]
    for i, name in enumerate(names):
        if name == "pytest":
            return "pytest"
        if re.fullmatch(r"python[0-9.]*", name) and names[i + 1:i + 3] == ["-m", "pytest"]:
            return "pytest"
        if name == "vitest":
            return "vitest"
        if name == "jest":
            return "jest"
        if name == "go" and names[i + 1:i + 2] == ["test"]:
            return "go"
        if name == "cargo" and names[i + 1:i + 2] == ["test"]:
            return "cargo"
        if name in _DIAGNOSTIC_TOOLS:
            return "diagnostics"
    return None


# ---------------------------------------------------------------------------
# Output normalization (port of lib/verification-baseline.sh's normalize(), same
# regexes and order, so a fingerprint computed by the shell tooling and one computed
# here agree on the same raw output).
# ---------------------------------------------------------------------------

# v2: counts on a whole summary line are stripped (7.1.0); the diagnostics parser.
NORMALIZATION_VERSION = 2

_ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
_HEX = re.compile(r"\b0x[0-9a-f]+\b", re.IGNORECASE)
_LINE_NO = re.compile(r"(?<=:)[0-9]+(?::[0-9]+)?\b")
_TIME = re.compile(r"\b[0-9]+(?:\.[0-9]+)?(?:ms|s)\b")
_LABELED_NUM = re.compile(r"\b(pid|process|port)([:=# ]+)[0-9]+\b", re.IGNORECASE)
_BIG_INT = re.compile(r"\b[0-9]{5,}\b")
# A summary banner's counts change whenever a passing test is added, so a line that is
# ENTIRELY one of these shapes has its digits replaced; any other line keeps them, so two
# assertion messages that differ only in a number stay two fingerprints.
_SUMMARY_LINES = (
    re.compile(r"^[=\s-]*\d+ \w+(?:\s*[,|]\s*\d+ \w+)*(?: in <TIME>)?[=\s-]*$"),  # pytest, vitest
    re.compile(r"^FAILED \((?:\w+=\d+(?:, )?)+\)$"),  # unittest
    re.compile(r"^Tests?:\s+.*\b\d+ total$"),  # jest
)
_FAILURE_MARKER = re.compile(
    r"(?:\bfail(?:ed|ure)?\b|\berror\b|\bexception\b|\bpanic\b|\bfatal\b|\bassert(?:ion)?\b|\bnot ok\b)",
    re.IGNORECASE,
)


def _normalize_line(line: str, root: str) -> str:
    line = _ANSI.sub("", line).replace(root, "<ROOT>")
    line = _HEX.sub("<HEX>", line)
    line = _LINE_NO.sub("<LINE>", line)
    line = _TIME.sub("<TIME>", line)
    line = _LABELED_NUM.sub(r"\1\2<N>", line)
    line = _BIG_INT.sub("<N>", line)
    line = " ".join(line.split())
    if any(summary.match(line) for summary in _SUMMARY_LINES):
        line = re.sub(r"\d+", "<N>", line)
    return line


def normalize_output(text: str, root: Path) -> str:
    root_str = str(root)
    return "\n".join(_normalize_line(line, root_str) for line in text.splitlines())


def _fingerprint_hash(line: str) -> str:
    return hashlib.sha256(line.encode()).hexdigest()[:16]


def fingerprint_candidates(text: str, root: Path) -> list[str]:
    """The normalized lines `fingerprints` hashes, in output order."""
    root_str = str(root)
    lines = text.splitlines()
    # The marker check runs on the RAW line, before normalization, matching the 6.9
    # shell/python tool exactly; normalizing first would let a scrubbed number or
    # path swallow the word that made the line worth fingerprinting.
    candidates = [_normalize_line(line, root_str) for line in lines if _FAILURE_MARKER.search(line)]
    candidates = [c for c in candidates if c]
    if not candidates:
        nonempty = [_normalize_line(line, root_str) for line in lines if line.strip()]
        candidates = nonempty[-1:] or ["<no failure output>"]
    return candidates


def fingerprints(text: str, root: Path) -> list[str]:
    return sorted({_fingerprint_hash(c) for c in fingerprint_candidates(text, root)})


_LINE_CAP = 300  # display characters kept per line; the hash is of the whole line
_FINGERPRINT_LINE_CAP = 50
_TAIL_LINES = 20


# ---------------------------------------------------------------------------
# Running a command
# ---------------------------------------------------------------------------


@dataclass
class CommandRun:
    command: str
    cwd: str
    sha: str
    exit_status: int
    runner: str | None
    failure_identities: list[str]
    fingerprints: list[str]
    output_digest: str
    normalized_digest: str
    normalization_version: int
    started_at: str
    elapsed_seconds: float
    error_class: str | None
    tests_ran: int
    log_path: str | None
    # Readable failure text for a retry reason (7.1.0); state written before has none.
    fingerprint_lines: dict[str, str] = field(default_factory=dict)
    omitted_lines: int = 0
    tail: list[str] = field(default_factory=list)

    def to_dict(self) -> dict:
        return {
            "command": self.command,
            "cwd": self.cwd,
            "sha": self.sha,
            "exitStatus": self.exit_status,
            "runner": self.runner,
            "failureIdentities": list(self.failure_identities),
            "fingerprints": list(self.fingerprints),
            "outputDigest": self.output_digest,
            "normalizedDigest": self.normalized_digest,
            "normalizationVersion": self.normalization_version,
            "startedAt": self.started_at,
            "elapsedSeconds": self.elapsed_seconds,
            "errorClass": self.error_class,
            "testsRan": self.tests_ran,
            "logPath": self.log_path,
            "fingerprintLines": dict(self.fingerprint_lines),
            "omittedLines": self.omitted_lines,
            "tail": list(self.tail),
        }

    @classmethod
    def from_dict(cls, data: dict) -> "CommandRun":
        return cls(
            command=data["command"], cwd=data["cwd"], sha=data["sha"], exit_status=data["exitStatus"],
            runner=data["runner"], failure_identities=list(data["failureIdentities"]),
            fingerprints=list(data["fingerprints"]), output_digest=data["outputDigest"],
            normalized_digest=data["normalizedDigest"], normalization_version=data["normalizationVersion"],
            started_at=data["startedAt"], elapsed_seconds=data["elapsedSeconds"], error_class=data["errorClass"],
            tests_ran=data["testsRan"], log_path=data["logPath"],
            fingerprint_lines=dict(data.get("fingerprintLines") or {}),
            omitted_lines=data.get("omittedLines", 0), tail=list(data.get("tail") or []),
        )


_TESTS_RAN_PATTERNS = {
    "pytest": re.compile(r"\bpassed\b|PASSED"),
    "vitest": re.compile(r"✓|√|Tests:\s+\d+ passed"),
    "jest": re.compile(r"✓|√|Tests:\s+\d+ passed"),
    "go": re.compile(r"^--- PASS|^ok\s"),
    "cargo": re.compile(r"^test result:.*\bok\b|\.\.\. ok$"),
    "diagnostics": re.compile(r"(?!)"),  # a check runs no tests
}


def _count_tests_ran(output: str, runner: str | None) -> int:
    if runner is None:
        return 0
    pattern = _TESTS_RAN_PATTERNS[runner]
    return sum(1 for line in output.splitlines() if pattern.search(line))


# ---------------------------------------------------------------------------
# Command format (LF-53)
# ---------------------------------------------------------------------------

_OPERATOR_CHARS = set(";&|<>()")
_GLOB_CHARS = set("*?[")
_SPECIAL_PARAMS = set("?#@*!$-")
_ASSIGNMENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=")


class _InvalidCommand(Exception):
    pass


def shell_syntax(command: str) -> str | None:
    """LF-53: run_command execs a command as argv with no shell, so shell syntax in it
    reaches the program as literal arguments (`&&` became a git pathspec, exit 128).
    Name the first construct the supported plain-argv format rejects, or None.

    A quote/escape-aware scan that reads the string the way run_command's
    `shlex.split` does (POSIX, comments disabled): quoted and escaped text is literal,
    single quotes make everything literal, double quotes still expand `$` and
    backticks. A format validator, not a sandbox or a shell emulator: `sh -c '...'` is
    plain argv and passes.
    """
    # ponytail: brace expansion ({a,b}) and "\$" inside double quotes (the shell passes
    # `$`, shlex passes `\$`) are not flagged; add them if a live command needs it.
    try:
        tokens = shlex.split(command)
    except ValueError as exc:
        return f"does not split as argv ({exc})"
    if not tokens:
        return "is empty"
    if tokens[0] == "":
        return "has an empty executable"
    quote = None
    word_start = True
    first_word = True
    i, n = 0, len(command)
    while i < n:
        c = command[i]
        if quote == "'":
            if c == "'":
                quote = None
            i += 1
            continue
        if quote == '"':
            if c == "\\":
                i += 2
                continue
            if c == '"':
                quote = None
            elif c == "`":
                return "uses command substitution (`)"
            elif c == "$" and (why := _expansion(command, i)):
                return why
            i += 1
            continue
        if c == "\\":
            if i + 1 < n and command[i + 1] in "\r\n":
                return "uses a line continuation"
            i += 2
            word_start = False
            continue
        if c in " \t":
            if not word_start:
                first_word = False
            word_start = True
            i += 1
            continue
        if c in "\r\n":
            return "separates commands with a newline"
        if c in _OPERATOR_CHARS:
            j = i
            while j < n and command[j] in _OPERATOR_CHARS:
                j += 1
            return f"uses the shell operator {command[i:j]!r}"
        if c == "`":
            return "uses command substitution (`)"
        if c == "$" and (why := _expansion(command, i)):
            return why
        if word_start:
            if c == "#":
                return "starts a shell comment (#)"
            if c == "~":
                return "uses tilde expansion (~)"
            if first_word and (m := _ASSIGNMENT.match(command, i)):
                return f"sets an environment variable ({m.group(0)})"
        if c in _GLOB_CHARS:
            return f"uses an unquoted glob character ({c!r}); quote a pattern the program reads itself"
        if c in "'\"":
            quote = c
        word_start = False
        i += 1
    return None


def _expansion(command: str, i: int) -> str | None:
    nxt = command[i + 1] if i + 1 < len(command) else ""
    if nxt in ("(", "{", "_") or nxt.isalnum() or nxt in _SPECIAL_PARAMS:
        return f"uses shell expansion (${nxt})"
    return None


def run_command(
    command: str, cwd: Path, sha: str, *, timeout: int = 1800, env: dict | None = None, log_path: Path | None = None
) -> CommandRun:
    started_at = now_iso()
    start = time.monotonic()
    output = ""
    exit_status = 1
    error_class: str | None = None
    try:
        if (why := shell_syntax(command)) is not None:
            raise _InvalidCommand(f"command {why}; commands run as argv with no shell")
        args = shlex.split(command)
        proc = subprocess.run(
            args, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            timeout=timeout, env=env, check=False,
        )
        output = proc.stdout or ""
        exit_status = proc.returncode
    except FileNotFoundError as exc:
        output = str(exc)
        exit_status = 127
        error_class = "command-not-found"
    except subprocess.TimeoutExpired as exc:
        # R11: TimeoutExpired.stdout can be bytes even with text=True requested --
        # Popen only decodes output it reads to completion; the partial output a
        # timeout hands back comes straight from the pipe. Decode it the same way
        # a normal completion's text=True read would, so the regexes/digest/
        # write_text calls below see a str either way.
        output = exc.stdout or ""
        if isinstance(output, bytes):
            output = output.decode("utf-8", errors="replace")
        exit_status = 124
        error_class = "timeout"
    except _InvalidCommand as exc:
        # LF-53: refused before spawning; 127 is synthetic here, the errorClass says why.
        output = str(exc)
        exit_status = 127
        error_class = "invalid-command"
    except (ValueError, OSError) as exc:
        # A malformed command string (shlex.split) or an OS-level spawn failure (cwd
        # missing, not executable) is data for the caller too: a failing command is
        # never raised, only a genuinely bad input to run_command's own arguments is.
        output = str(exc)
        exit_status = 127
        error_class = "spawn-error"

    elapsed = time.monotonic() - start
    root = Path(cwd)
    runner = detect_runner(command)
    if log_path is not None:
        # Written so an operator can read a failing baseline's raw output; the digest
        # below still comes from the bytes, not the file, so it is correct even if the
        # write fails or the file is later moved.
        Path(log_path).write_text(output)
    candidates = fingerprint_candidates(output, root)
    fingerprint_lines: dict[str, str] = {}
    for line in candidates:
        fingerprint_lines.setdefault(_fingerprint_hash(line), line[:_LINE_CAP])
    kept = dict(list(fingerprint_lines.items())[:_FINGERPRINT_LINE_CAP])
    tail = [line[:_LINE_CAP] for line in normalize_output(output, root).splitlines() if line][-_TAIL_LINES:]
    return CommandRun(
        command=command, cwd=str(cwd), sha=sha, exit_status=exit_status, runner=runner,
        failure_identities=_parse(runner, output, root) if runner else [],
        fingerprints=sorted(fingerprint_lines),
        fingerprint_lines=kept, omitted_lines=len(fingerprint_lines) - len(kept), tail=tail,
        output_digest=digest_bytes(output.encode()),
        normalized_digest=digest_bytes(normalize_output(output, root).encode()),
        normalization_version=NORMALIZATION_VERSION,
        started_at=started_at, elapsed_seconds=elapsed, error_class=error_class,
        tests_ran=_count_tests_ran(output, runner), log_path=str(log_path) if log_path is not None else None,
    )


# ---------------------------------------------------------------------------
# Baseline capture
# ---------------------------------------------------------------------------


@dataclass
class BaselineEntry:
    command: str
    task: str | None
    status: Literal["ran", "no-baseline"]
    run: CommandRun | None

    def to_dict(self) -> dict:
        return {"command": self.command, "task": self.task, "status": self.status, "run": self.run.to_dict() if self.run else None}

    @classmethod
    def from_dict(cls, data: dict) -> "BaselineEntry":
        run = CommandRun.from_dict(data["run"]) if data.get("run") is not None else None
        return cls(command=data["command"], task=data["task"], status=data["status"], run=run)


@dataclass
class Baseline:
    base_sha: str
    repo: str
    prepare: str | None
    prepare_run: CommandRun | None
    entries: dict[str, BaselineEntry]
    captured_at: str
    normalization_version: int

    def to_dict(self) -> dict:
        return {
            "baseSha": self.base_sha,
            "repo": self.repo,
            "prepare": self.prepare,
            "prepareRun": self.prepare_run.to_dict() if self.prepare_run else None,
            "entries": {name: entry.to_dict() for name, entry in self.entries.items()},
            "capturedAt": self.captured_at,
            "normalizationVersion": self.normalization_version,
        }

    @classmethod
    def from_dict(cls, data: dict) -> "Baseline":
        prepare_run = CommandRun.from_dict(data["prepareRun"]) if data.get("prepareRun") is not None else None
        entries = {name: BaselineEntry.from_dict(entry) for name, entry in data["entries"].items()}
        return cls(
            base_sha=data["baseSha"], repo=data["repo"], prepare=data["prepare"], prepare_run=prepare_run,
            entries=entries, captured_at=data["capturedAt"], normalization_version=data["normalizationVersion"],
        )


def capture_baseline(
    repo: Path,
    base_sha: str,
    commands: list[tuple[str, str | None, str | None]],
    prepare: str | None,
    checkouts_dir: Path,
    repo_name: str,
) -> Baseline:
    checkout_dest = Path(checkouts_dir) / f"baseline-{base_sha[:12]}"
    repo_module.clean_checkout(repo, base_sha, checkout_dest)
    try:
        prepare_run = None
        if prepare:
            prepare_run = run_command(prepare, checkout_dest, base_sha)
            if prepare_run.exit_status != 0:
                raise LoopSpecError(
                    f"prepare command failed at base: {prepare}",
                    repair=f"run `{prepare}` by hand in {checkout_dest} against {base_sha} and fix it",
                )

        entries: dict[str, BaselineEntry] = {}
        for command, task_id, feature_added_path in commands:
            if command in entries:
                continue  # identical command strings run once; the dict is keyed by command
            if feature_added_path is not None:
                target = checkout_dest / feature_added_path
                if target.exists():
                    raise LoopSpecError(
                        f"featureAdded target {feature_added_path} already exists at base",
                        repair=f"pick a path for task {task_id} that does not exist at {base_sha}",
                    )
                entries[command] = BaselineEntry(command=command, task=task_id, status="no-baseline", run=None)
                continue
            entries[command] = BaselineEntry(
                command=command, task=task_id, status="ran", run=run_command(command, checkout_dest, base_sha)
            )

        return Baseline(
            base_sha=base_sha, repo=repo_name, prepare=prepare, prepare_run=prepare_run,
            entries=entries, captured_at=now_iso(), normalization_version=NORMALIZATION_VERSION,
        )
    finally:
        repo_module.remove_worktree(repo, checkout_dest, force=True)


def repo_baseline_dict(baseline_state: dict | None, repo_name: str, repos: dict) -> dict | None:
    """This repo's own Baseline dict (the shape `Baseline.to_dict()` returns) out
    of `store.state["baseline"]`.

    R3: a workspace's baseline is captured once per repo, keyed under
    `baseline_state["repos"][repo_name]`, since each repo has its own base SHA,
    prepare run, and verify-command entries -- a plan task's own repo names which
    one is its. A baseline captured before that shape existed is one flat
    Baseline dict for the whole workspace's first (and, before workspaces, only)
    repo; that only means anything when there is exactly one repo to attribute it
    to, so it is read as `repo_name`'s own baseline in that case and as nothing
    captured otherwise -- never guessed at for a workspace it can't be told apart
    for."""
    if baseline_state is None:
        return None
    repos_dict = baseline_state.get("repos")
    if repos_dict is not None:
        return repos_dict.get(repo_name)
    if len(repos) == 1 and repo_name in repos:
        return baseline_state
    return None


def all_baseline_entries(baseline_state: dict | None) -> list[dict]:
    """Every BaselineEntry dict across every repo's own baseline, for a check
    that only cares whether ANY command anywhere recorded a given fact (V6),
    never which repo it belongs to. Handles a pre-R3 flat baseline the same way
    repo_baseline_dict does."""
    if baseline_state is None:
        return []
    repos_dict = baseline_state.get("repos")
    if repos_dict is not None:
        return [entry for repo_dict in repos_dict.values() for entry in repo_dict.get("entries", {}).values()]
    return list(baseline_state.get("entries", {}).values())


# ---------------------------------------------------------------------------
# Comparison
# ---------------------------------------------------------------------------


@dataclass
class Comparison:
    verdict: Literal[
        "no-regression", "regression", "featureAdded-ok", "featureAdded-failed",
        "mustFlip-ok", "mustFlip-failed", "baseline-error",
    ]
    new_identities: list[str]
    detail: str

    def to_dict(self) -> dict:
        return {"verdict": self.verdict, "newIdentities": list(self.new_identities), "detail": self.detail}

    @classmethod
    def from_dict(cls, data: dict) -> "Comparison":
        return cls(verdict=data["verdict"], new_identities=list(data["newIdentities"]), detail=data["detail"])


def describe_failure(comparison: Comparison, run: CommandRun, limit: int = 20) -> list[str]:
    """What a person (or a retrying implementer) needs to read about a failing
    comparison: the new parsed identities, else the output lines behind new
    fingerprints, else the run's last lines (mustFlip, featureAdded, a run that never
    finished carry no identities at all)."""
    new = list(comparison.new_identities)
    if new and all(i in run.failure_identities for i in new):
        lines = new
    elif new:
        lines = [run.fingerprint_lines[h] for h in new if h in run.fingerprint_lines]
        missing = len(new) - len(lines)
        if missing:
            lines.append(f"({missing} failure line(s) past the stored {_FINGERPRINT_LINE_CAP} not shown)")
    else:
        lines = list(run.tail)
    if len(lines) > limit:
        lines = lines[:limit] + [f"({len(lines) - limit} more not shown)"]
    return lines


def _incomplete(run: CommandRun) -> bool:
    """True when `run` never finished in the way a comparison needs: either an
    execution/environment failure (run_command's own error classes -- timeout,
    command-not-found, spawn-error; there is no other path that sets one) or,
    with a recognized runner, a nonzero exit with nothing parsed (a collection/
    build failure -- the parser found no per-test failures because nothing ran,
    not because everything passed). Either way, a set of failure identities or
    fingerprints taken from it says nothing about what a FINISHED run would
    have found."""
    if run.error_class is not None:
        return True
    return run.runner is not None and run.exit_status != 0 and not run.failure_identities


def compare_to_baseline(entry: BaselineEntry, candidate: CommandRun, *, feature_added: bool = False, must_flip: bool = False) -> Comparison:
    baseline_run = entry.run

    if baseline_run is None and not feature_added:
        return Comparison("baseline-error", [], "no baseline run was recorded for this command")

    if must_flip:
        if baseline_run is None or baseline_run.exit_status == 0:
            return Comparison("mustFlip-failed", [], "reproduction did not fail at base")
        if candidate.exit_status == 0:
            return Comparison("mustFlip-ok", [], "reproduction no longer fails")
        return Comparison("mustFlip-failed", [], "reproduction still fails at the candidate commit")

    if feature_added:
        if candidate.exit_status != 0:
            return Comparison("featureAdded-failed", [], "feature-added command did not exit 0")
        if candidate.runner is not None and candidate.failure_identities:
            return Comparison("featureAdded-failed", list(candidate.failure_identities), "feature-added command reported failures")
        if candidate.runner not in (None, "diagnostics") and candidate.tests_ran == 0:
            # Exit 0 with zero parsed failures also happens when zero tests were
            # collected; tests_ran (counted from the raw output at capture time,
            # since CommandRun keeps only digests) is what tells the two apart.
            return Comparison("featureAdded-failed", [], "no test ran")
        return Comparison("featureAdded-ok", [], "feature-added command passed")

    # R4 (plus the round-2 residual): classify each run's own completion BEFORE
    # ever comparing failure identities or fingerprints -- a run that did not
    # finish might have found more had it actually finished, so an overlapping
    # (even IDENTICAL) id or fingerprint set out of it is never "no-regression"
    # on its own. Only a baseline stuck in the exact same broken state (same
    # error class, same fingerprints) excuses a candidate that also didn't
    # finish; a baseline that did not finish but the candidate does not
    # reproduce leaves E7 undecidable rather than guessed at either way.
    candidate_incomplete = _incomplete(candidate)
    baseline_incomplete = _incomplete(baseline_run)
    if baseline_run.normalization_version != candidate.normalization_version and (
            candidate_incomplete or candidate.runner is None or baseline_run.runner is None):
        # Fingerprints from two normalization rules are not comparable (a run resumed
        # across an upgrade is refused before it gets here; this is the backstop).
        return Comparison("baseline-error", [], f"baseline normalization v{baseline_run.normalization_version}, "
                                                f"candidate v{candidate.normalization_version}")
    if candidate_incomplete:
        same_pre_existing_failure = (
            baseline_incomplete and baseline_run.error_class == candidate.error_class
            and set(candidate.fingerprints) == set(baseline_run.fingerprints)
        )
        if same_pre_existing_failure:
            return Comparison("no-regression", [], "same pre-existing collection/runner failure as base")
        if baseline_incomplete:
            return Comparison("baseline-error", [], "baseline run hit an environment error; E7 cannot be decided")
        detail = (
            f"candidate did not complete ({candidate.error_class}, exit {candidate.exit_status})"
            if candidate.error_class is not None
            else f"runner failed before collecting tests (exit {candidate.exit_status})"
        )
        return Comparison("regression", [], detail)
    if baseline_incomplete:
        return Comparison("baseline-error", [], "baseline run hit an environment error; E7 cannot be decided")

    if candidate.runner is not None and baseline_run.runner is not None:
        new_identities = sorted(set(candidate.failure_identities) - set(baseline_run.failure_identities))
    else:
        new_identities = sorted(set(candidate.fingerprints) - set(baseline_run.fingerprints))

    if new_identities:
        return Comparison("regression", new_identities, "new failure identity not present at base")
    return Comparison("no-regression", [], "no new failure identity versus base; exit status alone never decides")


def evidence_matches(claimed: dict, rerun: CommandRun) -> tuple[bool, str]:
    try:
        claimed_command = " ".join(shlex.split(claimed.get("command", "")))
        rerun_command = " ".join(shlex.split(rerun.command))
    except ValueError:
        return False, "command does not split as argv"
    if claimed_command != rerun_command:
        return False, "command differs"
    if claimed.get("sha") != rerun.sha:
        return False, "sha differs"
    if claimed.get("exitStatus") != rerun.exit_status:
        return False, "exitStatus differs"
    if sorted(claimed.get("failureIdentities") or []) != sorted(rerun.failure_identities):
        return False, "failureIdentities differ"
    if "normalizedDigest" in claimed and claimed["normalizedDigest"] != rerun.normalized_digest:
        return False, "normalizedDigest differs"
    return True, ""
