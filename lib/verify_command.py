#!/usr/bin/env python3
"""Check shell syntax and preserve literal inline interpreter programs; never run them."""
from pathlib import Path
import re
import subprocess
import sys


def words(command):
    """Yield shell words with expansion provenance, ignoring comments and heredoc bodies.

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
                yield None, False
            if c == '\n' and pending:
                for delimiter, strip_tabs in pending:
                    while i < len(command):
                        end = command.find('\n', i)
                        end = len(command) if end < 0 else end
                        line = command[i:end]
                        i = min(end + 1, len(command))
                        if (line.lstrip('\t') if strip_tabs else line) == delimiter:
                            break
                pending = []
            continue
        if c == '#':
            end = command.find('\n', i)
            i = len(command) if end < 0 else end
            continue
        if c in ';|&()<>':
            if command.startswith('<<', i) and not command.startswith('<<<', i):
                heredoc = command.startswith('<<-', i)
                i += 3 if heredoc else 2
            else:
                i += 1
            yield None, False
            continue
        value, expands, quote = [], False, None
        while i < len(command):
            c = command[i]
            if quote is None and (c.isspace() or c in ';|&()<>'):
                break
            if c == "'" and quote != '"':
                quote = None if quote == "'" else "'"
            elif c == '"' and quote != "'":
                quote = None if quote == '"' else '"'
            elif c == '\\' and quote != "'" and i + 1 < len(command):
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
        if heredoc is not None:
            pending.append((word, heredoc))
            heredoc = None
        yield word, expands


def validate(command):
    syntax = subprocess.run(['bash', '-n', '-c', command], capture_output=True, text=True)
    if syntax.returncode:
        raise ValueError('verifyCommand does not parse: ' + syntax.stderr.strip())
    interpreter = None
    program_next = False
    for word, expands in words(command):
        if word is None:
            interpreter, program_next = None, False
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
        elif interpreter:
            flags = ('-c',) if interpreter.startswith('python') else ('-e', '--eval', '-r')
            if word in flags:
                program_next = True
            elif any(word.startswith(flag + '=') or (len(flag) == 2 and word.startswith(flag)
                        and len(word) > 2) for flag in flags) and expands:
                raise ValueError('verifyCommand shell-expands an inline interpreter program; '
                                 'use a test file or literal quoted program')
            elif not word.startswith('-'):
                interpreter = None


if __name__ == '__main__':
    try:
        validate(sys.stdin.read())
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
