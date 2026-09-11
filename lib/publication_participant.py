#!/usr/bin/env python3
"""publication_participant - one feature-state ingress token per driver operation.

Why: every lib/graph/driver.py command performs exactly one publication operation (an
"ingress"): it captures a token once, carries it across model and subprocess work, and
offers only its own accepted refresh to its own next write -- never re-capturing to let
stale work pass (docs/loop-spec/features/release-7-0's task-004 contract). Bash
participants get this for free from lib/feature-write.sh's sourced helpers
(loop_spec_publication_begin/run/lib); driver.py runs in one long-lived process instead
of a fresh shell per step, so this module is that process's equivalent: a private temp
file holds the current token, `token_args()`/`child_env()` hand it to feature_write.py
and to child subprocesses, and `adopt()`/`adopt_output()` swap in whichever refresh a
write or a child accepted.

Usage -- module functions operate on one process-wide operation; driver.py runs exactly
one operation per invocation (one `cycle-driver.sh <command>`), so a module-level
singleton matches that lifetime and needs no instance to thread through every call:
    begin(feature_dir, read_only=False)
        Capture the ingress token, adopting an inherited LOOP_SPEC_PUBLICATION_TOKEN env
        file when this process is itself somebody else's child. Call once per command,
        as soon as feature.json exists; calling it again would re-capture and let a
        child's stale work through. A token-less feature (no artifactPublication) leaves
        the private file holding `null`; every other function then degrades to the
        pre-publication, plain-write behavior.
    token_args()
        ["--token", path] for a feature_write.py CLI call, or [] for a null token.
    child_env(base)
        `base` with LOOP_SPEC_PUBLICATION_TOKEN/LOOP_SPEC_PUBLICATION_TOKEN_OUTPUT set
        for one subprocess. Call once per subprocess; read the output path back out of
        the returned dict and pass it to adopt() when that subprocess returns.
    adopt(received_path)
        Copy a child's accepted refresh over our private token, then remove the child's
        temp file. A plain (not-yet-converted) child leaves the file empty or absent --
        adopt() is then a no-op, and the caller stays on its now-stale token on purpose
        (task-004 WP3 names the three children this is still expected for).
    adopt_output(text)
        Same adoption, from a refresh a direct feature_write.py CLI call printed to
        stdout (feature-write.sh prints the refreshed token when --token was given)
        rather than through a child's output file.
    current()
        The token this operation would publish against next, or None for a token-less
        feature. lib/graph/driver.py's publish_artifact/retire_artifact/publish_spec
        read it from here to build their own publish_locked manifest, rather than
        reaching into this module's private token file -- the one place other than
        adopt()/adopt_output() that is allowed to see it. A no-op read: it never
        recaptures (task-004 removed the `refresh` this module used to expose for
        that; a participant NEVER re-captures a token to legitimize work it already
        did, it publishes that work and adopts the refresh publish_locked returns).
    active()
        True once begin() has captured a non-null token for this operation.
    finish()
        Hand the final token to our own parent's LOOP_SPEC_PUBLICATION_TOKEN_OUTPUT, if
        one was inherited, and remove this operation's temp file. Call once, from the
        command's exit path (including on a Die), never mid-operation.

`bash lib/surface.sh show publication_participant` reads this header.
"""
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from feature_write import begin_operation, read_bounded  # noqa: E402

_token_path = None


def begin(feature_dir, read_only=False, token_path=None):
    """`token_path`, when given, overrides the inherited LOOP_SPEC_PUBLICATION_TOKEN env
    file for this one capture -- a caller's own explicit `--token PATH` argument, which
    a bare env pair cannot express (lib/graph/driver.py's `cmd_spec` accepts either)."""
    global _token_path
    incoming = token_path or os.environ.get("LOOP_SPEC_PUBLICATION_TOKEN")
    supplied = json.loads(read_bounded(Path(incoming))) if incoming else None
    token = begin_operation(feature_dir, token=supplied, bootstrap=not read_only)
    # A nested call (one cmd_* handler invoking another in-process, e.g. cmd_next's own
    # cmd_escalate) re-begins on the same feature: drop the superseded file rather than
    # leaking one temp file per nested call in a long-lived process.
    if _token_path is not None:
        try:
            os.remove(_token_path)
        except OSError:
            pass
    descriptor, path = tempfile.mkstemp(prefix="loop-spec-publication.")
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        json.dump(token, stream)
    _token_path = path
    return token


def has_begun():
    """True once begin() has captured an ingress for this process (a null token counts:
    it still means begin() ran). Lets a module that may run in-process under a caller
    that already began (driver.py's engine.step_once) or standalone (lib/graph/run.sh)
    skip a redundant re-capture without duplicating that check itself."""
    return _token_path is not None


def active():
    return _token_path is not None and current() is not None


def current():
    """The token this operation would publish against next, or None for a token-less
    feature. See the module docstring: this is the one place other than
    adopt()/adopt_output() that is allowed to see the private token file's content."""
    if _token_path is None:
        return None
    with open(_token_path, encoding="utf-8") as stream:
        return json.load(stream)


def token_args():
    return [] if current() is None else ["--token", _token_path]


def child_env(base):
    env = dict(base)
    if _token_path is None:
        env.pop("LOOP_SPEC_PUBLICATION_TOKEN", None)
        env.pop("LOOP_SPEC_PUBLICATION_TOKEN_OUTPUT", None)
        return env
    descriptor, received = tempfile.mkstemp(prefix="loop-spec-publication-child.")
    os.close(descriptor)
    env["LOOP_SPEC_PUBLICATION_TOKEN"] = _token_path
    env["LOOP_SPEC_PUBLICATION_TOKEN_OUTPUT"] = received
    return env


def adopt(received):
    try:
        if _token_path is not None and received and os.path.exists(received) and os.path.getsize(received) > 0:
            shutil.copyfile(received, _token_path)
    finally:
        if received:
            try:
                os.remove(received)
            except OSError:
                pass


def adopt_output(text):
    if _token_path is not None and text and text.strip():
        with open(_token_path, "w", encoding="utf-8") as stream:
            stream.write(text if text.endswith("\n") else text + "\n")


def finish():
    global _token_path
    if _token_path is None:
        return
    try:
        output = os.environ.get("LOOP_SPEC_PUBLICATION_TOKEN_OUTPUT")
        if output:
            shutil.copyfile(_token_path, output)
    finally:
        try:
            os.remove(_token_path)
        except OSError:
            pass
        _token_path = None
