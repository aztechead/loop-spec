#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export OKF_ROOT="$ROOT"
python3 - <<'PY'
import os, pathlib, tempfile, subprocess, sys, tracemalloc, builtins
sys.path.insert(0, os.environ['OKF_ROOT'] + '/lib')
from okf import *
passed = failed = 0
def check(name, fn):
    global passed, failed
    try: fn(); print('PASS:', name); passed += 1
    except Exception as exc: print('FAIL:', name, exc); failed += 1
def reject(fn):
    try: fn()
    except ValueError: return
    raise AssertionError('invalid input accepted')
def reject_message(fn, needle):
    try: fn()
    except ValueError as exc:
        if needle not in str(exc): raise AssertionError(str(exc))
        return
    raise AssertionError('invalid input accepted')
def yes(v):
    if not v: raise AssertionError('assertion failed')
text = '---\ntype: Unknown\ncustom: [a,b]\nverified: {by: human:x}\n---\nbody\r\n'
check('normal unknown metadata', lambda: yes(split_document(text)[0]['type'] == 'Unknown'))
check('body preserved', lambda: yes(split_document(text)[1] == 'body\r\n'))
check('render preserves body', lambda: yes(render_document(*split_document(text)).endswith('body\r\n')))
check('nonmapping rejected', lambda: reject(lambda: split_document('---\n- x\n---\n')))
check('malformed rejected', lambda: reject(lambda: split_document('---\ntype: [\n---\n')))
def malformed_read_before_body():
    target = pathlib.Path(tempfile.mktemp()); target.write_bytes(b'---\ntype: [\n---\n' + b'x' * 1000000)
    real_open = builtins.open
    class Guard:
        def __init__(self, fh): self.fh = fh
        def __enter__(self): return self
        def __exit__(self, *args): return self.fh.close()
        def readline(self, *args): return self.fh.readline(*args)
        def read(self, *args): raise AssertionError('body read before malformed header rejection')
    builtins.open = lambda path, *args, **kwargs: Guard(real_open(path, *args, **kwargs)) if os.fspath(path) == os.fspath(target) else real_open(path, *args, **kwargs)
    try: reject(lambda: read_document(target))
    finally: builtins.open = real_open; target.unlink()
check('read_document rejects malformed header before body', malformed_read_before_body)
check('empty type rejected', lambda: reject(lambda: split_document('---\ntype: ""\n---\n')))
check('duplicate key rejected', lambda: reject(lambda: split_document('---\ntype: A\ntype: B\n---\n')))
check('unsafe tag rejected', lambda: reject(lambda: split_document('---\ntype: !!python/object/apply:os.system [x]\n---\n')))
check('unhashable mapping key rejected', lambda: reject(lambda: split_document('---\ntype: T\n? [a, b]\n: value\n---\n')))
aliases = ', '.join(['*x'] * 1001)
check('alias limit rejected', lambda: reject_message(lambda: split_document('---\ntype: T\nx: &x {v: 1}\nitems: [' + aliases + ']\n---\n'), 'aliases'))
check('nesting limit rejected', lambda: reject(lambda: split_document('---\ntype: T\na: ' + '[' * 110 + 'x' + ']' * 110 + '\n---\n')))
check('optional fields absent', lambda: yes(split_document('---\ntype: T\n---\n')[0] == {'type':'T'}))
check('bare verified normalized', lambda: yes(normalize_verified(split_document(text)[0])['verified'][0]['by'] == 'human:x'))
check('oversized header rejected', lambda: reject_message(lambda: split_document('---\ntype: T\nvalue: ' + 'a' * 70000 + '\n---\n'), '65536'))
tempdir = tempfile.TemporaryDirectory(); root = pathlib.Path(tempdir.name); p = root / 'a.md'; p.write_bytes(b'---\ntype: T\n---\n' + b'x' * 10000000)
def bounded():
    tracemalloc.start(); yes(read_metadata(p)['type'] == 'T'); _, peak = tracemalloc.get_traced_memory(); tracemalloc.stop(); yes(peak < 2000000)
