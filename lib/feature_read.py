#!/usr/bin/env python3
"""One typed reader for feature.json.

Every `jq ... feature.json` in lib/ used to be its own reader: 248 of them, each
free to name a key the schema never declared and to fail in its own way when the
file was absent. This module is the one place feature state is read, and the key
space it accepts is the `stateKey` enum of graph/schema.json, loaded at call time
(the same enum that types node reads and writes), so a misspelled or undeclared
key is an error here instead of a silent null three scripts later.
tests/feature-read-coverage.test.sh keeps the other readers from coming back.

Usage (lib/feature-read.sh is the launcher):
  feature_read.py <feature-dir|feature.json> <key>[.<sub>...|[<n>]...] [-r] [--default <json>] [--jq <filter>]
  feature_read.py <feature-dir|feature.json> [-r|-c] [-e] --filter <jq filter> [-- <jq args>]
  feature_read.py <feature-dir|feature.json> --all
  feature_read.py <feature-dir|feature.json> --strays
  feature_read.py --keys

  <key>      a stateKey; the dotted path below it descends objects and arrays
  -r         print a string bare and null as nothing (jq -r); other values as JSON
  --default  the JSON printed when the path is absent or null (default: null)
  --jq       shape the value with a jq filter written against it (`.repos[].path`
             under `workspace`), so a caller keeps jq's reach below a typed key
  --filter   a jq filter written against the whole document, the way the old readers
             wrote it. The top-level keys it names (`.slug`, `(.workspace`, `| .branch`)
             are typed: one outside the enum is exit 1, and only those keys are handed
             to jq, so the filter cannot read what it did not name. -c/-r/-e and any
             `--arg`/`--argjson` after `--` pass to jq; jq's exit code is relayed.
  --all      the whole document projected onto the enum (a key the schema does not
             declare is dropped), compact, for the readers that render all of it (the
             run digest, the status dashboard, the egress diff)
  --strays   the top-level keys the enum does NOT declare, with their values, compact.
             The one consumer is lib/phase-exit.sh's egress guard, whose job is to name a
             write outside the schema; every other reader takes the typed view.
  --keys     print the accepted key space, one per line

Exit 0 printed; 1 the key is not a stateKey (the message names the enum); 2 the
feature.json is missing or unreadable, or the invocation is wrong.
"""
from __future__ import print_function

import json
import os
import re
import subprocess
import sys

SCHEMA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "graph", "schema.json")
PATH_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*|\[[0-9]+\])*$")
# A root-level key in a jq filter: `.name` not preceded by a path character, a quote,
# or a `$` (so `.a.b`, `x[0].b`, `$v.b`, `"a.b"` do not read as roots).
FILTER_KEY_RE = re.compile(r'(?<![A-Za-z0-9_"$.\])])\.([A-Za-z_][A-Za-z0-9_]*)')
SEGMENT_RE = re.compile(r"\.?([A-Za-z_][A-Za-z0-9_]*)|\[([0-9]+)\]")


def state_keys():
    with open(SCHEMA, "r", encoding="utf-8") as fh:
        return list(json.load(fh)["definitions"]["stateKey"]["enum"])


def filter_keys(jq_filter, keys):
    """The root keys a document filter reads. Before the first `|` every `.name` is a
    root and must be a state key; after a pipe `.name` is usually a field of what the
    pipe produced (`.gateHistory[] | select(.phase == $g)`), so there only names that
    ARE state keys count, which over-reads harmlessly and never mis-types."""
    head, _, tail = jq_filter.partition("|")
    roots = []
    for name in FILTER_KEY_RE.findall(head):
        if name not in keys:
            raise ValueError("{!r} in filter {!r} is not a feature.json state key (graph/schema.json stateKey)".format(name, jq_filter))
        roots.append(name)
    roots.extend(n for n in FILTER_KEY_RE.findall(tail) if n in keys)
    if not roots:
        raise ValueError("filter {!r} names no state key; read a key (feature-read.sh <dir> <key>) instead".format(jq_filter))
    return sorted(set(roots))


def load_state(target):
    file_path = target if os.path.basename(target) == "feature.json" else os.path.join(target, "feature.json")
    try:
        with open(file_path, "r", encoding="utf-8") as fh:
            state = json.load(fh)
    except (IOError, OSError) as exc:
        raise IOError("cannot read {}: {}".format(file_path, exc.strerror or exc))
    except ValueError as exc:
        raise IOError("{} is not JSON: {}".format(file_path, exc))
    if not isinstance(state, dict):
        raise IOError("{} is not a JSON object".format(file_path))
    return state


