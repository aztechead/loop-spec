#!/usr/bin/env bash
# PreToolUse hook (Bash): a phase lead never launches a nested harness session.
#
# Why: after a HANDOFF the cycle skill says "print the marker and stop; the caller
# re-invokes". A live sonnet run did not stop: it wrote a round script around
# `claude -p /loop-spec:cycle` and spent its own budget a second time, and the
# handoff guard then denied the nested phase (the port plan,
# WP4 finding). The prose rule is in skills/cycle/SKILL.md; this is its enforcement.
#
# Denies (exit 2, reason on stderr) a Bash command that launches a headless harness CLI
# (`claude -p`, `claude --print`, `codex exec`, `opencode run`, `adk run`), at shell
# command positions or in literal executable calls inside interpreter payloads. Prose
# about a launcher inside a file the command only reads (grep/wc/sed/head/cat/...) is
# not a launch, and neither is a launcher named in a `#` comment inside a scanned script.
# The cycle launcher also has a runtime identity backstop in extensions/sessions/cycle_run.py.
# The bundled launchers are the exceptions, because spawning sessions is their job:
# extensions/sessions/session_run.py (the EXECUTE session rung) and the loop-runner
# scripts (the loop-fleet rung).
#
# Stands down (exit 0) when LOOP_SPEC_NESTED_SESSION_GUARD=0, when the project has no
# .loop-spec/ directory (never hijack an unrelated project), when the tool is not Bash,
# and on any unreadable payload (fail-open, like every guard here). Registered for
# Claude Code in hooks/hooks.json; hooks/pre-tool-guard.py adapts Codex,
# OpenCode, and ADK pre-tool callbacks to the same guard.
set -euo pipefail

if [[ "${LOOP_SPEC_NESTED_SESSION_GUARD:-1}" == "0" ]]; then
  exit 0
fi
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
if [[ ! -d "$PROJECT_DIR/.loop-spec" && ! -d "$PWD/.loop-spec" ]]; then
  exit 0
fi
command -v python3 >/dev/null 2>&1 || exit 0

