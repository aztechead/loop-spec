#!/usr/bin/env python3
"""Check shell syntax and preserve literal inline interpreter programs; never run them."""
from pathlib import Path
import re
import subprocess
import sys


def words(command):
    """Yield words, redirects, and heredoc bodies with expansion provenance.

    This is a lexical check, not a shell evaluator. Shell syntax is checked by bash.
    Operators delimit commands; quoted and escaped fragments remain a single word.
    """
    i = 0
    pending = []
    heredoc = None
    while i < len(command):
        c = command[i]
        if c.isspace():
            i += 1
            if c == '\n':
                yield 'boundary', None, False
            if c == '\n' and pending:
                for delimiter, strip_tabs, quoted in pending:
                    body = []
                    while i < len(command):
                        end = command.find('\n', i)
                        end = len(command) if end < 0 else end
                        line = command[i:end]
                        i = min(end + 1, len(command))
                        if (line.lstrip('\t') if strip_tabs else line) == delimiter:
                            break
                        body.append(line)
                    yield 'body', ''.join(body), not quoted and heredoc_expands('\n'.join(body))
                pending = []
            continue
        if c == '#':
            end = command.find('\n', i)
            i = len(command) if end < 0 else end
            continue
        if command.startswith('\\\n', i):
            i += 2
            continue
        if c in ';|&()<>':
            if command.startswith('<<<', i):
                i += 3
                yield 'here-string', None, False
            elif command.startswith('<<', i):
                heredoc = command.startswith('<<-', i)
                i += 3 if heredoc else 2
                yield 'heredoc', None, False
            elif c in '<>':
                i += 1
                if i < len(command) and command[i] in '<>&':
                    i += 1
                yield 'redirect', None, False
            else:
                i += 1
                yield 'boundary', None, False
            continue
        value, expands, quote = [], False, None
        quoted = False
        while i < len(command):
            c = command[i]
            if quote is None and (c.isspace() or c in ';|&()<>'):
                break
            if c == "'" and quote != '"':
                quoted = True
                quote = None if quote == "'" else "'"
            elif c == '"' and quote != "'":
                quoted = True
                quote = None if quote == '"' else '"'
            elif c == '\\' and quote != "'" and i + 1 < len(command):
                quoted = True
                following = command[i + 1]
                if quote is None or following in '$`"\\\n':
                    i += 1
                    if following != '\n':
                        value.append(following)
                else:
                    value.append(c)
            else:
                if quote != "'" and (c == '`' or (c == '$' and i + 1 < len(command)
                        and re.match(r'[\w{(*@#?$!\-]', command[i + 1]))):
                    expands = True
                value.append(c)
            i += 1
        word = ''.join(value)
        if word.isdigit() and i < len(command) and command[i] in '<>':
            continue  # A redirection descriptor is not an interpreter argument.
        if heredoc is not None:
            pending.append((word, heredoc, quoted))
            heredoc = None
        yield 'word', word, expands


def heredoc_expands(body):
    # Quotes in a heredoc body are literal; only backslash protects $, `, and \.
    body = re.sub(r'\\[$`\\\n]', '', body)
    return bool(re.search(r'`|\$(?=[\w{(*@#?$!\-])', body))


def validate(command):
    syntax = subprocess.run(['bash', '-n', '-c', command], capture_output=True, text=True)
    if syntax.returncode:
        raise ValueError('verifyCommand does not parse: ' + syntax.stderr.strip())
    interpreter = None
    program_next = False
    stdin_selected = False
    redirect = None
    bodies = []
    context = {"stdin_program": False}
    stdin_programs = []
    for kind, word, expands in words(command):
        if kind in ('heredoc', 'here-string', 'redirect'):
            redirect = kind
            continue
        if kind == 'body':
            stdin_programs.append((bodies.pop(0), expands))
            continue
        if kind == 'boundary':
            interpreter, program_next, stdin_selected = None, False, False
            context = {"stdin_program": False}
            continue
        if redirect:
            if redirect == 'heredoc':
                bodies.append(context)
            elif redirect == 'here-string':
                stdin_programs.append((context, expands))
            redirect = None
            continue
        if program_next:
            if expands:
                raise ValueError('verifyCommand shell-expands an inline interpreter program; '
                                 'use a test file, single-quoted program, or quoted heredoc, '
                                 'and pass dynamic values as arguments instead of interpolating code')
            interpreter, program_next = None, False
            continue
        name = Path(word).name
        if re.fullmatch(r'python(?:\d+(?:\.\d+)*)?|node(?:js)?|ruby|perl|php', name):
            interpreter = name
            stdin_selected = False
            context["stdin_program"] = True
        elif interpreter:
            flags = ('-c',) if interpreter.startswith('python') else ('-e', '--eval', '-r')
            if word in flags:
                program_next = True
                context["stdin_program"] = False
            elif any(word.startswith(flag + '=') or (len(flag) == 2 and word.startswith(flag)
                        and len(word) > 2) for flag in flags):
                if expands:
                    raise ValueError('verifyCommand shell-expands an inline interpreter program; '
                                     'use a test file or literal quoted program')
                context["stdin_program"] = False
                interpreter = None
            elif word == '-':
                stdin_selected = True
            elif not word.startswith('-') and not stdin_selected:
                interpreter = None
                context["stdin_program"] = False
    for source, expands in stdin_programs:
        if source["stdin_program"] and expands:
            raise ValueError('verifyCommand shell-expands an interpreter stdin program; '
                             'use a quoted heredoc or literal here-string')


if __name__ == '__main__':
    try:
        validate(sys.stdin.read())
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