def descend(state, path):
    """Walk the dotted path; None once any step is absent, null, or of the wrong shape."""
    value = state
    for name, index in SEGMENT_RE.findall(path):
        if name:
            if not isinstance(value, dict):
                return None
            value = value.get(name)
        else:
            if not isinstance(value, list) or int(index) >= len(value):
                return None
            value = value[int(index)]
        if value is None:
            return None
    return value


def main(argv):
    if argv == ["--keys"]:
        print("\n".join(state_keys()))
        return 0
    if len(argv) == 2 and argv[1] in ("--all", "--strays"):
        keys = state_keys()
        state = load_state(argv[0])
        wanted = (lambda k: k in keys) if argv[1] == "--all" else (lambda k: k not in keys)
        print(json.dumps({k: v for k, v in state.items() if wanted(k)}, ensure_ascii=False, separators=(",", ":")))
        return 0
    raw = False
    compact = False
    exit_status = False
    default = "null"
    jq_filter = None
    doc_filter = None
    jq_args = []
    positional = []
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--":
            jq_args = argv[i + 1:]
            break
        if arg == "-r":
            raw = True
        elif arg == "-c":
            compact = True
        elif arg == "-e":
            exit_status = True
        elif arg in ("-er", "-re"):
            raw = exit_status = True
        elif arg in ("-cr", "-rc"):
            raw = compact = True
        elif arg == "--filter":
            if i + 1 >= len(argv):
                raise ValueError("--filter takes a jq filter")
            doc_filter = argv[i + 1]
            i += 1
        elif arg == "--default":
            if i + 1 >= len(argv):
                raise ValueError("--default takes a JSON value")
            default = argv[i + 1]
            i += 1
        elif arg == "--jq":
            if i + 1 >= len(argv):
                raise ValueError("--jq takes a filter")
            jq_filter = argv[i + 1]
            i += 1
        else:
            positional.append(arg)
        i += 1
    keys = state_keys()
    if doc_filter is not None:
        if len(positional) != 1 or jq_filter is not None:
            raise ValueError("usage: feature-read.sh <feature-dir|feature.json> [-r|-c] [-e] --filter <jq filter> [-- <jq args>]")
        state = load_state(positional[0])
        subset = {k: state.get(k) for k in filter_keys(doc_filter, keys)}
        cmd = ["jq"] + (["-r"] if raw else []) + (["-c"] if compact else []) + (["-e"] if exit_status else []) + jq_args + [doc_filter]
        proc = subprocess.run(cmd, input=json.dumps(subset, ensure_ascii=False), stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, universal_newlines=True)
        sys.stdout.write(proc.stdout)
        if proc.stderr:
            sys.stderr.write(proc.stderr)
        return proc.returncode
    if len(positional) != 2:
        raise ValueError("usage: feature-read.sh <feature-dir|feature.json> <key>[.<sub>...] [-r] [--default <json>] [--jq <filter>] | --keys")
    target, path = positional
    if not PATH_RE.match(path):
        raise ValueError("path {!r} is not <key>(.<sub>|[n])*".format(path))
    key = SEGMENT_RE.match(path).group(1)
    if key not in keys:
        raise ValueError("{!r} is not a feature.json state key (graph/schema.json stateKey: {})".format(key, ", ".join(keys)))
    try:
        fallback = json.loads(default)
    except ValueError:
        raise ValueError("--default {!r} is not JSON".format(default))

    state = load_state(target)
    value = descend(state, path)
    if value is None:
        value = fallback
    if jq_filter is not None:
        # jq shapes the value the same way it shaped the file before: exit 5 (a filter
        # that fails on this value) and a parse error stay jq's own, relayed as exit 1.
        proc = subprocess.run(["jq", "-r" if raw else "-c", jq_filter],
                              input=json.dumps(value, ensure_ascii=False), stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, universal_newlines=True)
        if proc.returncode != 0:
            raise ValueError("jq {!r} on {}: {}".format(jq_filter, path, proc.stderr.strip()))
        sys.stdout.write(proc.stdout)
        return 0
    if raw:
        if value is None:
            print("")
        elif isinstance(value, str):
            print(value)
        else:
            print(json.dumps(value, ensure_ascii=False, separators=(",", ":")))
    else:
        print(json.dumps(value, ensure_ascii=False, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except ValueError as exc:
        print("feature-read: {}".format(exc), file=sys.stderr)
        sys.exit(1)
    except IOError as exc:
        print("feature-read: {}".format(exc), file=sys.stderr)
        sys.exit(2)