INPUT=$(cat)
# simplicity: retain four-space Python indentation inside this shell boundary; extract
# a standalone scanner only if another hook needs the command-position parser.
VERDICT=$(printf '%s' "$INPUT" | NESTED_GUARD_CWD="$PWD" NESTED_GUARD_PROJECT_DIR="$PROJECT_DIR" python3 -c '
import json
import ast
import os
import re
import shlex
import sys

# This is deliberately evaluated on shell command positions, rather than the raw
# command text: a prompt, quoted argument, or source file may discuss a launcher.
LAUNCH = re.compile(r"(?:claude\s+(?:-p|--print)\b|codex\s+exec\b|opencode\s+run\b|adk\s+run\b)")
# The cycle runner is a harness launch even when it is hidden behind nohup/python3
# and therefore does not contain a native CLI name. Read-only commands never reach
# this check because only shell command positions and interpreter script arguments
# are scanned below.
CYCLE_RUNNER = re.compile(r"(?:^|/)(?:extensions/sessions/cycle_run\.py|lib/cycle-launch\.sh)$")
# The bundled launchers, matched as the path token the command runs, never as a
# substring anywhere in the line: a comment naming session_run.py next to a `claude -p`
# was a pass (port audit 1, F8).
LAUNCHERS = re.compile(r"(?:^|[\s\"\x27=])(?:[\w.~-]*/)*(?:extensions/sessions/session_run\.py|skills/loop-runner/scripts/[\w.-]+\.py)(?=$|[\s\"\x27])")
COMMENT = re.compile(r"(?:^|\s)#.*$", flags=re.M)


def strip_comments(text):
    # A hash inside a quoted string is data, not a comment: an echo of a quoted hash
    # followed by a launch on the same line still launches.
    out = []
    for line in text.splitlines():
        m = COMMENT.search(line)
        while m and (line[:m.start()].count("\"") % 2 or line[:m.start()].count("\x27") % 2):
            m = COMMENT.search(line, m.start() + 1)
        out.append(line[:m.start()] if m else line)
    return "\n".join(out)

# Interpreter words whose next non-flag argument is the script they run. Closed list: an
# interpreter this hook does not know about is not scanned, same as any other unknown
# command word (fail toward not-a-script, matching the command-position rule below).
INTERPRETERS = ("bash", "sh", "zsh", "dash", "ksh", "source", ".", "python", "python3", "node", "perl", "ruby")
# Prefix words that pass the command position through to the next word unconsumed
# (their own flags and flag values skipped, as for an interpreter).
PREFIXES = ("env", "nohup", "time", "exec", "sudo", "command", "timeout", "stdbuf", "setsid", "xargs")
OPERATORS = (";", "&", "&&", "||", "|", "(", "{")
CONTROL_WORDS = ("if", "then", "elif", "else", "fi", "for", "while", "until", "in", "do", "done", "case", "esac")
# After an interpreter, these end the script search: the program comes from stdin, a
# string, or a module, so the next word is data (`python3 - tasks.json <<PY` is the
# idiom this repo itself uses, and was a false deny).
NO_SCRIPT_FLAGS = ("-", "--", "-c", "-m", "-e", "-s")
ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
PREFIX_ARG = re.compile(r"^(?:-|\d+[smhd]?$|[A-Za-z_][A-Za-z0-9_]*=|\{\}$)")


def command_position_words(command):
    """Indices of tokens the shell would execute: the command word of a simple
    command, or the first non-flag argument after an interpreter word. Everything
    else (an argument to grep/wc/sed/head/cat/...) is never a script position."""
    # The shell reads a newline as `;`, and a backslash-newline as a space.
    flat = re.sub(r"\\\n", " ", command).replace("\n", " ; ")
    lex = shlex.shlex(flat, posix=True, punctuation_chars=";&|(){}")
    lex.whitespace_split = True
    try:
        tokens = list(lex)
    except ValueError:
        # An unbalanced quote must not switch the scan off: walk the raw words instead.
        tokens = flat.split()
    positions = []
    expect_cmd = True
    i = 0
    while i < len(tokens):
        tok = tokens[i]
        if tok in OPERATORS:
            expect_cmd = True
            i += 1
            continue
        if not expect_cmd:
            i += 1
            continue
        if tok in CONTROL_WORDS or ASSIGNMENT.match(tok):
            i += 1
            continue
        if tok in PREFIXES:
            # Its flags, KEY=value words, and bare counts or durations (`timeout 60`,
            # `xargs -n 1`) sit between the prefix and the command it wraps.
            i += 1
            while i < len(tokens) and tokens[i] not in OPERATORS and PREFIX_ARG.match(tokens[i]):
                i += 1
            continue
        positions.append(i)
        if tok in INTERPRETERS:
            j = i + 1
            while j < len(tokens) and tokens[j] not in OPERATORS and tokens[j].startswith("-") and tokens[j] not in NO_SCRIPT_FLAGS:
                j += 1
            if j < len(tokens) and tokens[j] not in OPERATORS and tokens[j] not in NO_SCRIPT_FLAGS:
                positions.append(j)
        expect_cmd = False
        i += 1
    return positions, tokens

def cycle_runner_word(command):
    positions, tokens = command_position_words(command)
    for idx in positions:
        if CYCLE_RUNNER.search(tokens[idx]):
            return tokens[idx]
    return ""

def payload_launch(code):
    """Inspect literal executable callsites in an interpreter payload."""
    try:
        tree = ast.parse(code)
    except (SyntaxError, ValueError):
        return ""
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call) or not node.args:
            continue
        func = node.func
        name = func.id if isinstance(func, ast.Name) else ""
        if isinstance(func, ast.Attribute) and isinstance(func.value, ast.Name):
            name = func.value.id + "." + func.attr
        try:
            literal = ast.literal_eval(node.args[0])
        except (ValueError, TypeError, SyntaxError):
            literal = None
        if name == "runpy.run_path" and isinstance(literal, str) and CYCLE_RUNNER.search(literal):
            return "cycle_run.py"
        if name not in ("os.system", "subprocess.run", "subprocess.call", "subprocess.Popen", "eval"):
            continue
        if isinstance(literal, str):
            text = literal
        elif name.startswith("subprocess.") and isinstance(literal, (list, tuple)) \
                and all(isinstance(item, str) for item in literal):
            text = " ".join(shlex.quote(item) for item in literal)
        else:
            continue
        if name == "eval":
            try:
                text = " ".join(shlex.split(text))
            except ValueError:
                continue
        nested = launcher_word(text) or cycle_runner_word(text)
        if nested:
            return nested
    return ""