check('large body metadata bounded', bounded)
p.write_bytes(b'---\ntype: T\n---\n\xff'); check('invalid body UTF8 rejected', lambda: reject(lambda: validate_utf8(p)))
(root/'a.md').write_text('---\ntype: T\n---\nA\n'); (root/'sub').mkdir(); (root/'sub'/'b.md').write_text('---\ntype: T\n---\nB\n')
(root/'c.md').write_text('---\ntype: T\ntitle: "Line one\\nLine two"\ndescription: "Desc one\\nDesc two"\n---\nC\n')
run = lambda *args: subprocess.run(['bash', os.environ['OKF_ROOT']+'/lib/okf.sh', *args], check=True, capture_output=True)
check('index and bundle', lambda: (run('index', str(root)), run('bundle-check', str(root))))
check('index flattens multiline metadata', lambda: yes('Line one Line two' in (root/'index.md').read_text() and 'Desc one Desc two' in (root/'index.md').read_text()))
check('bundle typed generic accepted', lambda: run('bundle-check', str(root), '--types', '{"a.md":"T"}'))
check('bundle typed matching accepted', lambda: run('bundle-check', str(root), '--types', '{"c.md":"T"}'))
def bundle_mismatch():
    result = subprocess.run(['bash', os.environ['OKF_ROOT']+'/lib/okf.sh', 'bundle-check', str(root), '--types', '{"a.md":"Wrong"}'], text=True, capture_output=True)
    yes(result.returncode == 1 and "expected type 'Wrong', found 'T'" in result.stderr)
check('bundle typed mismatch rejected', bundle_mismatch)
inode = (root/'index.md').stat().st_ino; mtime = (root/'index.md').stat().st_mtime_ns
check('index idempotent', lambda: (run('index', str(root)), yes((root/'index.md').stat().st_ino == inode and (root/'index.md').stat().st_mtime_ns == mtime)))
(root/'index.md').write_bytes(b'---\nokf_version: "0.2"\n---\n# Concepts\n' + b'x\n' * 5000000)
check('huge existing index replaced without unbounded compare', lambda: run('index', str(root)))
(root/'sub'/'index.md').write_text('# Nested\n'); check('nested index no frontmatter', lambda: validate_index(root/'sub'/'index.md'))
check('CRLF root index accepted', lambda: ((root/'index.md').write_bytes(b'---\r\nokf_version: "0.2"\r\n---\r\n# Concepts\r\n'), validate_index(root/'index.md', True)))
check('root index frontmatter optional', lambda: ((root/'index.md').write_text('# Concepts\n'), validate_index(root/'index.md', True)))
check('invalid UTF8 after index heading rejected', lambda: (p.write_bytes(b'# Concepts\n\xff'), reject(lambda: validate_index(p, True))))
check('oversized root index header rejected', lambda: (p.write_bytes(b'---\n' + b'x' * 70000 + b'\n---\n# Concepts\n'), reject(lambda: validate_index(p, True))))
def reserved_bounded():
    p.write_bytes(b'# Concepts\n' + (b'x\n' * 5000000))
    tracemalloc.start(); validate_index(p, True); _, peak = tracemalloc.get_traced_memory(); tracemalloc.stop(); yes(peak < 2000000)
check('large reserved body bounded', reserved_bounded)
(root/'a.md').write_text('---\ntype: Generic Unknown\n---\nA\n')
def mismatch():
    result = subprocess.run(['bash', os.environ['OKF_ROOT']+'/lib/okf.sh', 'check', str(root/'a.md'), '--type', 'Wrong'], text=True, capture_output=True)
    yes(result.returncode == 1 and "expected type 'Wrong', found 'Generic Unknown'" in result.stderr)
check('application type mismatch', mismatch)
print('Results: %d passed, %d failed' % (passed, failed)); raise SystemExit(bool(failed))
PY