def launcher_word(command):
    """Return a real nested launch at a command boundary, including shell/python
    wrappers whose executable payload is supplied with -c or runpy.run_path."""
    positions, tokens = command_position_words(command)
    for idx in positions:
        word = tokens[idx]
        base = os.path.basename(word)
        end = next((n for n in range(idx + 1, len(tokens)) if tokens[n] in OPERATORS), len(tokens))
        args = tokens[idx + 1:end]
        if base == "claude" and any(a in ("-p", "--print") for a in args):
            return "claude -p"
        if base == "codex" and "exec" in args:
            return "codex exec"
        if base == "opencode" and "run" in args:
            return "opencode run"
        if base == "adk" and "run" in args:
            return "adk run"
        if base in INTERPRETERS:
            # python3 cycle_run.py and python3 -m cycle_run are executable payloads.
            script = ""
            for a in args:
                if a in NO_SCRIPT_FLAGS:
                    if a in ("-c", "-e", "-m"):
                        break
                    continue
                if base in ("bash", "sh", "zsh", "dash", "ksh") and a.startswith("-") and not a.startswith("--") and "c" in a[1:]:
                    break
                if a.startswith("-"):
                    continue
                script = a
                break
            if CYCLE_RUNNER.search(script) or script in ("cycle_run", "extensions.sessions.cycle_run"):
                return script or "cycle_run"
            if "-m" in args:
                module = args[args.index("-m") + 1] if args.index("-m") + 1 < len(args) else ""
                if module in ("cycle_run", "extensions.sessions.cycle_run"):
                    return module
            if script:
                continue
            # `bash -c` / `python3 -c` carries a second command language. Scan only
            # the code argument; ordinary prompt data remains opaque.
            code_index = None
            for n, arg in enumerate(args):
                if arg == "-c" or (base in ("bash", "sh", "zsh", "dash", "ksh") and
                                    arg.startswith("-") and not arg.startswith("--") and "c" in arg[1:]):
                    code_index = n + 1
                    break
            if code_index is not None:
                code = args[code_index] if code_index < len(args) else ""
                try:
                    shell_tokens = shlex.split(command)
                    shell_pos = shell_tokens.index(word)
                    for candidate in shell_tokens[shell_pos + 1:]:
                        if candidate in ("-c", "-e"):
                            code_pos = shell_tokens.index(candidate, shell_pos + 1) + 1
                            if code_pos < len(shell_tokens):
                                code = shell_tokens[code_pos]
                            break
                except (ValueError, IndexError):
                    pass
                nested = launcher_word(code) or cycle_runner_word(code)
                if nested:
                    return nested
                eval_code = re.match(r"\s*eval\s+(.+)$", code, flags=re.S)
                if eval_code:
                    literal = re.match(r"\s*([\"\x27])(.*?)\1\s*$", eval_code.group(1), flags=re.S)
                    eval_text = literal.group(2) if literal else eval_code.group(1)
                    nested = launcher_word(eval_text) or cycle_runner_word(eval_text)
                    if nested:
                        return nested
                nested = payload_launch(code)
                if nested:
                    return nested
    return ""


try:
    payload = json.load(sys.stdin)
except Exception:
    print("allow")
    raise SystemExit(0)
if str(payload.get("tool_name") or "") != "Bash":
    print("allow")
    raise SystemExit(0)
command = str((payload.get("tool_input") or {}).get("command") or "")
found_label = launcher_word(command)
found = bool(found_label)
where = "the command"
if not found:
    # A launch hidden in a script the command runs: scan only the files that sit in a
    # position the shell would execute (command word, or interpreter argument) — never
    # a file the command merely reads (grep/wc/sed/head/... target).
    positions, tokens = command_position_words(command)
    project_dir = os.environ.get("NESTED_GUARD_PROJECT_DIR") or os.getcwd()
    cwd = os.environ.get("NESTED_GUARD_CWD") or os.getcwd()
    for idx in positions:
        word = tokens[idx]
        if CYCLE_RUNNER.search(word):
            found = True
            found_label = word
            where = word
            break
        if os.path.isabs(word):
            candidates = [word]
        else:
            candidates = [os.path.join(project_dir, word), os.path.join(cwd, word)]
        # Both roots are scanned: a script shadowed by a same-named file in the other
        # root would otherwise decide the verdict for the one the shell runs.
        for path in (c for c in candidates if os.path.isfile(c)):
            try:
                with open(path, "rb") as fh:
                    text = fh.read(64 * 1024).decode("utf-8", errors="replace")
            except OSError:
                continue
            if LAUNCHERS.search(" " + path):
                continue
            # A launcher named only in a `#` comment inside the script is not a launch it runs.
            script_text = strip_comments(text)
            found_label = launcher_word(script_text)
            found = bool(found_label)
            interpreter_script = any(tokens[j] in INTERPRETERS and idx == j + 1 for j in range(idx))
            if not found and interpreter_script:
                # A module passed to an interpreter is executable input even when
                # its launcher is only mentioned in a docstring.
                found = bool(LAUNCH.search(script_text))
                found_label = "nested harness" if found else ""
            if not found:
                cycle = cycle_runner_word(script_text)
                if cycle:
                    found = True
                    found_label = cycle
            if found:
                if not found_label:
                    found_label = "nested harness"
                where = word
                break
        if found:
            break
if found:
    print("deny\t%s\t%s" % (found_label, where))
else:
    print("allow")
' 2>/dev/null || echo "allow")

case "$VERDICT" in
  deny*)
    IFS=$'\t' read -r _ launch where <<<"$VERDICT"
    cat >&2 <<MSG
loop-spec: a phase lead never launches a nested harness session ($launch in $where).
After HANDOFF, print the LOOP_SPEC_HANDOFF marker and stop; the caller re-invokes
/loop-spec:cycle. EXECUTE's session rung is launched by the driver
(cycle-driver.sh task run, through extensions/sessions/session_run.py) and the
loop-fleet rung through the loop-runner scripts (skills/cycle/SKILL.md, HANDOFF).
MSG
    exit 2
    ;;
esac
exit 0
