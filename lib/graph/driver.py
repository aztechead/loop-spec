#!/usr/bin/env python3
"""driver.py - The cycle's mechanical loop, in one program with one-line answers.

Why: the orchestration between phases (preflight, invocation parsing, feature init,
resume adoption, watchdog, journaling, state commits, checkpoint PRs, graph stepping,
model-map activation, completion, escalation) was two thousand lines of prose with
embedded shell that the lead model re-executed by hand at every boundary, then a Bash
script that called the graph engine as a subprocess at every step. This module IS
that loop, in the same process as the engine (lib/graph/engine.py), so the cycle's
loop and the graph's loop are one program (the port plan, WP4). The
skill keeps only what needs a harness tool or a human: AskUserQuestion answers,
EnterWorktree/ExitWorktree, Agent dispatch, and Skill(loop-spec:<phase>).

lib/cycle-driver.sh is the launcher; every caller uses that name.

Usage:
    cycle-driver.sh start [--dir DIR] -- <invocation arguments...>
        Preflight + parse + profile + command detection. Prints one JSON object:
        {invocation, profile, classification, harness, teams, workflows, workspace,
         commands, resume:{candidates,cleanup,autoPick}, decisions:[...], notices:[...],
         warnings:[...]}
        decisions[] are the questions the caller must still answer (empty when
        autonomous or non-interactive answered them): {id, question, options, default}.
        ids: greenfield | resume | repos | title | commands.
        Exit 0 answer; 2 bad invocation/env; 3 abort (message on stderr).

    cycle-driver.sh init --dir DIR --slug S --title T --style ST --profile P
        [--classification JSON] [--autonomous 0|1] [--greenfield 0|1]
        [--spec-file PATH] [--commands JSON] [--repos JSON] [--backlog-entry JSON]
        [--protected JSON]   the task's protected files (the `protected:a,b` token),
                             recorded as feature.json.protected
        New feature: adopt-PR probe, clean guard, base, execution root, bootstrap.
        Prints {featureDir, slug, executionRoot, enterWorktree, branch, baseBranch,
        baseSha, greenfield}. `enterWorktree` non-null means the caller must call
        EnterWorktree({path}) before anything else. Exit 0/1/2; 3 the checkout is the
        plugin's own repository and not the project the harness opened (the reason
        names which of the two probes answered), which no cycle initializes.

    cycle-driver.sh resume --dir DIR --feature-root PATH [--slug SLUG]
        Adopt a resumable feature's execution root. Prints {featureDir, slug,
        currentPhase, enterWorktree, tasksDone, tasksRemaining, progressTail,
        recoverCompletion, watchdog}. Exit 0; 1 refused (message says where to relaunch).

    cycle-driver.sh begin [--dir DIR] -- <invocation arguments...>
        start, then init or resume when no human decision is pending. Prints start's
        object plus {action: "init"|"resume"|"decisions", ...the init or resume object}.
        action=decisions means the caller answers .decisions[] and calls init or resume
        itself. Exit codes as start, init, and resume.

    cycle-driver.sh phase-begin <phase> --feature-dir DIR
        The phase's whole ingress in one call: {entry:{fields,read,flags}, mode:{...},
        execute:{...}|verify:{...}}. The execute and verify blocks are
        lib/execute-prepare.sh and lib/verify-prepare.sh. Exit 1 when the entry packet
        FLAGs a missing ingress (the flags are in the JSON); 2 bad invocation.
        Exit 4: this session already answered HANDOFF for the feature; the phase
        starts in a fresh invocation (feature.json.handoffSession).
        A node whose ingress lists `skeletons` gets each absent file written from its
        template first, in the shape the exit gates accept (`skeletons` in the packet).

    cycle-driver.sh spec skeleton --feature-dir DIR
        The oneshot candidate, decided from the scout's record (lib/footprint.sh list)
        by lib/graph/probes/oneshot.sh --candidate, never from files the lead types.
        Prints one JSON object {route, reason, footprint, readOnly, spec}. On
        route=oneshot, {docs}/SPEC.md is written in the oneshot shape from
        skills/shared/artifact-templates/SPEC-oneshot.md.template with the title, slug,
        footprint, one Implementation notes bullet per footprint file, and one
        read-only bullet per read-only cite filled, in the checkout that holds
        feature.json (the one the exit gate reads); `spec` is its path. An existing
        SPEC.md is kept. On route=full nothing is written and `spec` is null: the lead
        writes the full shape. Exit 0; 2 bad invocation.

    cycle-driver.sh oneshot review --feature-dir DIR
        ONESHOT's one review pass, launched by the driver when lib/harness.sh
        session-layer answers "session": the package (the diff since baseSha) is
        written by lib/dispatch-files.sh, the reviewer runs as its own headless CLI
        session with a one-line prompt (the package, the spec, the report path), and
        the dispatch event the exit gate reads is emitted here, driver-observed, never
        self-reported (the port principles, rule 6). Prints the runner's
        JSON line plus {report, package}. In-harness (an attended session, no profile)
        it prints {action: "in-harness"} and the lead dispatches the reviewer through
        the harness tool. Exit 0; 1 the session failed; 2 bad invocation.

    cycle-driver.sh spec footprint drop --feature-dir DIR --file PATH --reason TEXT
        Take one file out of SPEC.md's footprint as a recorded decision: the reason lands
        in decisions.jsonl (kind ruling) and as a line under Implementation notes, and
        the frontmatter list loses the file. The footprint is a promise the ONESHOT exit
        gate checks against the diff, and this is the only way out of it (the gate has
        no prose exit, port audit 3, N2). Refused (exit 1) when the
        file is the test module of a file that stays in the footprint: the change gets
        its test, or the run escalates. Prints {spec, dropped, footprint}. Exit 0; 1
        refused (not in the footprint, or a test module); 2 bad invocation.

    cycle-driver.sh spec fill --feature-dir DIR [--intent TEXT] [--file PATH --note TEXT]
        [--command SHELL --expect TEXT [--row GE-NNN]] [--grounding TEXT [--row N]] | --json PATH|-
        A criterion is two fields: the driver writes `- [ ] \`<command>\` exits 0: <expect>`
        and the command into the frontmatter `criteria:` map that `verification run`
        executes; --row replaces that criterion (or the Nth grounding bullet), no --row
        appends the next one, and the same criterion is never appended twice. --json
        fills every field in one call from {intent, notes: {path: text}, criteria:
        [{command, expect}], grounding: [text]} (`-` reads stdin).
        Fill one value of the oneshot SPEC.md skeleton in place: the paragraph inside the
        frozen Intent block, the Implementation notes bullet of one footprint file, one
        Good Enough criterion (the text after `- [ ] `, the first real one replacing the
        placeholders), or one Grounding bullet (replacing `- none`). The driver is the
        only writer of the shape (port audit 3, N1): the lead never
        has the file open, so the exit gate cannot see a heading it typed. Every write
        re-runs the two spec lints and prints {spec, flags:[...]}; exit 0 written (flags
        are the gate's findings so far), 1 nothing to fill or the field is not in the
        skeleton, 2 bad invocation.
    (there is no `spec escalate`: a gate escalates from evidence, never the lead; the
        third identical REDO on ONESHOT writes `route: full` with the flag classes as
        the reason and the run takes the full path from DISCUSS)
    cycle-driver.sh verification fill --feature-dir DIR
        --row GE-NNN --implementation FILE:LINE --proof TEXT
          [--integration FILE:LINE|none --integration-proof TEXT]
        Fill VERIFICATION.md's oneshot skeleton (phase-begin wrote it) with what the
        lead knows: a criterion's grounding row. Every write re-runs the four
        verification lints the exit gate runs and prints {verification, flags:[...]}.
        Exit 0 written, 1 the row is not in the skeleton, 2 bad invocation.
    cycle-driver.sh verification review --feature-dir DIR [--report PATH] [--reviewer-model M]
        The Code review section from the reviewer's report (default
        <featureDir>/dispatch/oneshot.review.md, where `oneshot review` writes it):
        one `- <file>:<line> — <claim> | verdict: pending` bullet per finding, `none`
        when the report holds none, the reviewer's PASS/PASS_WITH_MINOR/BLOCK on the
        Reviewer line. The driver runs this at the ONESHOT boundary after its own
        review session; in-harness the lead saves the reviewer's result to the report
        path and calls it. Prints {verification, report, reviewerVerdict, findings,
        flags}. Exit 0; 2 no report.
    cycle-driver.sh verification verdict --feature-dir DIR --finding FILE:LINE --verdict true|false --reason TEXT
        The lead's answer to one pending finding: `true — <fix or commit>` or
        `false — <disproof>`. Prints {verification, finding, verdict, flags}. Exit 0;
        1 no such pending finding; 2 bad invocation.
    cycle-driver.sh verification run --feature-dir DIR [--row GE-NNN]
        Observe what the lead must never assert: run each Good Enough criterion's
        command (the first backticked span of its SPEC line) in the feature root and
        write the exit as the row's Status (PASS on 0, FAIL otherwise), the command and
        exit as its Evidence, and the output as its block; without --row also run
        commands.test into the Final test suite block. `next --returned-from oneshot`
        runs this before the exit gate. Prints {verification, ran:[{row, status, exit}],
        flags}. Exit 0 every row passed; 1 a row failed; 2 bad invocation.
    cycle-driver.sh verification run --feature-dir DIR --final-candidate SHA
    cycle-driver.sh verification run --feature-dir DIR --final-candidates PATH
        Task-008's final-candidate observer (PLAN "Final candidate observations"):
        finalize-delivery-candidate.sh has already finished tracked artifacts, and this
        verifies every named root's HEAD already equals its declared SHA (refusing,
        never checking out, otherwise), then runs every required v1 scenario or legacy
        criterion command plus the mandatory commands.test FRESH through
        execution_observation.observe. `--final-candidate SHA` names the one target of
        a single-repo feature; `--final-candidates PATH` names a JSON {name: sha}
        object, required for a workspace feature (each name a configured repo) and
        also accepted for a single-repo feature's one target. Writes the projection
        only under durable `observations/final/<candidate-digest>/` (record.json +
        VERIFICATION.md) -- never onto the branch, never through the tracked
        VERIFICATION.md. Prints the record.json object. Exit 0 every check passed
        (including none configured); 1 a check failed or a named root is not yet at
        its candidate SHA; 2 bad invocation.

    cycle-driver.sh spec approve --feature-dir DIR [--source human|autonomous|supervised]
        Record the full spec's Goal and Boundary digest, or verify an existing one. The
        driver runs this itself when the cycle enters PLAN, with the source read from
        lib/supervisor/oracle.sh; the flag exists for tests and for a supervisor that
        approved out of band. Phase skills never call it.

    cycle-driver.sh spec write --feature-dir DIR --file PATH
        Copy PATH (or stdin for `-`) to {docs}/SPEC.md, the only target this command
        accepts, and print the path. The lead never resolves the docs directory itself:
        a spec written next to the lead in the main checkout while the feature lived in
        a worktree was the misplaced-artifact REDO on two runs. Exit 0; 2 bad invocation.

    cycle-driver.sh plan write --feature-dir DIR --file PATH
    cycle-driver.sh plan patterns --feature-dir DIR --file PATH
        Lint PATH (or stdin for `-`) as PLAN.md/PATTERNS.md and publish it to
        {docs}/PLAN.md or PATTERNS.md under this operation's held token -- once a
        feature's requirementsContract is v1 that path is protected and the planner
        agent writes its draft to `<feature_dir>/publication-staging/` instead
        (skills/plan/SKILL.md). Prints the published path. Exit 0; 1 artifact-lint
        rejected the draft; 2 bad invocation.

    cycle-driver.sh plan tasks --feature-dir DIR
        Extract tasks.json from the already-published PLAN.md (`plan write` must land
        first) and publish it under this operation's held token. Prints the published
        path. Exit 0; 1 no PLAN.md published yet, or the extracted tasks failed
        artifact-lint; 2 bad invocation.

    cycle-driver.sh task dispatch|package|verdict|integrate --feature-dir DIR --task ID ...
        One EXECUTE task step per call; lib/execute-step.sh owns the contract.

    cycle-driver.sh critique open|findings|fail|revised|delta|pass --feature-dir DIR ...
        One critique-gate step per call for DISCUSS and PLAN; lib/critique-step.sh owns
        the contract.

    cycle-driver.sh verify gate|passes --feature-dir DIR ...
        VERIFY's verdict application (lib/verify-gate.sh) and advisory passes
        (lib/verify-passes.sh).

    cycle-driver.sh iterate limit|record|harvest --feature-dir DIR ...
        ITERATE's bookkeeping around the judge (lib/iterate-judged.sh).

    cycle-driver.sh deliver --feature-dir DIR
        The whole DELIVER phase: lib/deliver.sh run, then the terminal PR feedback check
        per target with a PR. Prints {rc, status, nextPhase, route, targets, feedback}.
        route: completed | execute | deliver | deferral (exit 3: restore the dropped scope,
        then call again). Exit 0 completed; 1 otherwise (the route says what to do).

    cycle-driver.sh next --feature-dir DIR [--returned-from PHASE] [--note TEXT]
        Runs phase-exit for the returned phase first: a FLAG answers
          REDO phase=<id> flags=<n> attempt=<k>   followed by the FLAG lines; fix and call again
        The same flags LOOP_SPEC_REDO_MAX (3) times escalate the run with them as the reason.
        Each REDO is also a driver-observed `redo` event in events.jsonl with the flag
        classes (the bracketed label of every FLAG line), which evals/eval_run.py counts.
        Then post-phase bookkeeping and the graph step. Prints exactly ONE answer line:
          NEXT phase=<id> label="<label>" effort=<system1|system2>
          PAUSED node=<id> [intent=changed|unchanged|unknown]
                                     (human gate; re-invoke the cycle to continue; the
                                     DISCUSS gate says whether Goal and Boundary still read
                                     as they did at the SPEC gate, because PLAN freezes them)
          HANDOFF next=<phase> model=<selector>   (one phase per session; relaunch)
          REWIND next=<phase>         (the graph lists <phase> before the returned one; relaunch)
          DONE status=<completed|escalated|paused> [reason=<r>]
          ABORT reason=<r>            (exit 1; diagnostics on stderr)
        followed by zero or more `EXT <instruction or fact=path>` lines for NEXT.
        A phase that returns hands off: the next phase starts in a fresh session
        (`/loop-spec:cycle`), whose first call is `next` without --returned-from.
        Exit 0 answered; 1 graph abort or failure.

    cycle-driver.sh decline [--dir DIR] --reason TEXT [--title TEXT] [--summary TEXT] [--autonomous 0|1]
        A request that is not repository work, declined before the tree changes: the
        protocol-mismatch terminal result (cycle-result.sh write-terminal). Prints
        {status, outcome, reason, result}. Exit 0; 1 the writer refused (the tree has
        changed: finish the work or declare the failure); 2 bad invocation.
    cycle-driver.sh finish --feature-dir DIR [--completed N]
        Terminal result + chain verdict. Prints {status, prUrl, targets, warnings,
        feedback, chain, backlogCount, exitWorktree, report}; `report` is the completion
        text the lead prints as is (outcome first, one line per target, warnings,
        elapsed, backlog count). Exit 0; 1 delivery incomplete.

    cycle-driver.sh escalate --feature-dir DIR --reason TEXT
        Clear team state, write the escalated result, checkpoint PR. Prints
        {gateHistory, artifacts, delivery, exitWorktree}. Exit 0.

Every subcommand is idempotent on its inputs; reading state twice is free, writing
it twice is the same write. harness-neutral: branches only via lib/harness.sh.
"""

from __future__ import print_function

import datetime
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
from glob import glob
from io import StringIO
from pathlib import Path

GRAPH_DIR = Path(__file__).resolve().parent
LIB_DIR = GRAPH_DIR.parent
REPO_ROOT = LIB_DIR.parent
sys.path.insert(0, str(GRAPH_DIR))
sys.path.insert(0, str(LIB_DIR))
import engine  # noqa: E402
import feature_read  # noqa: E402
import publication_participant as pub  # noqa: E402

GRAPH = os.environ.get("LOOP_SPEC_GRAPH") or str(REPO_ROOT / "graph" / "cycle.graph.json")
EMPTY_COMMANDS = {"prepare": "", "test": "", "lint": "", "typecheck": ""}


class Die(Exception):
    """A refusal with its exit code. An empty message means the command that failed
    already said why on stderr, the way `set -e` ends a shell script."""

    def __init__(self, message="", code=1):
        super(Die, self).__init__(message)
        self.message = message
        self.code = code


def usage():
    print(__doc__.split("Usage:", 1)[1].rstrip(), file=sys.stderr)
    raise Die("", 2)


def now():
    return datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")


def iso_epoch(stamp):
    try:
        parsed = datetime.datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        return 0
    return int((parsed - datetime.datetime(1970, 1, 1)).total_seconds())


def run_phase_exit(exit_args):
    """phase-exit.sh, carrying the active token like any other child (task-004 WP3):
    it returns its accepted refresh through LOOP_SPEC_PUBLICATION_TOKEN_OUTPUT, adopted
    here the same as any other participant's."""
    child_env, received = child_call(None)
    proc = subprocess.run(["bash", str(LIB_DIR / "phase-exit.sh")] + exit_args,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True,
                          env=child_env)
    pub.adopt(received)
    return proc


def child_call(base_env):
    """The env for one subprocess and the receipt file to adopt() its refresh from
    afterward -- the one place every subprocess launch passes through, so a publication
    operation begun by this command's cmd_* handler reaches every child of it (task-004:
    "route them through one place so no callsite is missed"). A command that has not
    begun an operation (pub.active() false, or no operation at all e.g. before
    feature.json exists) gets back a plain copy of base_env, same as before this
    existed."""
    env = pub.child_env(dict(base_env) if base_env is not None else dict(os.environ))
    return env, env.get("LOOP_SPEC_PUBLICATION_TOKEN_OUTPUT")


def sh(args, cwd=None, quiet=False, stdin_text=None, check=True, passthrough=False,
       stderr_to_stdout=False, env=None):
    """Run a command and return its stdout without the trailing newline, the way
    `$(...)` does. stderr passes through unless quiet; passthrough leaves stdout
    alone too. A non-zero exit with check raises Die with that code and no
    message: the command spoke for itself."""
    stdout = None if passthrough else subprocess.PIPE
    if stderr_to_stdout:
        stderr = subprocess.STDOUT
    else:
        stderr = subprocess.DEVNULL if quiet else None
    child_env, received = child_call(env)
    proc = subprocess.run([str(a) for a in args], cwd=cwd, input=stdin_text, stdout=stdout,
                          stderr=stderr, universal_newlines=True, env=child_env)
    pub.adopt(received)
    if check and proc.returncode != 0:
        raise Die("", proc.returncode)
    return (proc.stdout or "").rstrip("\n") if not passthrough else ""


def run(args, cwd=None, quiet=False, stdin_text=None, env=None):
    """sh without check: the CompletedProcess, for callers that read the code."""
    child_env, received = child_call(env)
    proc = subprocess.run([str(a) for a in args], cwd=cwd, input=stdin_text,
                          stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL if quiet else None, universal_newlines=True,
                          env=child_env)
    proc.stdout = (proc.stdout or "").rstrip("\n")
    pub.adopt(received)
    return proc


def lib(name, *args, **kw):
    return sh(["bash", LIB_DIR / (name + ".sh")] + list(args), **kw)


def lib_run(name, *args, **kw):
    return run(["bash", LIB_DIR / (name + ".sh")] + list(args), **kw)


def git(*args, **kw):
    return sh(["git"] + list(args), **kw)


def git_ok(*args, **kw):
    kw.setdefault("quiet", True)
    return run(["git"] + list(args), **kw).returncode == 0


def state(feature_dir):
    return feature_read.load_state(str(feature_dir))


def fget(feature_dir, path, default=None):
    value = feature_read.descend(state(feature_dir), path)
    return default if value is None else value


def feature_write_call(*args):
    """feature-write.sh, carrying the active operation's token (task-004): a token
    prints the refreshed one on stdout, which must be adopted here and never leak into
    the driver's own protocol stdout the way plain passthrough would."""
    output = lib("feature-write", *(args + tuple(pub.token_args())))
    pub.adopt_output(output)
    return output


def fset(feature_dir, key, value):
    feature_write_call("set", feature_dir, key, json.dumps(value))


def fappend(feature_dir, key, value):
    feature_write_call("append", feature_dir, key, json.dumps(value))


def publish_artifact(feature_dir, key, content_bytes):
    """Publish a producer's finished bytes for one registered artifact key (spec, plan,
    patterns, verification, tasks) under this operation's held token -- generalizing
    cmd_spec's own stage-then-publish_locked shape (task-004) so every direct writer of
    a registered artifact goes through the same seam. A token-less feature (no
    artifactPublication -- a completed cycle, or a pre-bootstrap fixture) writes the
    file plainly through feature_write.publish, same as before task-004."""
    from artifact_publication import artifact_paths, locked_feature, publish_locked, stage
    from feature_read import load_state
    from feature_write import participant_registry, publish as plain_publish
    import uuid
    directory = Path(feature_dir)
    registry = participant_registry(directory)
    token = pub.current()
    if token is None:
        target = artifact_paths(directory, load_state(directory), registry)[key]
        target.parent.mkdir(parents=True, exist_ok=True)
        plain_publish(target, content_bytes)
        return
    source = stage(directory, key + "-" + uuid.uuid4().hex, content_bytes)
    with locked_feature(directory):
        refreshed = publish_locked(directory, token, {"version": 1, "files": [{"source": source, "target": key}], "updates": []},
                                    registry=registry)
    pub.adopt_output(json.dumps(refreshed))


def retire_artifact(feature_dir, key):
    """Remove a registered artifact target (a manifest source of null) under this
    operation's held token: the third-REDO escalation's own VERIFICATION.md, set aside
    as a record before VERIFY writes its own (task-004)."""
    from artifact_publication import artifact_paths, locked_feature, publish_locked
    from feature_read import load_state
    from feature_write import participant_registry
    directory = Path(feature_dir)
    registry = participant_registry(directory)
    token = pub.current()
    if token is None:
        target = artifact_paths(directory, load_state(directory), registry)[key]
        if target.exists():
            target.unlink()
        return
    with locked_feature(directory):
        refreshed = publish_locked(directory, token, {"version": 1, "files": [{"source": None, "target": key}], "updates": []},
                                    registry=registry)
    pub.adopt_output(json.dumps(refreshed))


def publish_spec(feature_dir, feat, content_bytes):
    """Publish SPEC.md bytes under the held token, reconciling the requirements
    inventory in the same transaction when the feature has a v1 contract -- the one
    shape cmd_spec and cmd_next's third-REDO escalation share (task-004)."""
    from artifact_publication import locked_feature, publish_locked, stage
    from feature_write import participant_registry, publish as plain_publish
    import uuid
    directory = Path(feature_dir)
    registry = participant_registry(directory)
    contract = feat.get("requirementsContract")
    updates = []
    if contract:
        from requirements import parse_spec, reconcile_inventory
        target_hint = os.path.join(docs_dir(feature_dir, feat), "SPEC.md")
        inventory = parse_spec(content_bytes.decode("utf-8"), target_hint, contract)
        updates = [{"path": "requirementsContract", "value": reconcile_inventory(contract, inventory)}]
    token = pub.current()
    if token is None:
        plain_publish(Path(os.path.join(docs_dir(feature_dir, feat), "SPEC.md")), content_bytes)
        if updates:
            fset(feature_dir, "requirementsContract", updates[0]["value"])
        return
    source = stage(directory, "accepted-spec-" + uuid.uuid4().hex, content_bytes)
    with locked_feature(directory):
        refreshed = publish_locked(directory, token, {"version": 1, "files": [{"source": source, "target": "spec"}], "updates": updates},
                                    registry=registry, allowed_updates={"requirementsContract"})
    pub.adopt_output(json.dumps(refreshed))


def read_json(path, default=None):
    """A sidecar (result.json, delivery.json, runtime.json), never feature.json:
    that one goes through lib/feature_read.py."""
    try:
        with open(str(path), "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (IOError, OSError, ValueError):
        return default


def session_id():
    """The harness's id for this model session, or "" where the harness stamps none."""
    return os.environ.get("CLAUDE_CODE_SESSION_ID") or os.environ.get("CLAUDE_SESSION_ID") or ""


def handed_off_here(feat):
    """The handoff this same session produced, or None. A session that answered HANDOFF is
    done: the next phase starts in a fresh invocation, and the driver holds that line
    itself because the Skill-tool guard only sees Skill calls. A lead denied there read
    the next phase's SKILL.md by hand and ran it in the session that had handed off.
    Where the harness stamps no session id nothing can be compared, and the guard alone
    stands."""
    rec = feat.get("handoffSession")
    if not isinstance(rec, dict) or not rec.get("id"):
        return None
    sid = session_id()
    if sid == rec.get("id"):
        return rec
    if not sid:
        # The harness that stamped the record stamps every call of that session, so a
        # call with no id against a record that has one is the same session with the
        # variable stripped: a live sonnet run entered DISCUSS through
        # `env -u CLAUDE_CODE_SESSION_ID` after its own HANDOFF. A fresh session carries
        # its own id; refuse rather than trust an absence.
        return rec
    return None


def handoff_answer(feature_dir, rec):
    """The answer this session already gave, with its record put back. A same-session
    re-entry through `begin` runs preflight, which clears the result pointer; the eval's
    caller then read no result and ended the run after SPEC (final2-sonnet-fastapi)."""
    nxt = rec.get("next") or ""
    frm = rec.get("from") or ""
    lib("cycle-result", "write", feature_dir, "--status", "paused", "--reason", "phase-handoff",
        "--summary", "Phase %s completed; %s is ready in durable state." % (frm, nxt))
    order = lib("graph/phases", "list").splitlines()
    if nxt in order and frm in order and order.index(nxt) < order.index(frm):
        return "REWIND next=%s" % nxt
    model = lib_run("feature-init", "phase-model", nxt, quiet=True).stdout or "inherit"
    return "HANDOFF next=%s model=%s" % (nxt, model)


def workspace_of(feat):
    """The recorded workspace, or None in single-repo mode. Workspace mode is the
    recorded mode, never the presence of a root: lib/workspace.sh detect reports
    {root, mode:"single", repos:[]} for an ordinary repository too, and a consumer
    that read the root as the mode skipped every artifact commit (eval finding 6)."""
    ws = feat.get("workspace")
    if isinstance(ws, dict) and (ws.get("mode") or "") != "single":
        return ws
    return None


def json_bool(value):
    return "true" if value else "false"


def is_claude_worktree_feature(feat):
    return (workspace_of(feat) is None and bool(feat.get("worktreePath"))
            and lib("harness", "detect") == "claude")


def split_dir_args(argv):
    """`[--dir DIR] [--] <invocation arguments...>` -> (dir, arguments)."""
    directory = os.getcwd()
    args = []
    i = 0
    while i < len(argv):
        if argv[i] == "--dir":
            directory = argv[i + 1]
            i += 2
        elif argv[i] == "--":
            args = argv[i + 1:]
            break
        else:
            args.append(argv[i])
            i += 1
    return directory, args


def parse_pairs(argv, allowed):
    """`--key value` pairs into a dict; anything else is a usage error."""
    opts = {}
    i = 0
    while i < len(argv):
        if argv[i] not in allowed or i + 1 >= len(argv):
            usage()
        opts[argv[i][2:].replace("-", "_")] = argv[i + 1]
        i += 2
    return opts


def merge_invocation_stamp(directory, inv):
    """The UserPromptSubmit hook stamps the raw /loop-spec:<skill> arguments before the
    skill rewrites its prose; a token the rewrite dropped is taken from the stamp.
    Consumed on read, and ignored past LOOP_SPEC_STAMP_MAX_AGE_MIN (30), so a stale
    stamp never binds a later run."""
    stamp_path = os.path.join(directory, ".loop-spec", "invocation-stamp.json")
    if not os.path.isfile(stamp_path):
        return inv
    stamp = read_json(stamp_path, {}) or {}
    try:
        ts = int(stamp.get("ts") or 0)
    except (TypeError, ValueError):
        ts = 0
    max_age = int(os.environ.get("LOOP_SPEC_STAMP_MAX_AGE_MIN") or 30)
    os.remove(stamp_path)
    if int(time.time()) - ts > max_age * 60:
        return inv
    proc = lib_run("parse-invocation", "parse", "--", *str(stamp.get("args") or "").split())
    if proc.returncode != 0 or not proc.stdout:
        return inv
    stamped = json.loads(proc.stdout)
    merged = dict(inv)
    merged["autonomous"] = bool(inv.get("autonomous")) or bool(stamped.get("autonomous"))
    merged["greenfield"] = bool(inv.get("greenfield")) or bool(stamped.get("greenfield"))
    for key in ("style", "profile"):
        if not (inv.get(key) or ""):
            merged[key] = stamped.get(key)
    return merged


# ------------------------------------------------------------------ start ----
def cmd_start(argv):
    directory, args = split_dir_args(argv)
    directory = os.path.realpath(directory)
    os.chdir(directory)
    # .loop-spec/profile.json is the run's policy (docs/loop-spec/supervisor-interface.md).
    # Preflight evaluates it in its own process, which this one never saw: a supervised
    # preset that named autonomous still started an interactive run (eval finding 3).
    profile_env = lib_run("profile", "env")
    if profile_env.returncode == 0:
        for line in profile_env.stdout.splitlines():
            m = re.match(r"^export ([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line)
            if m:
                os.environ[m.group(1)] = "".join(shlex.split(m.group(2)))
    else:
        print("cycle-driver: profile.json is invalid; running without it", file=sys.stderr)

    max_parallel = os.environ.get("LOOP_SPEC_MAX_PARALLEL_SUBAGENTS") or ""
    if max_parallel and not re.match(r"^[1-9][0-9]*$", max_parallel):
        raise Die("LOOP_SPEC_MAX_PARALLEL_SUBAGENTS must be a positive integer.", 2)
    # Every LOOP_SPEC_PHASE_MODEL_* / LOOP_SPEC_MODEL_* value is validated here; a bad
    # selector would fail at phase activation anyway, and later is worse.
    if lib_run("feature-init", "validate").returncode != 0:
        raise Die("model routing is misconfigured; startup cannot resolve the selector set.", 2)

    pf = json.loads(lib("cycle-preflight", "run", directory))
    inv = json.loads(lib("parse-invocation", "parse", "--", *args))
    inv = merge_invocation_stamp(directory, inv)

    autonomous = inv.get("autonomous") is True or os.environ.get("LOOP_SPEC_AUTONOMOUS") == "1"
    non_interactive = os.environ.get("LOOP_SPEC_NON_INTERACTIVE") == "1" or autonomous

    # Execution profile: resolved once, carried for the whole cycle.
    inv_profile = inv.get("profile") or ""
    classification = (read_json(".loop-spec/active-run.json", {}) or {}).get("classification")
    class_text = json.dumps(classification) if classification is not None else ""
    profile_env_name = inv_profile or os.environ.get("LOOP_SPEC_CYCLE_PROFILE") or "auto"
    profile_line = lib("cycle-profile", "select", "-", stdin_text=class_text,
                       env=dict(os.environ, LOOP_SPEC_CYCLE_PROFILE=profile_env_name)).strip()
    profile = profile_line[len("profile="):].split(" ")[0] if profile_line.startswith("profile=") else profile_line.split(" ")[0]

    mode = inv.get("mode")
    style = inv.get("style") or "auto"
    if autonomous:
        style = "auto"
    title = inv.get("title") or ""
    spec_path = inv.get("spec_path") or ""

    # Non-interactive answers come from the environment and are validated here. The
    # inline `autonomous` token counts: a live run set LOOP_SPEC_ANSWER_TITLE to escape
    # an overlong prose slug and the driver ignored it because only the env var was
    # read (PR 93).
    if non_interactive:
        style = os.environ.get("LOOP_SPEC_ANSWER_STYLE") or style
        if autonomous:
            style = "auto"
        if style not in ("auto", "step", "interactive", "review-only"):
            raise Die("LOOP_SPEC_ANSWER_STYLE must be auto, step, interactive, or review-only", 2)
        spec_env = os.environ.get("LOOP_SPEC_SPEC_FILE") or ""
        if spec_env:
            if not (os.access(spec_env, os.R_OK) and spec_env.endswith(".md")):
                raise Die("LOOP_SPEC_SPEC_FILE must name a readable .md file", 2)
            spec_path = os.path.join(os.path.realpath(os.path.dirname(spec_env)), os.path.basename(spec_env))
            mode = "spec-file"
        answer_title = os.environ.get("LOOP_SPEC_ANSWER_TITLE") or ""
        if answer_title:
            title = answer_title
            if mode == "bare":
                mode = "description"
    if mode == "spec-file" and not title:
        with open(spec_path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if line.startswith("# "):
                    title = line[2:].rstrip("\n")
                    break
        if not title:
            title = os.path.basename(spec_path[:-3] if spec_path.endswith(".md") else spec_path)
    if mode == "backlog":
        entry_proc = lib_run("backlog", "next", "--json")
        if entry_proc.returncode != 0:
            print("backlog empty — nothing to drain", file=sys.stderr)
            raise Die("", 3)
        entry = json.loads(entry_proc.stdout)
        title = entry.get("text") or ""
        inv["backlogEntry"] = entry
    slug = lib("git-ops", "slugify", title) if title else ""

    decisions, notices = [], []
    warnings = pf.get("warnings") or []
    # Preflight runs before the invocation tokens are parsed, so its headless warning
    # cannot see the inline `autonomous` token; every documented `claude -p
    # "/loop-spec:cycle autonomous ..."` run printed it (PR 93).
    if inv.get("autonomous"):
        warnings = [w for w in warnings if not str(w).startswith("headless invocation")]

    def record(question, answer, why):
        lib("decisions", "add", ".loop-spec/decisions-staging", "cycle", question, answer, why)

    notices.append("loop-spec: " + profile_line)
    if inv.get("legacy"):
        notices.append("loop-spec: ignored legacy token(s) %s." % ", ".join(inv["legacy"]))

    # -- workspace / greenfield --------------------------------------------------
    ws_mode = pf["workspace"]["mode"]
    ws_root = pf["workspace"].get("root")
    ws_root = "null" if ws_root is None else str(ws_root)
    repos = pf["workspace"].get("repos") or []
    greenfield = False
    if ws_mode == "none":
        if inv.get("greenfield") is True or (autonomous and title):
            greenfield = True
            if autonomous:
                record("Not a git repo: bootstrap a net-new application here?", "yes",
                       "autonomous run with a feature description")
        elif not non_interactive and title:
            decisions.append({"id": "greenfield",
                              "question": "Not a git repo. Start a net-new application here (git init), or abort?",
                              "options": ["Start new project here", "Abort"],
                              "default": "Start new project here"})
        else:
            print("loop-spec: not a git repo and no child repos found. cd into a repo, create "
                  ".loop-spec/workspace.json, or start a net-new app with /loop-spec:cycle new <description>.",
                  file=sys.stderr)
            raise Die("", 3)
    elif inv.get("greenfield") is True:
        lib_run("greenfield-bootstrap", "bootstrap", directory, quiet=True)   # prints the refusal for its exit code
        raise Die("already a git repo — greenfield is for empty directories. Run the normal cycle, "
                  "or cd into an empty directory for a new app.", 3)
    if ws_mode == "workspace":
        notices.append("workspace mode: %d repos (%s); state rooted at %s"
                       % (len(repos), ", ".join(r["name"] for r in repos), ws_root))
        answer_repos = os.environ.get("LOOP_SPEC_ANSWER_REPOS") or ""
        if os.environ.get("LOOP_SPEC_NON_INTERACTIVE") == "1" and answer_repos:
            picked = [n for n in re.split(r"[,\s]+", answer_repos) if n]
            known = [r["name"] for r in repos]
            for name in picked:
                if name not in known:
                    raise Die("LOOP_SPEC_ANSWER_REPOS names unknown repo '%s'" % name, 2)
            repos = [r for r in repos if r["name"] in picked]
            if not repos:
                raise Die("LOOP_SPEC_ANSWER_REPOS selected no repos", 2)
        elif autonomous:
            record("Which workspace repos participate?", "all discovered",
                   "autonomous run takes every discovered repo")
        elif not non_interactive:
            listed = ", ".join("%s (%s)" % (r["name"], r["path"]) for r in repos)
            decisions.append({"id": "repos",
                              "question": "Workspace repos: %s. A feat/{slug} branch is created in place "
                                          "in each participating repo. All repos, or customize?" % listed,
                              "options": ["All repos", "Customize"], "default": "All repos"})

    # -- resume ------------------------------------------------------------------
    teams_mode = pf["teams"]["mode"]
    candidates = (pf.get("resume") or {}).get("candidates") or []
    cleanup = []
    if teams_mode != "explicit":
        # No cross-session team can survive here: clear stale references and resume.
        for c in candidates:
            if c.get("needs_probe") is not True:
                continue
            fdir = os.path.join(c["featureRoot"], ".loop-spec", "features", c["slug"])
            if not os.path.isfile(os.path.join(fdir, "feature.json")):
                continue
            # A candidate here is one of possibly several OTHER features' state, never
            # the one this command is about (that is not decided yet) -- each gets its
            # own self-contained ingress, in-process, rather than the command-wide token
            # `pub` tracks for the eventual chosen feature.
            from feature_write import begin_operation, write_operation
            write_operation(fdir, "set", None, ["currentTeamName"], token=begin_operation(fdir))
            notices.append("feature %s had stale team reference %s; cleared and ready to resume"
                           % (c["slug"], c.get("currentTeamName")))
        candidates = [dict(c, needs_probe=False, currentTeamName=None) for c in candidates]
    else:
        cleanup = [c for c in candidates if c.get("needs_probe") is True]
        candidates = [c for c in candidates if c.get("needs_probe") is not True]
    resume_pick = ""
    if candidates:
        if autonomous:
            reason = "autonomous: most recent resumable feature"
            if slug and any(c.get("slug") == slug for c in candidates):
                resume_pick = slug
            elif not title:
                resume_pick = candidates[0]["slug"]
            elif len(candidates) == 1:
                # After a handoff the caller re-invokes with the same description, and a
                # lead that reworded it produced a slug no candidate carried: the run
                # started a second feature next to the paused one. One paused feature in
                # an unattended run is the feature to continue; a different feature is a
                # human decision, and a human is not here.
                resume_pick = candidates[0]["slug"]
                reason = "autonomous: the one paused feature outranks a new title (%s)" % slug
            if resume_pick:
                record("Resume %s or start new?" % resume_pick, "resume " + resume_pick, reason)
                picked = next(c for c in candidates if c.get("slug") == resume_pick)
                fdir = os.path.join(picked["featureRoot"], ".loop-spec", "features", resume_pick)
                handed = handed_off_here(state(fdir))
                if handed is not None:
                    raise Die("this session is finished: it handed off after %s. End the turn now; the caller starts a fresh session for %s (%s)"
                              % (handed.get("from"), handed.get("next"), handoff_answer(fdir, handed)), 4)
        elif not non_interactive:
            options = ["Resume %s - phase %s (updated %s)" % (c["slug"], c["currentPhase"], c["updatedAt"])
                       for c in candidates] + ["New feature"]
            decisions.append({"id": "resume",
                              "question": "Resume an in-progress feature, or start a new one?",
                              "options": options, "default": "New feature"})

    # -- title (bare) ----------------------------------------------------------
    if not title and not resume_pick and mode == "bare":
        if autonomous:
            print("loop-spec: autonomous invocations must carry a feature description, a spec file "
                  "path, or 'backlog'.", file=sys.stderr)
            raise Die("", 3)
        if non_interactive:
            raise Die("LOOP_SPEC_ANSWER_TITLE is required when LOOP_SPEC_SPEC_FILE is unset", 2)
        decisions.append({"id": "title", "question": "What should this cycle build? (free text)",
                          "options": [], "default": ""})

    # -- commands ------------------------------------------------------------------
    commands = dict(EMPTY_COMMANDS)
    if not greenfield and ws_mode == "single":
        commands = detect_commands(ws_root)
    elif ws_mode == "workspace":
        repos = [dict(r, commands=detect_commands(os.path.join(ws_root, r["path"]))) for r in repos]
    if not greenfield and not non_interactive and not resume_pick:
        if ws_mode == "workspace":
            shown = "; ".join("%s: test=%s lint=%s typecheck=%s" % (
                r["name"], r["commands"]["test"], r["commands"]["lint"], r["commands"]["typecheck"]) for r in repos)
        else:
            shown = "prepare=%s test=%s lint=%s typecheck=%s" % (
                commands["prepare"], commands["test"], commands["lint"], commands["typecheck"])
        decisions.append({"id": "commands", "question": "Detected commands: %s. Use these?" % shown,
                          "options": ["Yes", "Customize"], "default": "Yes"})
    elif autonomous and not greenfield:
        record("Use detected project commands?", "yes",
               "autonomous run trusts detection; LOOP_SPEC_CMD_* still wins")

    teams_notice = {
        "none": "loop-spec: agent teams off; continuing with one-shot subagents (loop-fleet when the harness CLI is on PATH).",
        "implicit": "loop-spec: agent teams on (implicit team; teammates spawn via Agent({name})).",
        "explicit": "loop-spec: agent teams on (explicit team; per-phase TeamCreate/TeamDelete).",
    }.get(teams_mode)
    if teams_notice:
        notices.append(teams_notice)
    # Persist the probe answers the phase skills read.
    os.makedirs(".loop-spec", exist_ok=True)
    harness = pf["harness"]["name"]
    runtime = dict(read_json(".loop-spec/runtime.json", {}) or {})
    runtime.update({
        "harness": harness, "teamsMode": teams_mode, "teamsAvailable": teams_mode != "none",
        "workflowsAvailable": pf["workflows"]["available"],
        "workflowExecuteOptIn": os.environ.get("LOOP_SPEC_EXECUTE_WORKFLOW") == "1",
        "workspaceMode": ws_mode, "workspaceRoot": ws_root, "workspaceRepos": repos,
    })
    with open(".loop-spec/runtime.json.tmp", "w", encoding="utf-8") as fh:
        json.dump(runtime, fh)
        fh.write("\n")
    os.replace(".loop-spec/runtime.json.tmp", ".loop-spec/runtime.json")
    if harness == "claude":
        subprocess.run(["bash", str(REPO_ROOT / "hooks" / "pre-cycle-permission-check.sh")], stdout=sys.stderr)

    print(json.dumps({
        "invocation": dict(inv, mode=mode, style=style, title=title, slug=slug, spec_path=spec_path),
        "profile": profile, "classification": classification,
        "autonomous": autonomous, "greenfield": greenfield,
        "harness": harness, "teams": pf["teams"], "workflows": pf["workflows"],
        "workspace": {"mode": ws_mode, "root": ws_root, "repos": repos}, "commands": commands,
        "resume": {"candidates": candidates, "cleanup": cleanup, "autoPick": resume_pick or None},
        "decisions": decisions, "notices": notices, "warnings": warnings,
    }))
    return 0


def detect_commands(root):
    """{prepare,test,lint,typecheck} for one repository, after the env overrides."""
    prepare_proc = lib_run("prepare-environment", "resolve", "--root", root, quiet=True)
    prepare = ""
    if prepare_proc.returncode == 0:
        try:
            prepare = json.loads(prepare_proc.stdout).get("command") or ""
        except ValueError:
            prepare = ""
    test = lib_run("detect-test-cmd", root, quiet=True).stdout
    lint = typecheck = ""
    node_bin = os.path.join(root, "node_modules", ".bin")
    package_json = os.path.join(root, "package.json")
    if os.path.isfile(package_json):
        scripts = (read_json(package_json, {}) or {}).get("scripts") or {}
        if os.access(os.path.join(node_bin, "eslint"), os.X_OK):
            lint = "node_modules/.bin/eslint ."
        elif scripts.get("lint"):
            lint = "npm run lint"
        if os.access(os.path.join(node_bin, "tsc"), os.X_OK) and os.path.isfile(os.path.join(root, "tsconfig.json")):
            typecheck = "node_modules/.bin/tsc --noEmit"
        elif scripts.get("typecheck"):
            typecheck = "npm run typecheck"
    pyproject = ""
    pyproject_path = os.path.join(root, "pyproject.toml")
    if os.path.isfile(pyproject_path):
        with open(pyproject_path, "r", encoding="utf-8", errors="replace") as fh:
            pyproject = fh.read()
    if not lint:
        makefile = os.path.join(root, "Makefile")
        if os.path.isfile(os.path.join(root, "ruff.toml")) or "[tool.ruff" in pyproject:
            lint = "ruff check ."
        elif os.path.isfile(makefile):
            with open(makefile, "r", encoding="utf-8", errors="replace") as fh:
                if re.search(r"^lint:", fh.read(), re.M):
                    lint = "make lint"
    if not typecheck:
        if os.path.isfile(os.path.join(root, "mypy.ini")) or "[tool.mypy" in pyproject:
            typecheck = "mypy ."
    return json.loads(lib("project-commands", "resolve", "--prepare", prepare, "--test", test,
                          "--lint", lint, "--typecheck", typecheck))


# ------------------------------------------------------------------- init ----
INIT_OPTS = ("--dir", "--slug", "--title", "--style", "--profile", "--classification", "--autonomous",
             "--greenfield", "--spec-file", "--commands", "--repos", "--backlog-entry", "--protected")


def plugin_home_refusal(directory, plugin_home, project_dir):
    """Why a cycle must not initialize `directory`, or None. Two probes, both facts on
    disk: the checkout carries this plugin's own manifest and is not the project the
    harness opened (self-development is the one case where it is), or the driver runs
    from a copy inside that checkout (the eval's layout: its plugin snapshot lives under
    the repository the eval launched from). The f0959f6 wc-json run initialized the
    plugin checkout itself and left a feature worktree there that two guard suites
    later read as an in-flight cycle (port audit 3, N6)."""
    directory = os.path.realpath(directory)
    plugin_home = os.path.realpath(plugin_home)
    manifest = os.path.join(directory, ".claude-plugin", "plugin.json")
    own = read_json(os.path.join(plugin_home, ".claude-plugin", "plugin.json"), {}) or {}
    if plugin_home != directory and plugin_home.startswith(directory + os.sep):
        return ("%s holds the driver that would initialize it (%s): the plugin runs from a copy inside "
                "the checkout, the eval's layout, and the project is elsewhere" % (directory, plugin_home))
    named = (read_json(manifest, {}) or {}).get("name")
    if named and named == own.get("name"):
        if project_dir and os.path.realpath(project_dir) == directory:
            return None
        return ("%s is the %s plugin's own repository (.claude-plugin/plugin.json) and not the project the "
                "harness opened%s; a cycle runs in the project" % (
                    directory, named, " (%s)" % project_dir if project_dir else ""))
    return None


def cmd_init(argv):
    o = parse_pairs(argv, INIT_OPTS)
    slug, title = o.get("slug", ""), o.get("title", "")
    if not slug or not title:
        usage()
    directory = os.path.realpath(o.get("dir") or os.getcwd())
    refusal = plugin_home_refusal(directory, str(REPO_ROOT), os.environ.get("CLAUDE_PROJECT_DIR") or "")
    if refusal:
        raise Die("cycle-driver: refusing to initialize a cycle: %s" % refusal, 3)
    os.chdir(directory)
    style = o.get("style") or "auto"
    profile = o.get("profile") or "standard"
    class_text = o.get("classification") or "null"
    autonomous = o.get("autonomous") or "0"
    greenfield = o.get("greenfield") or "0"
    spec_file = o.get("spec_file") or ""
    commands = json.loads(o.get("commands") or "null") or dict(EMPTY_COMMANDS)
    repos = json.loads(o.get("repos") or "[]")
    backlog_entry = o.get("backlog_entry") or ""
    if spec_file and not os.access(spec_file, os.R_OK):
        raise Die("spec file not readable: %s" % spec_file, 2)

    if greenfield == "1":
        if lib_run("greenfield-bootstrap", "bootstrap", directory).returncode != 0:
            raise Die("greenfield bootstrap refused (see above)")
    ws = json.loads(lib("workspace", "detect", directory))
    ws_mode, ws_root = ws["mode"], ws["root"]
    harness = lib("harness", "detect")
    resolved_commands = json.loads(lib(
        "project-commands", "resolve", "--prepare", commands.get("prepare") or "",
        "--test", commands.get("test") or "", "--lint", commands.get("lint") or "",
        "--typecheck", commands.get("typecheck") or ""))

    if ws_mode == "workspace":
        init_workspace(ws_root, slug, title, style, profile, class_text, autonomous, greenfield, spec_file, repos)
        persist_backlog_entry(os.path.join(ws_root, ".loop-spec", "features", slug), backlog_entry)
        return 0

    repo_root = ws_root
    feature_branch = "feat/" + slug
    adopted = False
    adopt = json.loads(lib("adopt-pr", "resolve", "--repo", repo_root, "--request", title))
    if adopt.get("adopt") is True:
        adopted = True
        feature_branch = adopt["branch"]
        base_branch = adopt["baseBranch"]
        print("loop-spec: adopting PR %s on %s (base %s)." % (adopt.get("number"), feature_branch, base_branch),
              file=sys.stderr)
    else:
        base_branch = lib("git-ops", "-C", repo_root, "detect-base-branch")
    lib("runtime-ignore", "ensure", repo_root)
    # One feature per checkout: state used to be branch dirt that tripped the clean guard
    # below; now that it lives on a ref (lib/state-ref.sh) the guard has to say so itself.
    for active_fj in sorted(glob(os.path.join(repo_root, ".loop-spec", "features", "*", "feature.json"))):
        if adopted:
            continue
        active = state(os.path.dirname(active_fj))
        phase = active.get("currentPhase") or ""
        if lib_run("graph/phases", "validate", phase, quiet=True).returncode == 0:
            raise Die("feature %s is already active in this checkout (phase %s); resume it, or finish it "
                      "before starting another." % (active.get("slug"), phase))
    current_branch = git("-C", repo_root, "rev-parse", "--abbrev-ref", "HEAD")
    if not (adopted and current_branch == feature_branch):
        if lib("git-ops", "-C", repo_root, "ensure-clean-or-stash") != "clean":
            dirt = git("-C", repo_root, "status", "--porcelain", "--untracked-files=all").splitlines()[:5]
            raise Die("source checkout is dirty; commit or stash changes before starting autonomous "
                      "delivery: %s" % "".join(line + " " for line in dirt))
    base_ref = base_branch
    if git_ok("-C", repo_root, "remote", "get-url", "origin"):
        if not git_ok("-C", repo_root, "fetch", "--quiet", "origin", base_branch, quiet=False):
            raise Die("failed to fetch origin/%s; refusing a stale PR base." % base_branch)
        base_ref = "origin/" + base_branch
        if adopted:
            git_ok("-C", repo_root, "fetch", "--quiet", "origin", feature_branch, quiet=False)
    if adopted:
        head = run(["git", "-C", repo_root, "rev-parse", "--verify", "refs/heads/%s^{commit}" % feature_branch], quiet=True)
        if head.returncode != 0:
            head = run(["git", "-C", repo_root, "rev-parse", "--verify",
                        "refs/remotes/origin/%s^{commit}" % feature_branch])
        if head.returncode != 0:
            raise Die("cannot resolve adopted PR branch '%s'." % feature_branch)
        merge_base = run(["git", "-C", repo_root, "merge-base", head.stdout, base_ref])
        if merge_base.returncode != 0:
            raise Die("adopted PR branch '%s' does not share history with '%s'." % (feature_branch, base_ref))
        base_sha = merge_base.stdout
    else:
        base = run(["git", "-C", repo_root, "rev-parse", "--verify", "%s^{commit}" % base_ref])
        if base.returncode != 0:
            raise Die("cannot resolve base branch '%s'." % base_ref)
        base_sha = base.stdout
    lib("cycle-result", "begin", "--result-root", repo_root, "--cycle-type", "full", "--title", title,
        "--slug", slug, "--branch", feature_branch, "--base-branch", base_branch, "--phase", "startup",
        "--autonomous", json_bool(autonomous == "1"), passthrough=True)

    # Execution root: Claude enters a worktree; the other harnesses work in place.
    worktrees = os.environ.get("LOOP_SPEC_WORKTREES") or "1"
    if worktrees not in ("0", "1"):
        raise Die("LOOP_SPEC_WORKTREES must be 0 or 1.", 2)
    worktree_abs, exec_root = "", repo_root
    if worktrees == "1" and os.path.isfile(os.path.join(repo_root, ".git")):
        # A gitfile means a submodule or a linked worktree. git adds a worktree there,
        # but Claude Code's EnterWorktree then refuses it as "not a linked worktree of
        # <repo>", so a live run spent four turns tearing it down (PR 93). Work in place.
        worktrees = "0"
        print("loop-spec: %s/.git is a file (submodule or linked worktree); working in place on the feature branch (LOOP_SPEC_WORKTREES=0)." % repo_root, file=sys.stderr)
    if worktrees == "1" and lib("harness", "headless") == "true":
        # A session worktree exists so a human can keep editing the checkout while the
        # cycle runs. Headless has no such human, and Claude Code's worktree guard then
        # refuses plugin calls whose quoted text it cannot prove git-free (PR 93). In
        # place, on the feature branch, is the same isolation for free.
        worktrees = "0"
        print("loop-spec: headless invocation; working in place on the feature branch (LOOP_SPEC_WORKTREES=0).", file=sys.stderr)
    if harness == "claude" and worktrees == "1":
        if adopted:
            attach = lib_run("git-ops", "-C", repo_root, "attach-feature-worktree", slug, feature_branch)
            if attach.returncode != 0:
                raise Die("could not attach a worktree to %s (see the helper's diagnostic above)." % feature_branch)
            worktree_abs = attach.stdout
        else:
            create = lib_run("git-ops", "-C", repo_root, "create-feature-worktree", slug, base_sha)
            if create.returncode != 0:
                raise Die("could not create the feature worktree (see the helper's diagnostic above).")
            worktree_abs = create.stdout
        exec_root = worktree_abs
    elif adopted:
        if not git_ok("-C", repo_root, "checkout", "-q", feature_branch):
            git("-C", repo_root, "checkout", "-q", "-b", feature_branch, "--track", "origin/" + feature_branch)
    else:
        git("-C", repo_root, "checkout", "-q", "-b", feature_branch, base_sha)

    finalize = lib_run(
        "feature-bootstrap", "finalize", "--repo-root", repo_root, "--execution-root", exec_root,
        "--slug", slug, "--title", title, "--branch", feature_branch, "--base-branch", base_branch,
        "--base-sha", base_sha, "--worktree", worktree_abs, "--style", style, "--profile", profile,
        "--classification", class_text, "--autonomous", autonomous, "--greenfield", greenfield,
        "--prepare", resolved_commands["prepare"], "--test", resolved_commands["test"],
        "--lint", resolved_commands["lint"], "--typecheck", resolved_commands["typecheck"], cwd=exec_root)
    if finalize.returncode != 0:
        raise Die("feature bootstrap failed; a terminal cycle result was written (see stderr above).")
    feature_dir = os.path.join(exec_root, ".loop-spec", "features", slug)
    # feature-bootstrap.sh finalize is its own operation (it captures and releases its
    # own token internally for the autonomous/greenfield sets); this command's writes
    # from here on are ours, so begin now that feature.json exists.
    pub.begin(feature_dir)
    protected = json.loads(o.get("protected") or "[]")
    if protected:
        # The task's own list (`protected:a,b`), the one source of a read-only footprint
        # file (lib/footprint.sh; port audit 4, item 1).
        fset(feature_dir, "protected", protected)
    if spec_file:
        shutil.copy(spec_file, os.path.join(feature_dir, "spec-draft.md"))
    persist_backlog_entry(feature_dir, backlog_entry)
    print(json.dumps({
        "featureDir": feature_dir, "slug": slug, "executionRoot": exec_root,
        "enterWorktree": worktree_abs or None, "branch": feature_branch, "baseBranch": base_branch,
        "baseSha": base_sha, "greenfield": greenfield == "1", "testCommand": finalize.stdout,
    }))
    return 0


def init_workspace(ws_root, slug, title, style, profile, class_text, autonomous, greenfield, spec_file, repos):
    """Workspace mode: every repo is checked before any branch is created, then each
    repo gets an in-place feat/{slug} branch and its own prepare/baseline pass."""
    dirty = []
    for r in repos:
        rpath = os.path.join(ws_root, r["path"])
        lib("runtime-ignore", "ensure", rpath)
        if lib_run("git-ops", "-C", rpath, "ensure-clean-or-stash", quiet=True).stdout != "clean":
            dirty.append("%s (%s)" % (r["name"], rpath))
    if dirty:
        print("loop-spec: cannot create feature branches -- the following repos have uncommitted changes:",
              file=sys.stderr)
        for entry in dirty:
            print("  " + entry, file=sys.stderr)
        raise Die("commit or stash changes in each repo above, then re-invoke cycle.")
    bases = {}
    for r in repos:
        rname, rpath = r["name"], os.path.join(ws_root, r["path"])
        bb = lib("git-ops", "-C", rpath, "detect-base-branch")
        ref = bb
        if git_ok("-C", rpath, "remote", "get-url", "origin"):
            if not git_ok("-C", rpath, "fetch", "--quiet", "origin", bb, quiet=False):
                raise Die("failed to fetch %s origin/%s; no feature branches were created." % (rname, bb))
            ref = "origin/" + bb
        sha = run(["git", "-C", rpath, "rev-parse", "--verify", "%s^{commit}" % ref])
        if sha.returncode != 0:
            raise Die("cannot resolve %s base '%s'; no feature branches were created." % (rname, ref))
        if git_ok("-C", rpath, "show-ref", "--verify", "--quiet", "refs/heads/feat/" + slug):
            raise Die("%s already has branch feat/%s; no feature branches were created." % (rname, slug))
        bases[rname] = {"name": rname, "baseBranch": bb, "baseSha": sha.stdout}

    entries = []
    for r in repos:
        rname, rpath = r["name"], os.path.join(ws_root, r["path"])
        base = bases[rname]
        git("-C", rpath, "checkout", "-q", "-b", "feat/" + slug, base["baseSha"])
        rc = r.get("commands") or {}
        cmds = json.loads(lib("project-commands", "resolve", "--prepare", rc.get("prepare") or "",
                              "--test", rc.get("test") or "", "--lint", rc.get("lint") or "",
                              "--typecheck", rc.get("typecheck") or ""))
        prep = lib_run(
            "feature-bootstrap", "prepare-repo", "--root", rpath, "--result-root", ws_root, "--slug", slug,
            "--title", title, "--branch", "feat/" + slug, "--base-branch", base["baseBranch"],
            "--base-sha", base["baseSha"], "--prepare", cmds["prepare"], "--test", cmds["test"],
            "--lint", cmds["lint"], "--typecheck", cmds["typecheck"], "--autonomous", autonomous,
            "--greenfield", greenfield, "--repo-label", rname)
        if prep.returncode != 0:
            raise Die("feature bootstrap failed for %s; a terminal cycle result was written (see stderr above)." % rname)
        prepared = json.loads(prep.stdout)
        entries.append({
            "name": r["name"], "path": r["path"], "branch": "feat/" + slug,
            "baseSha": base["baseSha"], "baseBranch": base["baseBranch"],
            "commands": dict(cmds, prepare=prepared.get("command") or cmds["prepare"],
                             test=prepared.get("test") or cmds["test"]),
            "verificationBaseline": prepared.get("baseline"),
        })

    feature_dir = os.path.join(ws_root, ".loop-spec", "features", slug)
    os.makedirs(feature_dir, exist_ok=True)
    os.makedirs(os.path.join(ws_root, "docs", "loop-spec", "features", slug), exist_ok=True)
    if spec_file:
        shutil.copy(spec_file, os.path.join(feature_dir, "spec-draft.md"))
    fj = json.loads(lib("feature-init", "skeleton", "--mode", "workspace", "--slug", slug, "--now", now(),
                        "--style", style, "--title", title, "--ws-root", ws_root, "--repos", json.dumps(entries)))
    classification = json.loads(class_text) if class_text else None
    gate_plan = None
    selected = lib("cycle-profile", "select", "-", stdin_text=class_text,
                   env=dict(os.environ, LOOP_SPEC_CYCLE_PROFILE="auto")).strip()
    if selected.startswith("profile=compact ") and isinstance(classification, dict):
        gate_plan = classification.get("gatePlan")
    effective = profile
    if effective == "compact" and gate_plan is None:
        effective = "standard"
    if classification is not None:
        fj["autonomousClassification"] = classification
    if gate_plan is not None:
        fj["gatePlan"] = gate_plan
    fj["executionProfile"] = effective
    fj["autonomous"] = autonomous == "1"
    fj["greenfield"] = greenfield == "1"
    # The one token-less write this command makes: a missing feature.json is the only
    # case feature-write.sh's bare (unconditional-replace) form may touch.
    assert not os.path.isfile(os.path.join(feature_dir, "feature.json")), \
        "init_workspace: feature.json already exists at %s" % feature_dir
    lib("feature-write", feature_dir, json.dumps(fj))
    pub.begin(feature_dir)
    lib("decisions", "migrate", os.path.join(ws_root, ".loop-spec", "decisions-staging"), feature_dir)
    lib("cycle-result", "begin", "--result-root", ws_root, "--cycle-type", "full", "--title", title,
        "--slug", slug, "--feature-dir", feature_dir, "--phase", "startup",
        "--autonomous", json_bool(autonomous == "1"), passthrough=True)
    print(json.dumps({
        "featureDir": feature_dir, "slug": slug, "executionRoot": ws_root, "enterWorktree": None,
        "branch": None, "baseBranch": None, "baseSha": None, "greenfield": greenfield == "1",
        "workspace": True,
    }))


def persist_backlog_entry(feature_dir, entry_text):
    """ITERATE's terminal rule matches backlogEntryId exactly to catch a gap spending its
    rounds twice; finish marks the entry done by its text."""
    if not entry_text:
        return
    entry = json.loads(entry_text)
    fset(feature_dir, "backlogEntry", entry.get("text"))
    fset(feature_dir, "backlogEntryId", entry.get("id"))


# ----------------------------------------------------------------- resume ----
def cmd_resume(argv):
    o = parse_pairs(argv, ("--dir", "--feature-root", "--slug"))
    feature_root = o.get("feature_root") or ""
    if not feature_root:
        usage()
    directory = os.path.realpath(o.get("dir") or os.getcwd())
    os.chdir(directory)
    feature_root = os.path.realpath(feature_root)
    selected = o.get("slug") or ""
    if selected:
        if not re.match(r"^[a-zA-Z0-9][a-zA-Z0-9_-]*$", selected):
            raise Die("invalid feature slug: %s" % selected)
        fj = os.path.join(feature_root, ".loop-spec", "features", selected, "feature.json")
        if not os.path.isfile(fj):
            raise Die("selected feature '%s' not found under %s/.loop-spec/features/" % (selected, feature_root))
    else:
        candidates = sorted(glob(os.path.join(feature_root, ".loop-spec", "features", "*", "feature.json")))
        if not candidates:
            raise Die("no feature.json under %s/.loop-spec/features/" % feature_root)
        if len(candidates) != 1:
            raise Die("multiple features under %s; pass --slug for the selected resume candidate" % feature_root)
        fj = candidates[0]
    feature_dir = os.path.dirname(fj)
    # A read-only gate before any side effect: an active migration or an unfinished
    # publication refuses ordinary participation (begin_operation's refuse_pending
    # runs before its bootstrap check), and resume's worktree recreation below is a
    # side effect this must precede, not follow.
    pub.begin(feature_dir, read_only=True)
    feat = state(feature_dir)
    slug = feat.get("slug")
    if slug != os.path.basename(feature_dir):
        raise Die("feature slug does not match its directory: %s" % feature_dir)
    harness = lib("harness", "detect")
    enter = ""

    ws = workspace_of(feat)
    if ws is not None:
        if ws.get("root") != directory:
            raise Die("this workspace feature must be resumed from its workspace root. cd to %s and "
                      "re-invoke cycle." % ws.get("root"))
    elif (feat.get("executionRootMode") or "worktree") == "worktree" and harness == "claude":
        wt = feat.get("worktreePath") or ""
        branch, base = feat.get("branch"), feat.get("baseSha")
        if wt:
            if (os.environ.get("LOOP_SPEC_WORKTREES") or "1") == "0":
                raise Die("the recorded feature requires a worktree, but LOOP_SPEC_WORKTREES=0 forbids creating "
                          "or entering one. Resume once with worktrees enabled, or start a new in-place cycle "
                          "from a clean checkout.")
            listed = git("worktree", "list", "--porcelain").splitlines()
            if ("worktree " + wt) not in listed:
                print("loop-spec: worktree %s is missing; recreating it from the recorded branch." % wt,
                      file=sys.stderr)
                if git_ok("show-ref", "--verify", "--quiet", "refs/heads/%s" % branch):
                    if subprocess.run(["git", "worktree", "add", wt, branch], stdout=sys.stderr).returncode != 0:
                        raise Die("could not recreate worktree %s" % wt)
                else:
                    created = lib_run("git-ops", "create-feature-worktree", slug, base)
                    if created.returncode != 0:
                        raise Die("could not recreate worktree for %s" % slug)
                    wt = created.stdout
                # The branch carries no state; the state ref does.
                if lib_run("state-ref", "restore", wt, slug).returncode != 0:
                    raise Die("could not restore state for %s from %s" % (slug, lib("state-ref", "ref", slug)))
            enter = wt
            feature_dir = os.path.join(wt, ".loop-spec", "features", slug)
            feat = state(feature_dir)
    else:
        # In-place harnesses: the session root must already be the feature root.
        if feature_root != directory:
            raise Die("resume from the feature root: cd %s and re-invoke cycle." % feature_root)
        if git("rev-parse", "--abbrev-ref", "HEAD") != feat.get("branch"):
            raise Die("checkout %s first; the feature branch must be checked out to resume in place."
                      % feat.get("branch"))
    pub.begin(feature_dir)
    fset(feature_dir, "currentTeamName", None)

    done_ids = remaining_ids = ""
    sidecar = (feat.get("artifacts") or {}).get("tasks") or ""
    if sidecar and os.path.isfile(sidecar):
        done_ids = ",".join(lib("task-progress", "done", sidecar).splitlines())
        remaining_ids = ",".join(lib("task-progress", "remaining", sidecar).splitlines())
    delivery = read_json(os.path.join(feature_dir, "delivery.json"), {}) or {}
    recover = delivery.get("nextPhase") == "completed" and delivery.get("status") == "ready-for-review"
    ceiling = int(os.environ.get("LOOP_SPEC_PHASE_TIMEOUT_MINS") or 60)
    started = feat.get("currentPhaseStartedAt") or ""
    watchdog = ""
    if started and int(time.time()) - iso_epoch(started) > ceiling * 60:
        watchdog = ("phase %s exceeded its %dm ceiling in a prior session; resuming from last durable state"
                    % (feat.get("currentPhase"), ceiling))
    progress = os.path.join(feature_dir, "PROGRESS.md")
    tail = ""
    if os.path.isfile(progress):
        with open(progress, "r", encoding="utf-8", errors="replace") as fh:
            tail = "".join(fh.readlines()[-12:]).rstrip("\n")
    print(json.dumps({
        "featureDir": feature_dir, "slug": slug, "currentPhase": feat.get("currentPhase"),
        "enterWorktree": enter or None, "tasksDone": done_ids, "tasksRemaining": remaining_ids,
        "progressTail": tail, "recoverCompletion": recover, "watchdog": watchdog or None,
    }))
    return 0


# ------------------------------------------------------------------- next ----
def graph_step(feature_dir, completed):
    """One engine step in process, with run.sh's exit codes: 0 descriptor, 4 paused,
    5 no route satisfied, 1 failure. The graph was validated once by cmd_next."""
    engine.configure(GRAPH, feature_dir, False, True, True, str(REPO_ROOT), str(GRAPH_DIR), completed)
    try:
        return engine.step_once()
    except engine.EngineExit as exc:
        return exc.code, None


def approval_source(feature_dir, feat):
    """Who approved the Goal and Boundary, read from the run, never typed by a lead."""
    if os.environ.get("LOOP_SPEC_NON_INTERACTIVE") == "1" and not feat.get("autonomous"):
        # Nobody can answer a question on this run, so nobody human approved: the oracle
        # would say human only because the feature was never marked autonomous.
        return "autonomous"
    line = lib("supervisor/oracle", "mode", "--feature-dir", feature_dir).strip()
    return {"oracle=human": "human", "oracle=supervisor": "supervised"}.get(line.split(" ")[0], "autonomous")


def record_spec_approval(feature_dir, feat, source, phase):
    """Freeze Goal and Boundary once, at the last moment before implementation:
    PLAN entry, after SPEC's intent interview and DISCUSS's design questions. Recording
    at SPEC exit ended a run whose human answered DISCUSS's follow-ups. Raises ValueError."""
    from spec_questions import read_questions
    from spec_intent import intent_digest, verify_intent
    target = os.path.join(docs_dir(feature_dir, feat), "SPEC.md")
    text = Path(target).read_text(encoding="utf-8")
    if feat.get("specApproval"):
        verify_intent(text, feat["specApproval"])
        return feat["specApproval"]
    if read_questions(text):
        raise ValueError("resolve intent questions before approving SPEC.md")
    approval = {"sha256": intent_digest(text), "source": source, "approvedAt": now()}
    fset(feature_dir, "specApproval", approval)
    lib("events", "emit", feature_dir, "spec-approved", "--phase", phase, "--data", json.dumps(approval))
    return approval


def reopen_spec_approval(feature_dir, feat):
    """A human approved a SPEC-level rewind: the freeze they approved earlier steps
    aside so DISCUSS can amend Goal and Boundary, and PLAN records the new one. The
    old record moves to specApprovalHistory, which is the only shape the state writer
    lets an approval leave by. Autonomous rewinds never come here: the judge scores
    against feature_title and the freeze stands."""
    approval = feat.get("specApproval")
    if not approval:
        return
    retired = dict(approval, reopenedAt=now(), reopenedBy="human.iterate-spec-approval")
    fappend(feature_dir, "specApprovalHistory", retired)
    fset(feature_dir, "specApproval", None)
    fset(feature_dir, "specIntentSeen", {"sha256": approval["sha256"], "at": now()})
    lib("events", "emit", feature_dir, "spec-reopened", "--phase", "discuss", "--data", json.dumps(retired))


def cmd_next(argv):
    o = parse_pairs(argv, ("--feature-dir", "--returned-from", "--note"))
    feature_dir = o.get("feature_dir") or ""
    returned = o.get("returned_from") or ""
    note = o.get("note") or ""
    if not feature_dir or not os.path.isfile(os.path.join(feature_dir, "feature.json")):
        usage()
    feature_dir = os.path.realpath(feature_dir)
    pub.begin(feature_dir)
    feat = state(feature_dir)
    slug = feat.get("slug")
    ws_mode = "workspace" if workspace_of(feat) is not None else "single"
    repo_root = lib("cycle-result", "resolve-root", os.path.join(feature_dir, "..", "..", ".."))
    os.chdir(repo_root)

    handed = handed_off_here(feat)
    if handed is not None and returned != (handed.get("from") or ""):
        print("cycle-driver: this session is finished: it handed off after %s. End the turn now; "
              "the caller starts a fresh session for %s" % (handed.get("from"), handed.get("next")), file=sys.stderr)
        print(handoff_answer(feature_dir, handed))
        return 0
    rec = feat.get("handoffSession")
    if not returned and isinstance(rec, dict) and rec.get("next") == feat.get("currentPhase") \
            and rec.get("next") not in (None, "", "completed"):
        # The fresh session the handoff asked for: the phase it enters is already on
        # record, so it is answered from the record, never stepped again (the full-route
        # runs entered DISCUSS and PLAN twice and one ended with no result; port audit 5, R5).
        nxt = rec["next"]
        node = next((n for n in (read_json(GRAPH, {}) or {}).get("nodes", []) if n.get("id") == nxt), {})
        fset(feature_dir, "handoffSession", None)
        fset(feature_dir, "currentPhaseStartedAt", now())
        fset(feature_dir, "driverNext", {"phase": nxt, "at": now()})
        print_next(nxt, node.get("label") or nxt, node.get("effort") or "system2", feature_dir)
        return 0

    if returned:
        answer = returned_checks(feature_dir, returned)
        if answer is not None:
            print(answer)
            return 0
        from phase_snapshot import verify
        instructions = (feat.get("driverNext") or {}).get("instructions")
        try:
            if not instructions or (feat.get("driverNext") or {}).get("phase") != returned:
                raise ValueError("returned phase has no matching instruction snapshot")
            verify(instructions, REPO_ROOT, feature_dir)
        except (OSError, ValueError, KeyError) as exc:
            cmd_escalate(["--feature-dir", feature_dir, "--reason", "instruction snapshot verification failed: " + str(exc)], silent=True)
            print("DONE status=escalated reason=instruction-hash-mismatch")
            return 0
        try:
            recovery = review_recovery(feature_dir, returned)
        except (Die, OSError, ValueError) as exc:
            reason = exc.message if isinstance(exc, Die) else str(exc)
            cmd_escalate(["--feature-dir", feature_dir, "--reason", "review recovery failed: " + reason], silent=True)
            print("DONE status=escalated reason=review-recovery-failed")
            return 0
        if recovery == "rewind":
            step_rc, descriptor = graph_step(feature_dir, returned)
            target = "oneshot" if returned == "oneshot" else "discuss"
            if step_rc != 0 or descriptor.get("node") != target:
                raise Die("review recovery: graph did not route bad-spec to " + target)
            fset(feature_dir, "reviewRouting.pending", False)
            answer = record_transition(feature_dir, returned, target, "reverted implementation and amended spec", ws_mode)
            print(answer or ("REDO phase=oneshot flags=1\nFLAG [review] implementation reverted and spec corrected; implement the amended spec and obtain a fresh review"
                             if target == returned else "REWIND next=" + target))
            return 0
        if recovery:
            print("DONE status=escalated reason=review-" + recovery)
            return 0
        answer = boundary_review(feature_dir, returned)
        if answer is not None:
            flags = [line for line in answer.splitlines() if line.startswith("FLAG ")]
            lib("events", "emit", feature_dir, "redo", "--phase", returned,
                "--data", json.dumps({"flags": len(flags), "classes": {"review": len(flags)}, "messages": flags}))
            print(answer)
            return 0
        if returned == "oneshot":
            # Observe before judging: every criterion's command and the test suite run
            # here, by the driver, and the rows say what happened (port audit 4, items 2, 4).
            docs = docs_dir(feature_dir, feat)
            vpath, spath = os.path.join(docs, "VERIFICATION.md"), os.path.join(docs, "SPEC.md")
            if os.path.isfile(vpath) and os.path.isfile(spath) and \
                    not re.search(r"^route: *full\s*$", open(spath, encoding="utf-8").read(), flags=re.M):
                import uuid
                staged_verification = os.path.join(feature_dir, "publication-staging", "verification-oneshot-" + uuid.uuid4().hex)
                os.makedirs(os.path.dirname(staged_verification), exist_ok=True)
                shutil.copyfile(vpath, staged_verification)
                try:
                    # verification_run writes its staged copy after every criterion, never
                    # the registered VERIFICATION.md itself: a long observe() then holds no
                    # lock, and this operation publishes the final bytes once, however the
                    # run ends (task-004).
                    verification_run(feature_dir, feat, docs, staged_verification, spath, None, True)
                except Die as exc:
                    print("cycle-driver: verification run at the oneshot boundary: %s" % exc.message, file=sys.stderr)
                finally:
                    publish_artifact(feature_dir, "verification", Path(staged_verification).read_bytes())
        # The phase's exit gates run here, once, whatever the phase skill did: a lead that
        # skipped them or ran them from the wrong directory was every second eval finding.
        completed = feat.get("completedPhases") or []
        if returned != "deliver" and (completed[-1] if completed else "") != returned:
            exit_args = [returned, "--feature-dir", feature_dir]
            if returned == "iterate" and iterate_is_terminal(feature_dir):
                exit_args.append("--terminal")
            exit_proc = run_phase_exit(exit_args)
            exit_out = exit_proc.stdout
            flags = [line for line in exit_out.splitlines() if line.startswith("FLAG")]
            if exit_proc.returncode == 1:
                # The same flags three times is a gate the phase cannot satisfy, not a phase that
                # needs one more try: the 6.2.0 haiku runs looped six times on one flag and then
                # published an invented reason. Escalate with the flags as the reason instead.
                redo_hash = hashlib.sha1("\n".join(flags).encode("utf-8")).hexdigest()[:12]
                redo = feat.get("driverRedo") if isinstance(feat.get("driverRedo"), dict) else {}
                redo_count = 1
                if redo.get("phase") == returned and redo.get("hash") == redo_hash:
                    redo_count = int(redo.get("count") or 1) + 1
                fset(feature_dir, "driverRedo", {"phase": returned, "hash": redo_hash, "count": redo_count})
                if redo_count >= int(os.environ.get("LOOP_SPEC_REDO_MAX") or 3):
                    reason = "%s exit gate unsatisfied after %d attempts: %s" % (
                        returned, redo_count, "".join(f + " " for f in flags[:3]))
                    spath = os.path.join(docs_dir(feature_dir, feat), "SPEC.md")
                    if returned == "oneshot" and os.path.isfile(spath) and \
                            not re.search(r"^route: *full\s*$", open(spath, encoding="utf-8").read(), flags=re.M):
                        # The one escalation the short route has, and it is the gate's, never
                        # the lead's: the deadlock's flag classes go on record and the run
                        # takes the full path from DISCUSS (port audit 5, R3).
                        classes = sorted({(re.match(r"^FLAG \[([^\]]+)\]", f) or [None, "unlabeled"])[1] for f in flags})
                        import uuid
                        staged_spec = os.path.join(feature_dir, "publication-staging", "spec-escalate-" + uuid.uuid4().hex)
                        os.makedirs(os.path.dirname(staged_spec), exist_ok=True)
                        shutil.copyfile(spath, staged_spec)
                        capture(lambda a: spec_escalate(a[0], a[1]),
                                [staged_spec, "the exit gate held after %d attempts on %s" % (redo_count, ", ".join(classes))])
                        publish_spec(feature_dir, feat, Path(staged_spec).read_bytes())
                        # The attempt's VERIFICATION.md is a record, not the full route's
                        # artifact: set aside so the escalated exit closes with nothing to
                        # lint, and VERIFY writes its own.
                        vpath = os.path.join(docs_dir(feature_dir, feat), "VERIFICATION.md")
                        if os.path.isfile(vpath):
                            shutil.copyfile(vpath, os.path.join(docs_dir(feature_dir, feat), "VERIFICATION.oneshot-attempt.md"))
                            retire_artifact(feature_dir, "verification")
                        lib("events", "emit", feature_dir, "escalate", "--phase", returned,
                            "--data", json.dumps({"attempts": redo_count, "classes": classes, "messages": flags}))
                        print("NOTE [escalate] the oneshot exit gate held after %d attempts (%s): route: full written; the run continues on the full path" % (redo_count, ", ".join(classes)))
                        exit_proc = run_phase_exit(exit_args)
                        if exit_proc.returncode != 0:
                            print("ABORT reason=phase-exit-failed exit=%d" % exit_proc.returncode)
                            print(exit_proc.stdout, file=sys.stderr)
                            return 1
                    else:
                        cmd_escalate(["--feature-dir", feature_dir, "--reason", reason], silent=True)
                        print("DONE status=escalated reason=%s" % reason)
                        return 0
                else:
                    classes = {}
                    for flag in flags:
                        m = re.match(r"^FLAG \[([^\]]+)\]", flag)
                        label = m.group(1) if m else "unlabeled"
                        classes[label] = classes.get(label, 0) + 1
                    lib("events", "emit", feature_dir, "redo", "--phase", returned,
                        "--data", json.dumps({"attempt": redo_count, "flags": len(flags), "classes": classes, "messages": flags}))
                    print("REDO phase=%s flags=%d attempt=%d" % (returned, len(flags), redo_count))
                    for flag in flags:
                        print(flag)
                    return 0
            if exit_proc.returncode != 0 and exit_proc.returncode != 1:
                print("ABORT reason=phase-exit-failed exit=%d" % exit_proc.returncode)
                print(exit_out, file=sys.stderr)
                return 1

    if returned == "spec":
        # What the human read at their SPEC gate: the DISCUSS gate names whether the
        # sections PLAN will freeze still say that, so approval is of text they saw.
        from spec_intent import intent_digest
        try:
            text = Path(docs_dir(feature_dir, feat), "SPEC.md").read_text(encoding="utf-8")
        except OSError as exc:
            print("ABORT reason=spec-unreadable")
            print("cycle-driver: %s" % exc, file=sys.stderr)
            return 1
        if re.search(r"^route: *full\s*$", text, re.M) or not re.search(r"^## Intent$", text, re.M):
            # The oneshot shape has an Intent block and no Goals; it is not the full-spec freeze.
            # The exit gate linted the sections, but a repeat return skips that gate.
            try:
                fset(feature_dir, "specIntentSeen", {"sha256": intent_digest(text), "at": now()})
            except ValueError as exc:
                print("ABORT reason=spec-intent-unreadable")
                print("cycle-driver: %s" % exc, file=sys.stderr)
                return 1

    # Graph step: the engine dispatches gates/functions/subgraphs itself and stops at an
    # agent node, a human pause, an abort, or the terminal node.
    if run(["bash", GRAPH_DIR / "validate.sh", GRAPH], quiet=True).returncode != 0:
        print("run.sh: graph failed validation: %s" % GRAPH, file=sys.stderr)
        subprocess.run(["bash", str(GRAPH_DIR / "validate.sh"), GRAPH], stdout=sys.stderr)
        print("ABORT reason=graph-step-failed exit=1")
        return 1
    completion = returned
    answer = ""
    while True:
        step_rc, descriptor = graph_step(feature_dir, completion)
        completion = ""
        if step_rc == 4:
            nxt = descriptor["node"]
            answer = "PAUSED node=%s" % nxt
            if nxt == "human.after-discuss":
                answer += " intent=%s" % intent_since_spec(feature_dir)
            break
        if step_rc == 5:
            print("ABORT reason=graph-route-blocked (see stderr for route or retry-limit diagnostics)")
            return 1
        if step_rc != 0:
            print("ABORT reason=graph-step-failed exit=%d" % step_rc)
            return 1
        nxt = descriptor["node"]
        if descriptor.get("terminal") is True:
            answer = "DONE status=completed"
            break
        if descriptor.get("kind") == "agent":
            break

    # The descriptor defers an agent node's edge; the ledger's started entry keeps it.
    admitted = (engine.latest_checkpoint() or {}).get("edge") or "" if nxt == "discuss" else ""
    if admitted.endswith("human.iterate-spec-approval->discuss"):
        reopen_spec_approval(feature_dir, feat)
        feat = state(feature_dir)
    if nxt == "plan" and descriptor.get("kind") == "agent":
        # Every route into PLAN lands here (the DISCUSS gate, the short path, the compact
        # gate, ITERATE's plan gap), and before any handoff, so a fresh session finds it.
        try:
            record_spec_approval(feature_dir, feat, approval_source(feature_dir, feat), "plan")
        except (OSError, ValueError) as exc:
            cmd_escalate(["--feature-dir", feature_dir, "--reason", str(exc)], silent=True)
            print("DONE status=escalated reason=spec-approval-refused")
            print("cycle-driver: %s" % exc, file=sys.stderr)
            return 0
        feat = state(feature_dir)
    if returned:
        handed = record_transition(feature_dir, returned, nxt, note, ws_mode)
        if handed is not None:
            print(handed)
            return 0
    if answer:
        print(answer)
        return 0

    label, effort = descriptor["label"], descriptor["effort"]
    lib("feature-init", "activate", feature_dir, nxt)
    # The pause this answer resumes from is over: a reader of result.json (the launcher,
    # a supervisor) took the stale record for the present on the from-scratch walk.
    stale = os.path.join(feature_dir, "result.json")
    if (read_json(stale, {}) or {}).get("status") == "paused":
        os.remove(stale)
        lib("cycle-result", "clear", "--result-root", repo_root)
    # preset, tier, and phaseHandoff predate this schema; they are strays the reader keeps
    # out of every typed view, so the one place that drops them reads the strays on purpose.
    strays = json.loads(lib("feature-read", feature_dir, "--strays"))
    if any(key in strays for key in ("preset", "tier", "phaseHandoff")):
        merged = dict(json.loads(lib("feature-read", feature_dir, "--all", "--drop-strays")))
        merged.update({k: v for k, v in strays.items() if k not in ("preset", "tier", "phaseHandoff")})
        feature_write_call(feature_dir, json.dumps(merged))
    feat = state(feature_dir)
    # feature_title is the immutable goal the ITERATE judge scores against; the slug is
    # the only stand-in on features that predate it.
    if not (feat.get("feature_title") or ""):
        fset(feature_dir, "feature_title", slug)
        feat["feature_title"] = slug
    if nxt != "deliver":
        fset(feature_dir, "currentPhaseStartedAt", now())
    lib("cycle-result", "begin", "--result-root", repo_root, "--cycle-type", "full",
        "--title", feat.get("feature_title"), "--slug", slug,
        "--branch", feat.get("branch") or "", "--base-branch", feat.get("baseBranch") or "",
        "--feature-dir", feature_dir, "--phase", nxt, "--autonomous", json_bool(feat.get("autonomous")))
    # cycle-result.sh reads this: a failure published over an answered NEXT must say why.
    active = feat.get("driverNext") or {}
    if returned or active.get("phase") != nxt:
        active = {"phase": nxt, "at": now()}
    fset(feature_dir, "driverNext", active)
    print_next(nxt, label, effort, feature_dir)
    return 0


def entry_refused(feature_dir, phase, reason):
    """A refused entry is the caller's to fix and try again; the run is not over. It used
    to write the escalated result and open a checkpoint PR, so a ledger reader counted
    an escalation the feature never took (the from-scratch walk after 6.6.0)."""
    lib("events", "emit", feature_dir, "entry_refused", "--phase", phase, "--data", json.dumps({"reason": reason}))
    raise Die("phase entry refused: " + reason)


def instruction_record(feature_dir, phase):
    from phase_snapshot import render, verify
    from spec_intent import verify_intent
    feat = state(feature_dir)
    if phase == "plan" and not feat.get("specApproval"):
        entry_refused(feature_dir, phase, "PLAN needs the recorded Goal and Boundary approval; "
                      "`cycle-driver.sh next` records it when the cycle enters PLAN, so enter through it")
    if feat.get("specApproval"):
        try:
            verify_intent(Path(docs_dir(feature_dir, feat), "SPEC.md").read_text(encoding="utf-8"), feat["specApproval"])
        except (OSError, ValueError) as exc:
            entry_refused(feature_dir, phase, str(exc))
    active = fget(feature_dir, "driverNext", {}) or {}
    if active.get("phase") == phase and active.get("instructions"):
        verify(active["instructions"], REPO_ROOT, feature_dir)
        if Path(active["instructions"]["manifest"]).parent.parent.parent == Path(feature_dir):
            return active["instructions"]
    node = next(n for n in read_json(GRAPH, {})["nodes"] if n["id"] == phase)
    root = feature_root(feature_dir, state(feature_dir))
    prepend = lib("extension-points", "instructions", phase, "prepend", cwd=root)
    append = lib("extension-points", "instructions", phase, "append", cwd=root)
    facts = lib("extension-points", "facts", cwd=root)
    for line in facts.splitlines():
        if line.startswith("fact=file path="):
            path = Path(line[len("fact=file path="):])
            if not path.is_absolute():
                path = Path(root) / path
            prepend += "\n\nFact file %s:\n%s" % (path, path.read_text(encoding="utf-8"))
        elif line.startswith("fact=literal text="):
            prepend += "\n" + line[len("fact=literal text="):]
    record = render(REPO_ROOT, feature_dir, phase, node.get("skill") or phase,
                    lib("harness", "detect").strip(), {"prepend": prepend, "append": append})
    active.update({"phase": phase, "instructions": record})
    fset(feature_dir, "driverNext", active)
    fappend(feature_dir, "instructionSnapshots", dict(record, phase=phase))
    lib("events", "emit", feature_dir, "instructions-rendered", "--phase", phase,
        "--data", json.dumps(record))
    return record


def print_next(nxt, label, effort, feature_dir):
    record = instruction_record(feature_dir, nxt)
    print('NEXT phase=%s label="%s" effort=%s' % (nxt, label, effort))
    node_skill = next((n.get("skill") for n in (read_json(GRAPH, {}) or {}).get("nodes", []) if n.get("id") == nxt), None)
    if node_skill:
        print("EXT skill=%s" % node_skill)
    print("EXT instructions=%s sha256=%s" % (record["prompt"], record["promptSha256"]))


def review_recovery(feature_dir, phase):
    if phase not in ("verify", "oneshot"):
        return None
    from review_routes import findings, FROZEN
    from spec_intent import verify_intent
    feat = state(feature_dir)
    docs = Path(docs_dir(feature_dir, feat))
    report = docs / "VERIFICATION.md"
    prior = feat.get("reviewRouting") or {}
    if prior.get("pending"):
        return "rewind" if prior.get("route") == "bad-spec" else "intent-gap"
    if not report.is_file() or lib_run("review-triage-lint", str(report), quiet=True).returncode:
        return None
    groups = findings(report.read_text(encoding="utf-8"))
    if not groups:
        return None
    root = feature_root(feature_dir, feat)
    workspace = workspace_of(feat)
    repositories = [(os.path.join(root, r["path"]), r["baseSha"]) for r in workspace["repos"]] if workspace else [(root, feat.get("baseSha"))]
    prior = feat.get("reviewRouting") or {}
    report_hash = hashlib.sha256(report.read_bytes()).hexdigest()
    if prior.get("reportSha256") == report_hash and prior.get("pending"):
        return "rewind" if prior.get("route") == "bad-spec" else "intent-gap"
    for group in groups:
        if group["route"] == "patch":
            commit = group["fixCommit"]
            owners = [(repo, base) for repo, base in repositories
                      if base and git_ok("-C", repo, "merge-base", "--is-ancestor", commit, "HEAD")
                      and not git_ok("-C", repo, "merge-base", "--is-ancestor", commit, base)]
            if len(owners) != 1:
                raise Die("review patch: fixCommit must identify one repository's change after baseSha: " + commit)
            repo, _ = owners[0]
            changes = git("-C", repo, "show", "--format=", "--numstat", commit).splitlines()
            if len(changes) != 1 or not re.match(r"^\d+\t\d+\t", changes[0]):
                raise Die("review patch: only a trivial one-file text fix can use patch")
            added, removed, path = changes[0].split("\t", 2)
            if int(added) + int(removed) > 10 or path.startswith(("docs/loop-spec/features/", ".loop-spec/")):
                raise Die("review patch: fix exceeds the surface-free patch bound; classify its root cause")
        elif group["route"] == "defer":
            lib("backlog", "add", feat["slug"], "verify-deferred", group["finding"] + " — " + group["reason"],
                cwd=root, env=dict(os.environ, CLAUDE_PROJECT_DIR=root))
    recovery = [g for g in groups if g["route"] in ("intent-gap", "bad-spec")]
    if not recovery:
        return None
    used = prior.get("used", 0)
    if used >= 5:
        cmd_escalate(["--feature-dir", feature_dir, "--reason", "review recovery limit reached (5)"], silent=True)
        return "limit"
    route = "intent-gap" if any(g["route"] == "intent-gap" for g in recovery) else "bad-spec"
    spec = docs / "SPEC.md"
    revised = spec.read_text(encoding="utf-8")
    if route == "bad-spec":
        for group in recovery:
            section = group["section"]
            match = re.search(r"^## " + re.escape(section) + r"\s*\n", revised, re.M)
            if not match or section in FROZEN:
                raise Die("review bad-spec: amendment must name an existing non-intent section: " + section)
            end = re.search(r"^## ", revised[match.end():], re.M)
            stop = match.end() + end.start() if end else len(revised)
            revised = revised[:match.end()] + "\n" + group["replacement"].strip() + "\n\n" + revised[stop:]
        if phase == "oneshot" and not feat.get("specApproval"):
            pattern = r"(?ms)^<!-- intent: frozen[^\n]*\n.*?^<!-- /intent -->$"
            original = re.search(pattern, spec.read_text(encoding="utf-8"))
            amended = re.search(pattern, revised)
            if not original or not amended or original.group() != amended.group():
                raise Die("review bad-spec: preserve the frozen ONESHOT Intent block")
        else:
            verify_intent(revised, feat.get("specApproval"))
        revised += "\n## Spec change log\n" + "".join("- Review correction: " + g["cause"] + "\n" for g in recovery)
    plans = []
    for repo, base in repositories:
        if not base or not git_ok("-C", repo, "merge-base", "--is-ancestor", base, "HEAD"):
            raise Die("review recovery: baseSha must be an ancestor of the reviewed branch")
        paths = [p for p in git("-C", repo, "diff", "--name-only", "-z", base, "HEAD").split("\0")
                 if p and not p.startswith(("docs/loop-spec/", ".loop-spec/"))]
        untracked = [p for p in git("-C", repo, "ls-files", "--others", "-z").split("\0") if p]
        if any(p == u or u.startswith(p + "/") or p.startswith(u + "/") for p in paths for u in untracked):
            raise Die("review recovery: untracked files overlap the implementation to restore")
        dirty = set(git("-C", repo, "diff", "--name-only", "-z", "HEAD").split("\0"))
        if dirty.intersection(paths):
            raise Die("review recovery: commit or preserve dirty implementation files before reverting")
        plans.append((repo, base, paths))
    for repo, base, paths in plans:
        if paths:
            git("-C", repo, "restore", "--source", base, "--staged", "--worktree", "--", *paths)
            git("-C", repo, "commit", "-m", "fix: revert implementation for " + route, "--", *paths)
    if route == "bad-spec":
        publish_spec(feature_dir, feat, revised.encode("utf-8"))
    record = {"route": route, "used": used + 1, "pending": True,
              "reportSha256": report_hash, "findings": recovery}
    fset(feature_dir, "reviewRouting", record)
    lib("events", "emit", feature_dir, "review-routed", "--phase", phase, "--data", json.dumps(record))
    if route == "intent-gap":
        questions = "; ".join(g["question"] for g in recovery if g["route"] == "intent-gap")
        cmd_escalate(["--feature-dir", feature_dir, "--reason", "intent-gap requires human decision: " + questions], silent=True)
        return "intent-gap"
    fset(feature_dir, "iterate.feedback", {"type": "spec", "description": "Review corrected the spec; re-plan and re-implement.",
                                           "fix_first": "; ".join(g["cause"] for g in recovery)})
    archive = Path(feature_dir) / "review-attempts" / (str(used + 1) + "-" + report_hash)
    archive.mkdir(parents=True, exist_ok=True)
    # Archive a copy first (a record, never a registered artifact), then retire the
    # registered target through the held token: the old code renamed the file aside
    # in place, which both wrote outside the publication contract and left no
    # recoverable original for artifact_publication's own rollback (task-004).
    retiring = []
    for path, key in ((report, "verification"), (docs / "PLAN.md", "plan"), (Path(feature_dir) / "tasks.json", "tasks")):
        if path.is_file():
            shutil.copyfile(path, archive / path.name)
            retiring.append(key)
    for key in retiring:
        retire_artifact(feature_dir, key)
    for key in ("plan", "tasks", "verification", "iteration"):
        fset(feature_dir, "artifacts." + key, None)
    fset(feature_dir, "completedPhases", [p for p in feat.get("completedPhases", []) if p == "spec"])
    return "rewind"


def reviewer_dispatched(feature_dir, phase):
    events = os.path.join(feature_dir, "events.jsonl")
    if not os.path.isfile(events):
        return False
    dispatched = False
    for line in open(events, encoding="utf-8", errors="replace"):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if e.get("event") == "review-routed" and e.get("phase") == phase:
            dispatched = False
        elif e.get("event") == "dispatch" and e.get("phase") == phase \
                and "code-reviewer" in str((e.get("data") or {}).get("role") or ""):
            dispatched = True
    return dispatched


def boundary_review(feature_dir, phase):
    """ONESHOT's one review pass, run by the driver at the phase boundary when the
    session layer answers and no reviewer dispatch is on record. The live followup-haiku
    run implemented the fix, wrote a dispatch event by hand in the wrong shape, and
    escalated on the gate that could not find it: the lead's step was the failure, so
    the step is the driver's (the port principles, rules 6 and 12). Returns
    the one REDO that hands the lead the report, or None."""
    if phase != "oneshot" or reviewer_dispatched(feature_dir, phase):
        return None
    if lib("harness", "session-layer") != "session":
        return None
    events = os.path.join(feature_dir, "events.jsonl")
    if os.path.isfile(events) and any('"event": "review-session-failed"' in line or '"event":"review-session-failed"' in line
                                      for line in open(events, encoding="utf-8", errors="replace")):
        # One failed launch is on record: the lead was told to dispatch in-harness, and
        # relaunching on every return was the loop the port4-haiku-2 feature run
        # escalated out of. The gate's review check names what is still missing.
        return None
    out = capture(cmd_oneshot, ["review", "--feature-dir", feature_dir])
    rec = json.loads(out.strip() or "{}")
    status = rec.get("status") or "failed"
    if status != "completed":
        lib("events", "emit", feature_dir, "review-session-failed", "--phase", "oneshot",
            "--data", json.dumps({"status": status, "stderr": rec.get("stderr"), "envFault": rec.get("envFault")}))
        return ("REDO phase=oneshot flags=1\nFLAG [review] the driver-launched reviewer session ended %s (%s; log %s); the driver will "
                "not relaunch it: dispatch loop-spec:code-reviewer in-harness once (skills/oneshot/SKILL.md, One review pass), "
                "save its result to %s, run `verification review`, emit the dispatch event, then return"
                % (status, rec.get("lastStderrLine") or rec.get("envFault") or "no detail", rec.get("log") or "none",
                   rec.get("report") or "the report path"))
    feat = state(feature_dir)
    target = os.path.join(docs_dir(feature_dir, feat), "VERIFICATION.md")
    written = ""
    if os.path.isfile(target) and os.path.isfile(rec.get("report") or ""):
        try:
            findings, verdict = verification_review(target, rec["report"],
                                                    (feat.get("models") or {}).get("codeReviewer") or "inherit")
            written = "; the Code review section holds %s (reviewer: %s)" % (
                "%d finding(s) awaiting your verdict (verification verdict)" % len(findings) if findings else "none",
                verdict or "no verdict line")
        except Die as exc:
            # A VERIFICATION.md without the skeleton's sections cannot take the section;
            # the exit lints name that on the next return, the review still happened.
            written = "; the Code review section could not be written (%s)" % exc.message
    return ("REDO phase=oneshot flags=1\nFLAG [review] the driver ran the one review pass; its verdict and findings are in %s%s: "
            "fix what needs fixing, answer each pending finding with `verification verdict`, then return" % (rec.get("report"), written))


def intent_since_spec(feature_dir):
    """changed|unchanged|unknown: do Goal and Boundary still read as they did when the
    human left their SPEC gate? Unknown when either side cannot be read."""
    from spec_intent import intent_digest
    feat = state(feature_dir)
    # A feature frozen at SPEC exit by 6.5 has the approval and no snapshot; the approved
    # digest is what its human saw.
    seen = (feat.get("specIntentSeen") or feat.get("specApproval") or {}).get("sha256")
    try:
        current = intent_digest(Path(docs_dir(feature_dir, feat), "SPEC.md").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return "unknown"
    if not seen:
        return "unknown"
    return "unchanged" if current == seen else "changed"


def returned_checks(feature_dir, phase):
    """What a returned phase may have left behind that ends the loop before any
    routing. Returns the answer line, or None to continue."""
    feat = state(feature_dir)
    if feat.get("specApproval"):
        from spec_intent import verify_intent
        try:
            verify_intent(Path(docs_dir(feature_dir, feat), "SPEC.md").read_text(encoding="utf-8"), feat["specApproval"])
        except (OSError, ValueError) as exc:
            cmd_escalate(["--feature-dir", feature_dir, "--reason", str(exc)], silent=True)
            return "DONE status=escalated reason=frozen-intent-changed"
    result = read_json(os.path.join(feature_dir, "result.json"), {}) or {}
    if result.get("status") == "paused" and result.get("reason") in (
            "spec-confirmation-declined",):
        return "DONE status=paused reason=%s" % result["reason"]
    ceiling = os.environ.get("LOOP_SPEC_PHASE_TIMEOUT_MINS") or "60"
    if not re.match(r"^[1-9][0-9]*$", ceiling):
        raise Die("LOOP_SPEC_PHASE_TIMEOUT_MINS must be a positive integer", 2)
    started = fget(feature_dir, "currentPhaseStartedAt", "")
    if started:
        mins = (int(time.time()) - iso_epoch(started)) // 60
        if mins > int(ceiling):
            # The watchdog never kills work; it makes a wedged loop visible.
            print("loop-spec: phase %s took %dm, ceiling %sm" % (phase, mins, ceiling), file=sys.stderr)
            fappend(feature_dir, "warnings", "phase %s took %dm, ceiling %sm" % (phase, mins, ceiling))
    # An ITERATE gap only an operator can close ends the run here with the fix as the
    # reason, instead of a rewind that reproduces the gap or a question to an absent
    # human (PR 93).
    if phase == "iterate" and fget(feature_dir, "iterate.lastRoute", "") == "escalate":
        feedback = fget(feature_dir, "iterate.feedback", {}) or {}
        fix = feedback.get("fix_first") or feedback.get("description") or "iterate gap needs an operator"
        reason = "operator action needed: %s" % fix
        cmd_escalate(["--feature-dir", feature_dir, "--reason", reason], silent=True)
        return 'DONE status=escalated reason="%s"' % reason
    # deliver -> deliver is a stop that needs an external condition to change (or a
    # proven no-change completion); the graph must not re-enter DELIVER.
    delivery_path = os.path.join(feature_dir, "delivery.json")
    if phase == "deliver" and os.path.isfile(delivery_path):
        delivery = read_json(delivery_path, {}) or {}
        if (delivery.get("nextPhase") or "deliver") == "deliver":
            return deliver_stalled(feature_dir, delivery)
    return None


def record_transition(feature_dir, phase, nxt, note, ws_mode):
    """Journal, commit the resume contract, checkpoint, then hand the next phase to a
    fresh session. Returns the answer line that ends this invocation, or None."""
    feat = state(feature_dir)
    slug = feat.get("slug")
    # DELIVER's terminal states are observation-only: a tracked commit after them would
    # invalidate the exact SHA the PR proved. Only a remediation rewind mutates.
    if phase == "deliver" and nxt != "execute":
        return None

    fset(feature_dir, "updatedAt", now())
    progress = os.path.join(feature_dir, "PROGRESS.md")
    header = "" if os.path.isfile(progress) else "# Progress — %s\n" % slug
    with open(progress, "a", encoding="utf-8") as fh:
        fh.write(header)
        fh.write("\n## %s — %s → %s\n- did: %s\n" % (now(), phase, nxt, note or "phase %s returned" % phase))

    # State lives on refs/loop-spec/state/<slug> (lib/state-ref.sh), never on the feature
    # branch: ten of seventeen commits on a delivered branch were state commits, and the
    # driver had edited the project's .gitignore to make them (the port plan,
    # defects 3 and 4). The ref is shared by every worktree of the repository, so the
    # snapshot lands wherever the feature lives.
    root = run(["git", "-C", feature_dir, "rev-parse", "--show-toplevel"], quiet=True).stdout
    if ws_mode != "workspace" and root:
        snapshot = subprocess.run(["bash", str(LIB_DIR / "state-ref.sh"), "commit", feature_dir, "state @ " + nxt],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, universal_newlines=True)
        if snapshot.returncode != 0:
            err = snapshot.stderr.strip()
            print("cycle-driver: state snapshot failed in %s: %s" % (root, err), file=sys.stderr)
            fappend(feature_dir, "warnings", "state snapshot failed at %s -> %s: %s" % (phase, nxt, err))
        each = os.environ.get("LOOP_SPEC_CHECKPOINT_EACH_PHASE") or ("1" if feat.get("autonomous") is True else "0")
        if each not in ("0", "1"):
            raise Die("LOOP_SPEC_CHECKPOINT_EACH_PHASE must be 0 or 1", 2)
        if each == "1" and phase != "deliver":
            child_env, received = child_call(None)
            subprocess.run(["bash", str(LIB_DIR / "checkpoint-pr.sh"), "create", feature_dir,
                            "--reason", "autonomous phase checkpoint: " + nxt], stdout=sys.stderr, env=child_env)
            pub.adopt(received)

    if nxt == "completed" or nxt.startswith("human.") or nxt == phase:
        return None
    # The graph names the one exception to one phase per session: an edge carrying
    # sameSession (spec -> oneshot, oneshot -> deliver: the short route is one session end
    # to end). It paid a session's fixed cost per phase for a two-line fix, and each session
    # loaded its whole context (port audit 1, F2; live run 2 paid the DELIVER
    # handoff). hooks/team/phase-handoff-guard.sh reads the same edge.
    if lib_run("graph/phases", "same-session", phase, nxt, quiet=True).returncode == 0:
        return None
    # One phase per session: the next phase starts in a fresh context whose whole ingress
    # is lib/phase-entry.sh. A rewind is a next phase the graph lists before this one.
    lib("cycle-result", "write", feature_dir, "--status", "paused", "--reason", "phase-handoff",
        "--summary", "Phase %s completed; %s is ready in durable state." % (phase, nxt))
    fset(feature_dir, "handoffSession", {"id": session_id(), "from": phase, "next": nxt, "at": now()})
    order = lib("graph/phases", "list").splitlines()
    if nxt in order and phase in order and order.index(nxt) < order.index(phase):
        return "REWIND next=%s" % nxt
    model = lib_run("feature-init", "phase-model", nxt, quiet=True).stdout or "inherit"
    return "HANDOFF next=%s model=%s" % (nxt, model)


def deliver_stalled(feature_dir, delivery):
    """deliver -> deliver is either a proven no-change completion or a stop that needs an
    external condition to change. Never re-run DELIVER from here."""
    targets = delivery.get("targets") or []
    no_changes = (delivery.get("status") == "no-changes" and targets
                  and all(t.get("errorCode") == "no_commits" or t.get("outcome") == "skipped-no-commits"
                          for t in targets))
    feat = state(feature_dir)
    verdict = ((feat.get("iterate") or {}).get("lastVerdict") or {}) if isinstance(feat.get("iterate"), dict) else {}
    budget_warning = any(isinstance(w, str) and (w.startswith("iterate-budget-spent:") or w.startswith("iterate-terminal:"))
                         for w in (feat.get("warnings") or []))
    summary = verdict.get("summary") or ""
    if (no_changes and verdict.get("converged") is True and verdict.get("deterministic_gate_passed") is True
            and not budget_warning and summary.strip()):
        lib("cycle-result", "write", feature_dir, "--status", "completed", "--summary", summary,
            "--no-change-reason", "already-satisfied")
        return "DONE status=completed reason=already-satisfied"
    reason = next((t.get("error") for t in targets if t.get("error")), None) \
        or "delivery stopped with status %s" % (delivery.get("status") or "unknown")
    lib("cycle-result", "write", feature_dir, "--status", "escalated", "--reason", reason,
        "--summary", "Delivery stopped: " + reason)
    return 'DONE status=escalated reason="%s"' % reason


def iterate_is_terminal(feature_dir):
    """Converged, or the iteration budget spent, closes the phase; a rewind leaves it
    open for the next pass."""
    iterate = fget(feature_dir, "iterate", {})
    if not isinstance(iterate, dict):
        return False
    verdict = iterate.get("lastVerdict") if isinstance(iterate.get("lastVerdict"), dict) else {}
    used = iterate.get("used") or 0
    maximum = iterate.get("maxIterations") or 10
    return verdict.get("converged") is True or used >= maximum


# ------------------------------------------------------------------ finish ----
def cmd_finish(argv):
    o = parse_pairs(argv, ("--feature-dir", "--completed"))
    feature_dir = o.get("feature_dir") or ""
    if not feature_dir or not os.path.isfile(os.path.join(feature_dir, "feature.json")):
        usage()
    feature_dir = os.path.realpath(feature_dir)
    pub.begin(feature_dir, read_only=True)  # finish writes result.json and backlog, never feature.json
    delivery = read_json(os.path.join(feature_dir, "delivery.json"), {}) or {}
    status = delivery.get("status") or ""
    if status not in ("ready-for-review", "delivered-draft", "pushed-no-pr"):
        print("loop-spec: delivery-incomplete (sidecar status '%s'); feature.json.currentPhase stays at deliver."
              % (status or "none"), file=sys.stderr)
        raise Die("", 1)
    feat = state(feature_dir)
    pr_url = feat.get("prUrl") or ""
    summary = ((feat.get("iterate") or {}).get("lastVerdict") or {}).get("summary") or "" \
        if isinstance(feat.get("iterate"), dict) else ""
    if not summary.strip():
        summary = "Cycle completed; PR delivered."
    if status == "pushed-no-pr":
        summary += " (pushed to the remote; no gh on this host, so no PR was opened)"
    write_args = ["write", feature_dir, "--status", "completed", "--summary", summary]
    if pr_url:
        write_args += ["--pr-url", pr_url]
    if lib_run("cycle-result", *write_args).returncode != 0:
        print("cycle-result.sh write failed; retrying once", file=sys.stderr)
        lib("cycle-result", *write_args)
    entry = feat.get("backlogEntry") or ""
    if entry:
        lib_run("backlog", "done", entry, quiet=True)
    chain = json.loads(lib("autonomous-chain", "should-chain", feature_dir, "--completed", o.get("completed") or "0"))
    backlog_count = lib_run("backlog", "count", quiet=True).stdout or "0"
    targets = delivery.get("targets") or []
    feedback = delivery.get("feedback") if isinstance(delivery.get("feedback"), dict) else {}
    # The completion report, rendered from the record (outcome first, then each target,
    # the warnings, the elapsed time, the backlog). The lead prints it: a report built
    # from data carries no self-authored deferral to lint and needs no style contract
    # in the lead's context (port audit 3, N4).
    started = iso_epoch(feat.get("createdAt") or "") if feat.get("createdAt") else None
    lines = [summary]
    for t in targets:
        fb = t.get("feedback") if isinstance(t.get("feedback"), dict) else feedback
        parts = [t.get("name") or t.get("repo") or feat.get("slug") or "target"]
        if t.get("prUrl"):
            parts.append("PR " + t["prUrl"])
        if t.get("targetSha"):
            parts.append("sha " + str(t["targetSha"])[:12])
        if t.get("checks") is not None:
            parts.append("checks " + str(t["checks"]))
        if fb.get("reviewDecision"):
            parts.append("review " + str(fb["reviewDecision"]))
        if fb.get("unresolved") is not None:
            parts.append("%s unresolved" % fb["unresolved"])
        if t.get("errorCode"):
            parts.append("error " + str(t["errorCode"]))
        lines.append("- " + ", ".join(parts))
    for w in feat.get("warnings") or []:
        lines.append("- warning: " + str(w))
    if started:
        mins = max(0, (int(time.time()) - started) // 60)
        lines.append("elapsed %dh%02dm" % (mins // 60, mins % 60))
    lines.append("backlog entries remaining: %s" % backlog_count)
    if str(feedback.get("reviewDecision") or "").lower().replace("_", "") == "changesrequested" and pr_url:
        lines.append("next: /loop-spec:revise " + pr_url)
    print(json.dumps({
        "status": status, "prUrl": pr_url or None, "summary": summary,
        "targets": targets, "feedback": delivery.get("feedback"),
        "warnings": feat.get("warnings") or [], "chain": chain, "backlogCount": int(backlog_count),
        "exitWorktree": is_claude_worktree_feature(feat),
        "report": "\n".join(lines),
    }))
    return 0


# ---------------------------------------------------------------- escalate ----
def cmd_escalate(argv, silent=False):
    o = parse_pairs(argv, ("--feature-dir", "--reason"))
    feature_dir = o.get("feature_dir") or ""
    reason = o.get("reason") or ""
    if not feature_dir or not os.path.isfile(os.path.join(feature_dir, "feature.json")) or not reason:
        usage()
    feature_dir = os.path.realpath(feature_dir)
    pub.begin(feature_dir)
    fset(feature_dir, "currentTeamName", None)
    fset(feature_dir, "currentTeammates", [])
    feat = state(feature_dir)
    phase = feat.get("currentPhase")
    lib_run("cycle-result", "write", feature_dir, "--status", "escalated", "--reason", reason,
            "--summary", "Cycle stopped during %s: %s" % (phase, reason))
    child_env, received = child_call(None)
    subprocess.run(["bash", str(LIB_DIR / "checkpoint-pr.sh"), "create", feature_dir, "--reason", reason],
                   stdout=sys.stderr, env=child_env)
    pub.adopt(received)
    if silent:
        return 0
    print(json.dumps({
        "reason": reason, "phase": phase, "gateHistory": (feat.get("gateHistory") or [])[-3:],
        "artifacts": feat.get("artifacts") or {},
        "delivery": read_json(os.path.join(feature_dir, "delivery.json")),
        "exitWorktree": is_claude_worktree_feature(feat),
    }))
    return 0


# ------------------------------------------------------------------ begin ----
def cmd_decline(argv):
    """The one honest way past the driver for a request that is not repository work:
    the protocol-mismatch terminal result, written before the tree changes. The cycle
    skill used to carry the write-terminal call as a nine-line snippet cited from the
    route-exit contract; the call is the driver's (port audit 3, N4)."""
    o = parse_pairs(argv, ("--dir", "--title", "--reason", "--summary", "--autonomous"))
    reason = (o.get("reason") or "").strip()
    if not reason:
        raise Die("decline needs --reason TEXT (why this is not repository work)", 2)
    directory = os.path.realpath(o.get("dir") or os.getcwd())
    root = lib("cycle-result", "resolve-root", directory)
    # Before begin, never after: a run that initialized a feature has changed the
    # repository (a branch, a worktree, a spec) and reports what it did (the
    # port4-haiku-3 bug fix declined with the fix committed, as protocol-mismatch).
    for fj in glob(os.path.join(root, ".loop-spec", "features", "*", "feature.json")):
        active = state(os.path.dirname(fj))
        if lib_run("graph/phases", "validate", active.get("currentPhase") or "", quiet=True).returncode == 0:
            raise Die("decline: feature %s has begun (phase %s); a run past begin finishes through the cycle or "
                      "escalates (`escalate --reason`), never declines" % (active.get("slug"), active.get("currentPhase")), 1)
    autonomous = o.get("autonomous") or ("1" if os.environ.get("LOOP_SPEC_AUTONOMOUS") == "1" else "0")
    if autonomous not in ("0", "1"):
        raise Die("decline: --autonomous is 0 or 1", 2)
    args = ["write-terminal", "--result-root", root, "--cycle-type", "full", "--status", "escalated",
            "--outcome", "protocol-mismatch", "--converged", "false", "--title", o.get("title") or reason,
            "--reason", reason, "--summary", o.get("summary") or "no work was done: " + reason,
            "--autonomous", json_bool(autonomous == "1")]
    # The writer never aborts (its observability contract): a refusal is one stderr line
    # and no file, so the proof of publication is a result newer than this call.
    result = os.path.join(root, ".loop-spec", "last-result.json")
    before = os.stat(result).st_mtime_ns if os.path.isfile(result) else -1
    proc = lib_run("cycle-result", *args, quiet=True)
    after = os.stat(result).st_mtime_ns if os.path.isfile(result) else -1
    if proc.returncode != 0 or after <= before:
        raise Die("decline: the result writer refused: %s" % (proc.stderr.strip() or "no result was published"), 1)
    print(json.dumps({"status": "escalated", "outcome": "protocol-mismatch", "reason": reason, "result": result}))
    return 0


def cmd_begin(argv):
    directory, args = split_dir_args(argv)
    st = json.loads(capture(cmd_start, ["--dir", directory, "--"] + args))
    if st.get("decisions"):
        # The commands the lead runs once a human has answered, rendered here with every
        # value start already holds; the placeholders are the answers (port audit 3, N4).
        inv = st["invocation"]
        init_cmd = ('bash "$DRV" init --dir %s --slug <slug> --title "<title>" --style %s --profile %s '
                    '--classification %s --autonomous %s --greenfield <0|1> --spec-file "%s" '
                    '--commands %s --repos %s --protected %s' % (
                        shlex.quote(st["workspace"]["root"]), inv["style"], st["profile"],
                        shlex.quote(json.dumps(st["classification"])), "1" if st["autonomous"] else "0",
                        inv.get("spec_path") or "", shlex.quote(json.dumps(st["commands"])),
                        shlex.quote(json.dumps(st["workspace"]["repos"])), shlex.quote(json.dumps(inv.get("protected") or []))))
        if inv.get("backlogEntry"):
            init_cmd += " --backlog-entry %s" % shlex.quote(json.dumps(inv["backlogEntry"]))
        resume_cmd = 'bash "$DRV" resume --dir %s --feature-root <featureRoot of the pick> --slug <slug of the pick>' % shlex.quote(directory)
        print(json.dumps(dict(st, action="decisions", next={"init": init_cmd, "resume": resume_cmd})))
        return 0
    pick = (st.get("resume") or {}).get("autoPick")
    if pick:
        root = next(c["featureRoot"] for c in st["resume"]["candidates"] if c["slug"] == pick)
        out = json.loads(capture(cmd_resume, ["--dir", directory, "--feature-root", root, "--slug", pick]))
        merged = dict(st, action="resume")
        merged.update(out)
        print(json.dumps(merged))
        return 0
    inv = st["invocation"]
    title, slug = inv.get("title") or "", inv.get("slug") or ""
    if not title or not slug:
        print("cycle-driver: begin needs a feature title (start left none and asked no question)", file=sys.stderr)
        raise Die("", 3)
    init_args = ["--dir", st["workspace"]["root"], "--slug", slug, "--title", title,
                 "--style", inv["style"], "--profile", st["profile"],
                 "--protected", json.dumps(inv.get("protected") or []),
                 "--classification", json.dumps(st["classification"]),
                 "--autonomous", "1" if st["autonomous"] else "0",
                 "--greenfield", "1" if st["greenfield"] else "0",
                 "--spec-file", inv.get("spec_path") or "",
                 "--commands", json.dumps(st["commands"]), "--repos", json.dumps(st["workspace"]["repos"])]
    if inv.get("backlogEntry"):
        init_args += ["--backlog-entry", json.dumps(inv["backlogEntry"])]
    out = json.loads(capture(cmd_init, init_args))
    merged = dict(st, action="init")
    merged.update(out)
    print(json.dumps(merged))
    return 0


def capture(command, argv):
    """Run a subcommand (or any printer taking positional args) in this process and
    return what it printed."""
    saved = sys.stdout
    sys.stdout = buffer = StringIO()
    try:
        command(argv)
    finally:
        sys.stdout = saved
    return buffer.getvalue()


# ---------------------------------------------------------------- deliver ----
def cmd_deliver(argv):
    o = parse_pairs(argv, ("--feature-dir",))
    feature_dir = o.get("feature_dir") or ""
    if not feature_dir or not os.path.isfile(os.path.join(feature_dir, "feature.json")):
        usage()
    feature_dir = os.path.realpath(feature_dir)
    pub.begin(feature_dir)
    child_env, received = child_call(None)
    deliver = subprocess.run(["bash", str(LIB_DIR / "deliver.sh"), "run", feature_dir],
                             stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, universal_newlines=True,
                             env=child_env)
    pub.adopt(received)
    rc = deliver.returncode
    err = deliver.stderr.rstrip("\n")
    sidecar_path = os.path.join(feature_dir, "delivery.json")
    sidecar = read_json(sidecar_path, {}) or {}
    status = sidecar.get("status") or ""
    nxt = sidecar.get("nextPhase") or "deliver"
    feedback = []
    if rc == 3:
        route = "deferral"
    elif nxt == "completed":
        route = "completed"
        # Every cycle ends by reading its PR for reviews and requested changes; a target
        # without a PR (pushed-no-pr) has nothing to read.
        for target in sidecar.get("targets") or []:
            if target.get("prNumber") is None:
                continue
            check_args = [str(target["prNumber"])]
            if target.get("repo"):
                check_args += ["--repo", target["repo"]]
            checked = lib_run("pr-feedback", "check", *check_args)
            if checked.returncode != 0:
                route = "feedback-failed"
                break
            if lib_run("pr-feedback", "record", sidecar_path, target.get("name"), checked.stdout).returncode != 0:
                route = "feedback-failed"
                break
            feedback.append(json.loads(checked.stdout))
        if route == "feedback-failed":
            print("cycle-driver: PR feedback persistence failed; completion blocked", file=sys.stderr)
    else:
        route = nxt
    print(json.dumps({
        "rc": rc, "status": status, "nextPhase": nxt, "route": route,
        "targets": sidecar.get("targets") or [], "feedback": feedback, "stderr": err or None,
    }))
    return 0 if route == "completed" else 1


# -------------------------------------------------------------- skeletons ----
TEMPLATES = REPO_ROOT / "skills" / "shared" / "artifact-templates"


def compact_artifact(text):
    """Headings already separate short records; preserve whitespace inside evidence fences."""
    lines = text.splitlines()
    out, fenced = [], False
    for i, line in enumerate(lines):
        if line.startswith("```"):
            fenced = not fenced
        if not fenced and not line and (
                (out and out[-1].startswith("#")) or
                (i + 1 < len(lines) and lines[i + 1].startswith("#"))):
            continue
        out.append(line)
    return "\n".join(out) + "\n"


def feature_root(feature_dir, feat):
    """The checkout that holds feature.json (the workspace root in workspace mode): the
    root lib/exit-gate-prelude.sh reads artifacts from, never the lead's cwd."""
    ws = workspace_of(feat)
    root = ws.get("root") if ws else run(["git", "-C", feature_dir, "rev-parse", "--show-toplevel"], quiet=True).stdout
    if not root:
        raise Die("%s is not inside a git repository" % feature_dir, 2)
    return root


def docs_dir(feature_dir, feat):
    return os.path.join(feature_root(feature_dir, feat), "docs", "loop-spec", "features", feat.get("slug") or "")


def good_enough_criteria(spec_path):
    """The Good Enough checkbox lines of a spec, in order: GE-001 is the first."""
    if not os.path.isfile(spec_path):
        return []
    out, inside = [], False
    for line in open(spec_path, encoding="utf-8", errors="replace"):
        if line.startswith("### "):
            inside = line.strip() == "### Good Enough"
        elif line.startswith("## "):
            inside = False
        elif inside and re.match(r"^- \[[ xX]\] ", line):
            out.append(re.sub(r"^- \[[ xX]\] ", "", line).strip())
    return out


def render_skeleton(template, feat, footprint=None, spec_path=None, read_only=None, contract=None):
    """A template with the facts the driver holds filled in and every value the lead
    owns left as a {placeholder}. The shape is the gates' business, so it is written
    here once instead of retyped by the lead per run (six REDO rounds on the dda2cca
    bug fix were format rounds; port audit 1, F4). `contract` selects the SPEC
    templates' v1-or-legacy Good Enough/frontmatter placeholder (apply_requirements_shape
    below); every other template carries neither placeholder, so the substitution is a
    no-op for them, and an absent contract always yields today's legacy shape."""
    text = open(template, encoding="utf-8").read()
    text = text.replace("{feature_title}", feat.get("feature_title") or feat.get("slug") or "")
    text = text.replace("{slug}", feat.get("slug") or "")
    if footprint is not None:
        text = text.replace("  - {path/to/file-the-change-touches}\n", "".join("  - %s\n" % p for p in footprint))
        bullets = "".join("- %s: {what changes here, with the symbol or line it touches; or `unchanged`, and why}\n" % p for p in footprint)
        bullets += "".join("- %s: read-only; the change does not touch it.\n" % p for p in (read_only or []))
        text = text.replace(
            "- {What changes in each footprint file, one bullet per file, with the symbol or line it touches.}\n", bullets)
    if "GE-001" in text:
        criteria = good_enough_criteria(spec_path or "")
        if not (feat.get("artifacts") or {}).get("plan"):
            text = re.sub(r"^\*\*Plan:\*\* .*\n", "", text, flags=re.M)
        if contract and contract.get("format") == "v1":
            # v1 rows are keyed by the stable GE-ID/SC-ID pair `verification run`
            # binds from the live inventory each run, never a document-position
            # number (PLAN "no numeric row aliases"); the numbered placeholder row
            # and its "### Criterion 1" stub would otherwise sit unfilled forever,
            # since nothing here writes a row keyed "1" for verification_run's v1
            # route to find and replace.
            text = re.sub(r"^\| 1 \| \{from SPEC\} \|.*\|\n", "", text, flags=re.M)
            text = re.sub(
                r"### Criterion 1\n\n```\n\{full output of verify command\}\n```\n\n\(repeat per criterion\)\n",
                "", text)
        elif criteria:
            text = text.replace(
                "- criterion: GE-001 | implementation: {path}:{line} - {what it proves} | integration: {path}:{line} - {what it proves}\n",
                "".join("- criterion: GE-%03d | implementation: {path}:{line} - {what it proves} | integration: {path}:{line} - {what it proves}\n" % (i + 1)
                        for i in range(len(criteria))))
            # A criterion is often a shell pipeline; a bare `|` splits the table row
            # and lib/converged-floor.sh reads its status from the wrong cell (live
            # run 3 paid a REDO and ten edits for one).
            # The Status cell stays empty until `verification run` observes the command's
            # exit: a PASS written before anyone ran anything is the self-graded gate one
            # layer down (port audit 4, item 2).
            text = text.replace(
                "| 1 | {from SPEC} |  | `{verify command}` -> {output summary} |\n",
                "".join("| GE-%03d | %s |  | `{verify command}` -> {output summary} |\n" % (i + 1, c.replace("|", "\\|"))
                        for i, c in enumerate(criteria)))
            text = text.replace(
                "### Criterion 1\n\n```\n{full output of verify command}\n```\n\n(repeat per criterion)\n",
                "".join("### Criterion %d\n\n```\n{full output of verify command}\n```\n\n" % (i + 1) for i in range(len(criteria))))
    text = apply_requirements_shape(text, contract)
    return compact_artifact(text) if template.endswith("-oneshot.md.template") else text


# The two placeholders every SPEC template carries so ONE file renders both contract
# shapes (docs/loop-spec/requirements-format.md): `{requirements_frontmatter}\n` is a
# whole frontmatter line the v1 declarations replace or that vanishes for legacy, and
# REQUIREMENTS_V1_GE_ROW is the GE/SC placeholder that stands next to the legacy
# criterion placeholder until one of the two is stripped. On the full route nothing
# calls this (author_spec still writes no full-route skeleton); the same two literal
# placeholders in SPEC.md.template guide the human/agent lead who copies it by hand
# (skills/spec/SKILL.md, agents/spec-writer.md).
REQUIREMENTS_V1_GE_ROW = "- [ ] {GE-001: outcome}\n  - {SC-001: observable scenario}\n"


VERIFICATION_V1_NOTE = (
    "<!-- v1 requirements contract: cycle-driver.sh verification run keys each row\n"
    "     GE-ID/SC-ID (never a document-position number) and writes its Status and Evidence\n"
    "     from a driver-owned observation record -- see agents/verifier.md, \"v1 requirements\n"
    "     contract\". The legacy row shape below is unchanged. -->\n\n")


def apply_requirements_shape(text, contract):
    """Select the v1 or legacy Good Enough placeholder and frontmatter declaration in a
    freshly rendered spec skeleton. Harmless no-op against render_skeleton's own
    "GE-001" VERIFICATION-template substitution above: that block only replaces
    `- criterion: GE-001 | ...`/`| 1 | ...` spans, which this template never contains.
    The VERIFICATION templates' own v1 note is stripped for a legacy/no-contract
    skeleton the same way -- both templates carry the identical literal block so a
    legacy oneshot skeleton never grows v1-only prose (tests/lib/cycle-driver.test.sh
    pins its line count)."""
    if contract and contract.get("format") == "v1":
        declaration = "requirements_version: 1\nrequirements_owner: %s\nscenario_checks: {}\n" % (
            json.dumps(contract["owner"], sort_keys=True, separators=(",", ":")))
        text = text.replace("{requirements_frontmatter}\n", declaration)
        text = text.replace("- [ ] `{check command}` exits 0: {what that proves}\n", "")
        # A fresh oneshot skeleton carries no placeholder Good Enough row: the first
        # `spec fill --command/--expect` allocates GE-001/SC-001 itself (fill_requirement),
        # and parse_spec rejects the literal "{GE-001" text as a malformed requirement id,
        # so leaving the row in would fail every fill before the lead ever touches it.
        text = text.replace(REQUIREMENTS_V1_GE_ROW, "")
    else:
        text = text.replace("{requirements_frontmatter}\n", "")
        text = text.replace(REQUIREMENTS_V1_GE_ROW, "")
        text = text.replace(VERIFICATION_V1_NOTE, "")
    return text


SKELETON_ARTIFACT_KEYS = {"SPEC.md": "spec", "PLAN.md": "plan", "VERIFICATION.md": "verification", "PATTERNS.md": "patterns"}


def write_skeletons(feature_dir, feat, node):
    """Each absent file the node's ingress lists under `skeletons`, written from its
    template through publish_artifact -- every skeleton names a registered artifact
    (graph/schema.json's own description of the field). Returns the paths written."""
    written = []
    docs = docs_dir(feature_dir, feat)
    spec = (feat.get("artifacts") or {}).get("spec") or os.path.join(docs, "SPEC.md")
    if not os.path.isabs(spec):
        spec = os.path.join(feature_root(feature_dir, feat), spec)
    for entry in (node.get("ingress") or {}).get("skeletons") or []:
        target = entry["path"].replace("{docs}", docs).replace("{featureDir}", feature_dir)
        if os.path.exists(target):
            continue
        template = REPO_ROOT / entry["template"]
        if not template.is_file():
            raise Die("skeleton template missing: %s (graph node %s)" % (template, node.get("id")), 2)
        key = SKELETON_ARTIFACT_KEYS.get(os.path.basename(target))
        if key is None:
            raise Die("skeleton path is not a registered artifact: %s (graph node %s)" % (target, node.get("id")), 2)
        publish_artifact(feature_dir, key, render_skeleton(
            str(template), feat, spec_path=spec, contract=feat.get("requirementsContract")).encode("utf-8"))
        written.append(target)
    return written


def spec_footprint(text):
    """The frontmatter footprint list of a spec, in order."""
    m = re.search(r"^footprint:[ \t]*(\[.*?\])?[ \t]*$((?:\n  - .*)*)", text, flags=re.M)
    if not m:
        return []
    if m.group(1):
        return [p for p in re.findall(r"[^\[\],\s'\"]+", m.group(1))]
    return [line[4:].strip() for line in m.group(2).splitlines() if line.startswith("  - ")]


def footprint_drop(feature_dir, feat, target, path, reason):
    text = open(target, encoding="utf-8").read()
    footprint = spec_footprint(text)
    if path not in footprint:
        raise Die("spec footprint drop: %s is not in the footprint of %s (%s)" % (path, target, ", ".join(footprint) or "empty"))
    remaining = [p for p in footprint if p != path]
    # A test module of a file that changed in the diff stays whatever the footprint says
    # now: dropping the source first and its test second was accepted (port audit 4, N2).
    root = feature_root(feature_dir, feat)
    base = feat.get("baseSha") or ""
    changed = run(["git", "-C", root, "diff", "--name-only", base, "HEAD", "--"], quiet=True).stdout.splitlines() if base else []
    for kept in sorted(set(remaining) | set(changed)):
        # The naming rules lib/oneshot-spec-lint.sh applies: test_<stem>, <stem>_test, <stem>.test.
        stem, ext = os.path.splitext(os.path.basename(kept))
        if os.path.basename(path) in ("test_%s%s" % (stem, ext), "%s_test%s" % (stem, ext), "%s.test%s" % (stem, ext)):
            raise Die("spec footprint drop: %s is the test module of %s, which %s: the change "
                      "gets its test, or the run escalates (route: full)" % (
                          path, kept, "changed in the diff" if kept in changed else "stays in the footprint"))
    lib("decisions", "add", feature_dir, "oneshot", "drop %s from the footprint" % path, "dropped", reason, "ruling")
    text = re.sub(r"^  - %s\n" % re.escape(path), "", text, count=1, flags=re.M)
    text = re.sub(r"^(footprint:[ \t]*\[)([^\]]*)(\])",
                  lambda m: m.group(1) + ", ".join(p for p in re.split(r"\s*,\s*", m.group(2)) if p and p != path) + m.group(3),
                  text, count=1, flags=re.M)
    note = "- %s: dropped from the footprint by cycle-driver.sh spec footprint drop: %s\n" % (path, reason)
    text = text.replace("## Implementation notes\n", "## Implementation notes\n" + note, 1)
    with open(target, "w", encoding="utf-8") as fh:
        fh.write(text)
    print(json.dumps({"spec": target, "dropped": path, "reason": reason, "footprint": remaining}))
    return 0


def section_span(text, heading):
    """(start, end) of the body under a `## ` or `### ` heading: from the line after
    it to the next heading of the same or a higher level, or the end."""
    m = re.search(r"^(#{2,3}) %s[ \t]*$\n" % re.escape(heading), text, flags=re.M)
    if not m:
        return None
    level = len(m.group(1))
    nxt = re.compile(r"^#{1,%d} " % level, re.M).search(text, m.end())
    return m.end(), (nxt.start() if nxt else len(text))


def fill_requirement(text, source, options, contract):
    """Keep GE/SC identity separate from scenario_checks command and executionInputs."""
    from requirements import parse_spec, unique_object, valid_id
    inventory = parse_spec(text, source, contract)
    row = options.get("row")
    if row is not None and not valid_id(row, "GE"):
        raise Die("spec fill: v1 --row requires a stable GE-ID, never a numeric position", 2)
    inputs = options.get("execution_inputs")
    if isinstance(inputs, str):
        inputs = json.loads(inputs, object_pairs_hook=unique_object)
    if not isinstance(inputs, dict):
        raise Die("spec fill: v1 requires --execution-inputs with the reviewed JSON input contract "
                  "(docs/loop-spec/requirements-format.md); the minimal declaration is "
                  '\'{"version":1,"toolchains":[],"localInputs":[],"externalInputs":[],"sensitiveInputs":[]}\'', 2)
    command, expect = options["command"].strip(), options["expect"].strip()
    if not command or not expect or "\n" in expect:
        raise Die("spec fill: command and single-line outcome prose must be nonempty", 2)
    lines = text.splitlines(keepends=True)
    requirement = next((r for r in inventory["requirements"] if r["id"] == row), None)
    if row is not None and requirement is None:
        raise Die("spec fill: no active requirement " + row)
    scenario_id = options.get("scenario")
    if requirement:
        scenarios = requirement["scenarios"]
        if scenario_id is None and len(scenarios) == 1:
            scenario_id = scenarios[0]["id"]
        if scenario_id not in {scenario["id"] for scenario in scenarios}:
            raise Die("spec fill: --scenario must name an active scenario of " + row, 2)
        start = requirement["location"]["line"] - 1
        end = scenarios[0]["location"]["line"] - 1
        lines[start:end] = ["- [ ] %s: %s\n" % (row, expect)]
        text = "".join(lines)
    else:
        row = "GE-%03d" % contract["nextRequirementId"]
        scenario_id = "SC-001"
        span = section_span(text, "Good Enough")
        text = text[:span[1]] + "- [ ] %s: %s\n  - %s: %s\n\n" % (row, expect, scenario_id, expect) + text[span[1]:]
    match = re.search(r"^scenario_checks: *(.*)$", text, re.M)
    checks = json.loads(match.group(1), object_pairs_hook=unique_object) if match else {}
    for identity in checks:
        parts = identity.split("/")
        if len(parts) != 2 or not valid_id(parts[0], "GE") or not valid_id(parts[1], "SC"):
            raise Die("spec fill: scenario_checks requires GE-ID/SC-ID keys", 2)
    checks[row + "/" + scenario_id] = {"command": command, "executionInputs": inputs}
    declaration = "scenario_checks: " + json.dumps(checks, ensure_ascii=False, separators=(",", ":"))
    if match:
        text = text[:match.start()] + declaration + text[match.end():]
    else:
        text = text.replace("---\n", "---\n" + declaration + "\n", 1)
    parse_spec(text, source, contract)
    return text, row


def declares_requirements_metadata(text):
    """True when the frontmatter names any `requirements_*` key, mirroring parse_spec's
    own `explicit` test (lib/requirements.py) without importing its private frontmatter
    scanner: a supplied draft that already speaks v1 is left to parse_spec's full
    validation untouched, never rewritten under it."""
    lines = text.replace("\r\n", "\n").split("\n")
    if not lines or lines[0] != "---":
        return False
    try:
        end = lines.index("---", 1)
    except ValueError:
        return False
    return any(re.match(r"^requirements_[A-Za-z0-9_]*\s*:", line) for line in lines[1:end])


def normalize_v1_draft(text, contract):
    """A supplied draft that declares no v1 metadata: add the frontmatter declarations
    and allocate stable GE/SC IDs to Good Enough items in document order, from the
    contract's ledger -- ingest preserves the supplied requirement text verbatim and
    normalizes format only (docs/loop-spec/requirements-format.md). A draft that
    already declares v1 metadata is returned untouched; parse_spec alone is its judge."""
    placeholder = re.compile(r"^\{requirements_frontmatter\}\n", re.M)
    if declares_requirements_metadata(text):
        # A draft that kept the template's placeholder next to its own declarations
        # would publish the literal line; the declarations are what it stood for.
        return placeholder.sub("", text, count=1)
    declaration = "requirements_version: 1\nrequirements_owner: %s\n" % (
        json.dumps(contract["owner"], sort_keys=True, separators=(",", ":")))
    if not re.search(r"^scenario_checks:", text, re.M):
        declaration += "scenario_checks: {}\n"
    if not re.match(r"^---\n", text):
        raise Die("spec write: v1 ingest requires YAML frontmatter to declare the contract into", 1)
    if placeholder.search(text):
        # The full-route template's `{requirements_frontmatter}` line is where the
        # declarations belong (skills/spec/SKILL.md says the placeholder becomes them);
        # a live sonnet run read the driver source to learn what to type there instead.
        text = placeholder.sub(declaration, text, count=1)
    else:
        text = re.sub(r"^---\n", "---\n" + declaration, text, count=1)
    span = section_span(text, "Good Enough")
    if span is None:
        raise Die("spec write: v1 ingest requires a ### Good Enough section", 1)
    body = text[span[0]:span[1]]
    lines = body.splitlines(keepends=True)
    out = []
    next_id = contract["nextRequirementId"]
    i = 0
    while i < len(lines):
        line = lines[i]
        item = re.match(r"^- \[([ xX])\] (?:(GE-\d{3,}): )?(.*)\n?$", line)
        if item and item.group(2) is None:
            mark, _, rest = item.groups()
            out.append("- [%s] GE-%03d: %s\n" % (mark, next_id, rest))
            next_id += 1
            i += 1
            if i < len(lines) and re.match(r"^  - ", lines[i]):
                out.append(lines[i])
                i += 1
            else:
                out.append("  - SC-001: %s\n" % rest)
        else:
            out.append(line)
            i += 1
    return text[:span[0]] + "".join(out) + text[span[1]:]


def spec_fill(target, o, contract=None):
    text = open(target, encoding="utf-8").read()
    filled = []
    if o.get("intent"):
        span = section_span(text, "Intent")
        if span is None:
            raise Die("spec fill: no ## Intent block in %s" % target)
        body = text[span[0]:span[1]]
        close = body.find("<!-- /intent -->")
        if close < 0:
            raise Die("spec fill: the Intent block of %s has no closing marker" % target)
        text = text[:span[0]] + "\n" + o["intent"].strip() + "\n" + body[close:] + text[span[1]:]
        filled.append("intent")
    if o.get("note") or o.get("file"):
        if not (o.get("note") and o.get("file")):
            raise Die("spec fill: --file PATH and --note TEXT go together", 2)
        line = re.compile(r"^- %s: .*$" % re.escape(o["file"]), re.M)
        if not line.search(text):
            raise Die("spec fill: %s has no Implementation notes bullet for %s (the footprint's files have one each)" % (target, o["file"]))
        text = line.sub(lambda _: "- %s: %s" % (o["file"], o["note"].strip()), text, count=1)
        filled.append("note:" + o["file"])
    if o.get("criterion"):
        raise Die("spec fill: a criterion is two fields, --command <shell> and --expect <what exit 0 proves>; "
                  "the driver writes the line (port audit 5, R1)", 2)
    versioned = bool(contract and contract.get("format") == "v1")
    if versioned and (o.get("command") or o.get("expect")):
        if not (o.get("command") and o.get("expect")):
            raise Die("spec fill: --command and --expect go together", 2)
        text, row = fill_requirement(text, target, o, contract)
        filled.append("criterion:" + row)
    elif not versioned:
        if o.get("command") or o.get("expect"):
            command, expect = (o.get("command") or "").strip(), (o.get("expect") or "").strip()
            if not command or not expect:
                raise Die("spec fill: --command <shell> and --expect <what exit 0 proves> go together", 2)
            if "`" in command:
                raise Die("spec fill: the command carries no backtick; the driver writes the line", 2)
            span = section_span(text, "Good Enough")
            if span is None:
                raise Die("spec fill: no ### Good Enough section in %s" % target)
            body = text[span[0]:span[1]]
            kept = [l for l in body.splitlines() if l.strip() and "{check command}" not in l]
            line = "- [ ] `%s` exits 0: %s" % (command, expect)
            row = o.get("row")
            if row:
                if not re.match(r"^GE-\d{3}$", row):
                    raise Die("spec fill: --row names a criterion as GE-NNN", 2)
                idx = int(row[3:]) - 1
                if not 0 <= idx < len(kept):
                    raise Die("spec fill: %s has no criterion %s to replace (%d present)" % (target, row, len(kept)), 1)
                kept[idx] = line
                filled.append("criterion:%s" % row)
            elif line in kept:
                filled.append("criterion (already present)")
            else:
                kept.append(line)
                filled.append("criterion:GE-%03d" % len(kept))
            text = text[:span[0]] + "\n" + "\n".join(kept) + "\n\n" + text[span[1]:]
            # The command the driver will run lives in the frontmatter too, keyed by row:
            # `verification run` reads this map, never the sentence.
            commands = [re.search(r"`([^`]+)`", l).group(1) if re.search(r"`([^`]+)`", l) else "" for l in kept]
            block = "criteria:\n" + "".join("  GE-%03d: %s\n" % (i + 1, json.dumps(c)) for i, c in enumerate(commands))
            fm = re.match(r"^---\n(.*?)^---\n", text, flags=re.M | re.S)
            if not fm:
                raise Die("spec fill: %s has no frontmatter to hold the criteria map" % target)
            front = re.sub(r"^criteria:\n(?:  GE-\d{3}: .*\n)*", "", fm.group(1), flags=re.M)
            text = "---\n" + front + block + "---\n" + text[fm.end():]
    if o.get("grounding"):
        span = section_span(text, "Grounding")
        if span is None:
            raise Die("spec fill: no ## Grounding section in %s" % target)
        body = text[span[0]:span[1]]
        kept = [l for l in body.splitlines() if l.strip() and l.strip() != "- none"]
        line = "- " + o["grounding"].strip()
        row = o.get("row")
        if row and not (o.get("command") or o.get("expect")):
            if not row.isdigit() or not 1 <= int(row) <= len(kept):
                raise Die("spec fill: --row for a grounding bullet is its 1-based index (%d present)" % len(kept), 2)
            kept[int(row) - 1] = line
            filled.append("grounding:%s" % row)
        elif line in kept:
            filled.append("grounding (already present)")
        else:
            kept.append(line)
            filled.append("grounding")
        text = text[:span[0]] + "\n" + "\n".join(kept) + "\n" + text[span[1]:]
    if not filled:
        raise Die("spec fill: nothing to fill (--intent, --file/--note, --command/--expect, or --grounding)", 2)
    if not versioned:
        text = compact_artifact(text)
    with open(target, "w", encoding="utf-8") as fh:
        fh.write(text)
    flags = []
    for name, args in (("artifact-lint", ["spec", target]), ("oneshot-spec-lint", [target])):
        out = lib_run(name, *args, quiet=True).stdout
        flags += [line for line in out.splitlines() if line.startswith("FLAG")]
    print(json.dumps({"spec": target, "filled": filled, "flags": flags}))
    return 0


def spec_escalate(target, reason):
    text = open(target, encoding="utf-8").read()
    if not re.search(r"^route: *full\s*$", text, flags=re.M):
        text = re.sub(r"^---\n(.*?)^---\n", lambda m: "---\n" + m.group(1) + "route: full\n---\n", text, count=1, flags=re.M | re.S)
    text = text.replace("## Implementation notes\n", "## Implementation notes\n- escalated (route: full): %s\n" % reason, 1)
    with open(target, "w", encoding="utf-8") as fh:
        fh.write(text)
    print(json.dumps({"spec": target, "route": "full", "reason": reason}))
    return 0


def cmd_spec(argv):
    """Author a private candidate, then publish its inventory with the original token
    (the model publish_artifact/publish_spec generalize for every other registered
    artifact: task-004)."""
    from feature_write import read_bounded
    import uuid
    if "--feature-dir" not in argv:
        return author_spec(argv)
    index = argv.index("--feature-dir")
    if index + 1 == len(argv):
        usage()
    directory = Path(argv[index + 1]).resolve()
    if not (directory / "feature.json").is_file():
        return author_spec(argv)
    token_path = None
    if "--token" in argv:
        index = argv.index("--token")
        if index + 1 == len(argv):
            usage()
        token_path = argv[index + 1]
        argv = argv[:index] + argv[index + 2:]
    # An explicit --token PATH overrides an inherited env pair; both funnel through the
    # same seam, so this carries no private token handling of its own (task-004 WP2).
    token = current = pub.begin(directory, token_path=token_path)
    feat = state(directory)
    if current is None:
        return author_spec(argv)
    if argv[:1] == ["approve"]:
        return author_spec(argv, publication_token=token)
    target = Path(docs_dir(str(directory), feat)) / "SPEC.md"
    staged = directory / "publication-staging" / ("spec-" + uuid.uuid4().hex)
    staged.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        staged.write_bytes(read_bounded(target))
    output = capture(lambda args: author_spec(args, str(staged)), argv)
    if staged.exists():
        if argv[:1] == ["skeleton"]:
            # A driver-rendered skeleton is scaffolding the lead has not filled yet
            # (a `{GE-001: outcome}` placeholder under v1 satisfies no grammar); publish
            # it plainly, the same as legacy, and leave the ledger for the first real
            # `spec write`/`spec fill` to reconcile.
            publish_artifact(str(directory), "spec", read_bounded(staged))
        else:
            publish_spec(str(directory), feat, read_bounded(staged))
    print(output.replace(str(staged), str(target)), end="")
    return 0


def cmd_plan(argv):
    """Land the planner's PLAN.md/PATTERNS.md drafts and derive tasks.json, through the
    same staged-then-publish_artifact seam cmd_spec uses (task-009 follow-up): once a
    feature's requirementsContract is v1, docs/loop-spec/features/<slug>/*.md is a
    protected path (lib/harness.sh; hooks/restrict-agent-paths.sh) and the planner
    agent cannot write there directly. The planner writes its draft to
    `<feature_dir>/publication-staging/PLAN.md`/`PATTERNS.md` (a path every harness
    role scope already allows) and the lead runs `plan write`/`plan patterns` to land
    it, then `plan tasks` to extract tasks.json from the PUBLISHED PLAN.md -- never a
    shell redirection a hook cannot see land."""
    sub = argv[0] if argv else ""
    if sub not in ("write", "patterns", "tasks"):
        usage()
    opts = {"write": ("--feature-dir", "--file"), "patterns": ("--feature-dir", "--file"),
            "tasks": ("--feature-dir",)}[sub]
    o = parse_pairs(argv[1:], opts)
    feature_dir = o.get("feature_dir") or ""
    if not feature_dir or not os.path.isfile(os.path.join(feature_dir, "feature.json")):
        usage()
    feature_dir = os.path.realpath(feature_dir)
    from feature_write import read_bounded
    pub.begin(feature_dir)
    feat = state(feature_dir)
    docs = docs_dir(feature_dir, feat)
    if sub in ("write", "patterns"):
        file_path = o.get("file") or ""
        if not file_path:
            raise Die("plan %s: --file is required" % sub, 2)
        content = sys.stdin.buffer.read() if file_path == "-" else read_bounded(Path(file_path))
        key, name = ("plan", "PLAN.md") if sub == "write" else ("patterns", "PATTERNS.md")
        lint_args = [key, "-"] + (["--feature-dir", feature_dir] if key == "plan" else [])
        lint = lib_run("artifact-lint", *lint_args, stdin_text=content.decode("utf-8"))
        if lint.returncode != 0:
            raise Die("plan %s: artifact-lint rejected the draft:\n%s" % (sub, lint.stdout), 1)
        publish_artifact(feature_dir, key, content)
        print(os.path.join(docs, name))
        return 0
    # tasks: extracted from the ALREADY-PUBLISHED PLAN.md, never a draft -- `plan
    # write` must land first so the DAG the extractor reads is the accepted one.
    plan_path = (feat.get("artifacts") or {}).get("plan") or os.path.join(docs, "PLAN.md")
    if not os.path.isabs(plan_path):
        plan_path = os.path.join(feature_root(feature_dir, feat), plan_path)
    if not os.path.isfile(plan_path):
        raise Die("plan tasks: PLAN.md has not been published yet; run 'plan write' first", 1)
    extracted = lib_run("plan-tasks", "extract", plan_path)
    if extracted.returncode != 0:
        raise Die("plan tasks: %s" % extracted.stdout, 1)
    lint = lib_run("artifact-lint", "tasks", "-", "--feature-dir", feature_dir, stdin_text=extracted.stdout)
    if lint.returncode != 0:
        raise Die("plan tasks: artifact-lint rejected the extracted tasks:\n%s" % lint.stdout, 1)
    # Edge inference (lib/plan-conflicts.sh edges) used to write tasks.json in place,
    # outside this command's publication boundary -- a security hardening pass moved
    # it here, in-process before the single publish_artifact call, so the driver's
    # held token is the only thing that ever lands tasks.json. plan-conflicts.sh is
    # print-only now: it reads a file and prints the augmented array, so the
    # extractor's output goes to a throwaway temp file rather than the published one.
    import tempfile
    with tempfile.NamedTemporaryFile(mode="wb", suffix=".json", delete=False) as tmp:
        tmp.write(extracted.stdout.encode("utf-8"))
        tmp_path = tmp.name
    try:
        # quiet=True: plan-conflicts.sh edges' own stderr ("edge X -> Y",
        # "N edge(s) inferred") is diagnostic chatter this command's stdout
        # contract (the published tasks.json path, nothing else) never carried
        # before -- an inherited fd here would otherwise leak straight past this
        # process into whatever redirects the driver's own stderr.
        edges = lib_run("plan-conflicts", "edges", tmp_path, quiet=True)
    finally:
        os.unlink(tmp_path)
    if edges.returncode != 0:
        raise Die("plan tasks: %s" % (edges.stdout or "an inferred blockedBy edge would close a dependency cycle"), 1)
    final_tasks = edges.stdout.encode("utf-8")
    lint = lib_run("artifact-lint", "tasks", "-", "--feature-dir", feature_dir, stdin_text=edges.stdout)
    if lint.returncode != 0:
        raise Die("plan tasks: artifact-lint rejected the tasks after edge inference:\n%s" % lint.stdout, 1)
    publish_artifact(feature_dir, "tasks", final_tasks)
    print(os.path.join(feature_dir, "tasks.json"))
    return 0


def author_spec(argv, target_override=None, publication_token=None):
    sub = argv[0] if argv else ""
    if sub == "footprint" and argv[1:2] == ["drop"]:
        sub, argv = "drop", argv[1:]
    if sub == "escalate":
        raise Die("spec escalate is not the lead's call: a gate escalates from evidence (a diff outside the footprint, "
                  "a reviewer BLOCK, or the third identical REDO), with the reason on record (port audit 5, R3)", 2)
    if sub not in ("skeleton", "write", "drop", "fill", "approve"):
        usage()
    opts = {"approve": ("--feature-dir", "--source"), "write": ("--feature-dir", "--file"), "drop": ("--feature-dir", "--file", "--reason"),
            "fill": ("--feature-dir", "--intent", "--file", "--note", "--criterion", "--command", "--expect", "--row", "--scenario", "--execution-inputs", "--grounding", "--json"),
            "escalate": ("--feature-dir", "--reason")}.get(sub, ("--feature-dir",))
    o = parse_pairs(argv[1:], opts)
    feature_dir = o.get("feature_dir") or ""
    source = o.get("file")
    if not feature_dir or not os.path.isfile(os.path.join(feature_dir, "feature.json")):
        usage()
    feature_dir = os.path.realpath(feature_dir)
    feat = state(feature_dir)
    target = target_override or os.path.join(docs_dir(feature_dir, feat), "SPEC.md")
    if sub in ("drop", "fill", "escalate") and not os.path.isfile(target):
        raise Die("spec %s: no SPEC.md at %s" % (sub, target), 2)
    if sub == "approve":
        source_flag = o.get("source") or approval_source(feature_dir, feat)
        if source_flag not in ("human", "autonomous", "supervised"):
            raise Die("spec approve needs --source human|autonomous|supervised", 2)
        if source_flag == "autonomous" and not (feat.get("autonomous") or os.environ.get("LOOP_SPEC_NON_INTERACTIVE") == "1"):
            raise Die("spec approve: autonomous approval requires an unattended run", 2)
        try:
            record_spec_approval(feature_dir, feat, source_flag, feat.get("currentPhase") or "spec")
        except (OSError, ValueError) as exc:
            raise Die("spec approve: %s" % exc, 1)
        print(json.dumps({"spec": target, "approval": fget(feature_dir, "specApproval")}))
        return 0
    if sub == "drop":
        if not source or not (o.get("reason") or "").strip():
            raise Die("spec footprint drop needs --file PATH and --reason TEXT", 2)
        return footprint_drop(feature_dir, feat, target, source, o["reason"].strip())
    if sub == "fill":
        if o.get("json"):
            # Every field in one call, one Bash turn: each fill was a turn that re-read the
            # whole context (port audit 4, item 5). {intent, notes: {path: text}, criteria:
            # [text], grounding: [text]}; `-` reads stdin.
            raw = sys.stdin.read() if o["json"] == "-" else open(o["json"], encoding="utf-8").read()
            try:
                batch = json.loads(raw)
            except ValueError as exc:
                raise Die("spec fill --json: not a JSON object: %s" % exc, 2)
            if not isinstance(batch, dict):
                raise Die("spec fill --json: the document is a JSON object", 2)
            filled = []
            calls = []
            if batch.get("intent"):
                calls.append({"intent": batch["intent"]})
            for path, note in (batch.get("notes") or {}).items():
                calls.append({"file": path, "note": note})
            for c in batch.get("criteria") or []:
                if not isinstance(c, dict):
                    raise Die("spec fill --json: each criterion is {command, expect}, never a sentence (port audit 5, R1)", 2)
                calls.append({"command": c.get("command"), "expect": c.get("expect"), "row": c.get("row"), "scenario": c.get("scenario"), "execution_inputs": c.get("executionInputs")})
            for g in batch.get("grounding") or []:
                calls.append({"grounding": g})
            if not calls:
                raise Die("spec fill --json: nothing to fill", 2)
            out = None
            contract = feat.get("requirementsContract")
            for call in calls:
                out = json.loads(capture(lambda a: spec_fill(a[0], a[1], contract=contract), [target, call]))
                filled += out["filled"]
                if contract and contract.get("format") == "v1" and call.get("command"):
                    # A criterion fill can issue a fresh GE-ID (fill_requirement reads
                    # contract["nextRequirementId"]): reconcile in-memory after each call
                    # so two new requirements in one batch get consecutive IDs, never the
                    # same one reused. This candidate is never persisted here -- cmd_spec's
                    # publish_spec reconciles and persists the real ledger once, from the
                    # batch's final text.
                    from requirements import parse_spec, reconcile_inventory
                    text = open(target, encoding="utf-8").read()
                    contract = reconcile_inventory(contract, parse_spec(text, target, contract))
            print(json.dumps({"spec": target, "filled": filled, "flags": out["flags"]}))
            return 0
        return spec_fill(target, o, contract=feat.get("requirementsContract"))
    if sub == "skeleton":
        # The route is a function of the scout's record, and the model may lengthen it,
        # never shorten it (the port principles, rule 1). The probe reads the
        # same ledger this reads, so the two cannot disagree about the footprint.
        footprint = lib("footprint", "list", feature_dir).splitlines()
        read_only = lib("footprint", "list", feature_dir, "--read-only").splitlines()
        probe = lib_run("graph/probes/oneshot", "--feature-dir", feature_dir, "--candidate", quiet=True).stdout.strip()
        route, _, reason = probe.partition(" reason=")
        route = route.replace("route=", "") or "full"
        spec = None
        if route == "oneshot":
            if os.path.exists(target):
                print("cycle-driver: %s exists; kept as written (delete it to start over)" % target, file=sys.stderr)
            else:
                os.makedirs(os.path.dirname(target), exist_ok=True)
                with open(target, "w", encoding="utf-8") as fh:
                    fh.write(render_skeleton(str(TEMPLATES / "SPEC-oneshot.md.template"), feat,
                                             footprint=footprint, read_only=read_only,
                                             contract=feat.get("requirementsContract")))
            spec = target
        full_spec = None
        if route == "full":
            record = instruction_record(feature_dir, "spec")
            full_spec = str(Path(record["manifest"]).parent / "skills/spec/SKILL.md")
        print(json.dumps({"route": route, "reason": reason, "footprint": footprint, "readOnly": read_only, "spec": spec, "fullSpec": full_spec}))
        return 0
    if not source:
        raise Die("spec write needs --file PATH (or - for stdin)", 2)
    # On the oneshot route the skeleton the driver wrote is the spec, filled through
    # `spec fill`; a whole-file write over it was the one writer the hook could not
    # see (port audit 4, N1's remaining writers).
    if os.path.isfile(target):
        route = lib_run("graph/probes/oneshot", "--feature-dir", feature_dir, quiet=True).stdout.strip()
        if route.startswith("route=oneshot"):
            raise Die("spec write: %s is the oneshot skeleton (%s); fill it with `spec fill`, or escalate with "
                      "`spec escalate --reason`" % (target, route.partition(" reason=")[2]), 1)
    if source == "-":
        body = sys.stdin.read()
    else:
        if os.path.realpath(source) == os.path.realpath(target):
            print(target)
            return 0
        if not os.path.isfile(source):
            raise Die("spec write: no such file: %s" % source, 2)
        body = open(source, encoding="utf-8", errors="replace").read()
    contract = feat.get("requirementsContract")
    if contract and contract.get("format") == "v1":
        from requirements import parse_spec
        for no, line in enumerate(body.splitlines(), start=1):
            if "{GE-" in line:
                raise Die("spec write: %s:%d still carries the template placeholder (%s); "
                          "replace it with the real outcome prose before writing "
                          "(docs/loop-spec/requirements-format.md)" % (target, no, line.strip()), 1)
        body = normalize_v1_draft(body, contract)
        try:
            parse_spec(body, target, contract)
        except ValueError as exc:
            raise Die("spec write: %s" % exc, 1)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    with open(target, "w", encoding="utf-8") as fh:
        fh.write(body)
    print(target)
    return 0


def verification_lint_flags(feature_dir, root, target, spec):
    """`--feature-dir` selects each gate's v1-or-legacy row shape (its own
    requirementsContract.format read); a legacy feature is unaffected."""
    flags = []
    for name, args in (("artifact-lint", ["verification", target, "--feature-dir", feature_dir]),
                       ("verification-grounding-lint", [target, "--repo", root, "--spec", spec, "--feature-dir", feature_dir]),
                       ("review-triage-lint", [target]),
                       ("converged-floor", [spec, target, "--feature-dir", feature_dir])):
        out = lib_run(name, *args, quiet=True).stdout
        flags += [line for line in out.splitlines() if line.startswith("FLAG") or line.startswith("FLOOR")]
    return flags


def criteria_commands(spec_path):
    """The frontmatter `criteria:` map of a oneshot spec, {GE-NNN: command}: the commands
    the driver wrote with `spec fill --command`, the only ones `verification run` runs."""
    if not os.path.isfile(spec_path):
        return {}
    fm = re.match(r"^---\n(.*?)^---\n", open(spec_path, encoding="utf-8", errors="replace").read(), flags=re.M | re.S)
    if not fm:
        return {}
    out = {}
    for m in re.finditer(r"^  (GE-\d{3}): (.*)$", fm.group(1), flags=re.M):
        try:
            out[m.group(1)] = json.loads(m.group(2))
        except ValueError:
            out[m.group(1)] = m.group(2).strip()
    return out


def observe_command(feature_dir, root, requirement, command, binding=None, contract=None):
    """Run one required command through execution_observation.observe (task-007).
    The legacy oneshot criteria route passes no `binding`/`contract`: no
    owner/revision/scenario and no execution-inputs contract, so the record's
    environment is `unknown` but `status` still comes from exit code and
    clean-tree identity alone (see execution_observation's own LEGACY ROUTE
    docstring for why -- every legacy fixture through the 7.x window keeps
    working). The v1 scenario_checks route (task-008) passes both: `binding`
    names owner/requirement/revision/scenario from the live inventory and
    `contract` is that scenario's declared execution-inputs object, so the
    record's environment is fully checked (eligibleForV1 true). Returns
    (status, exit_code, block, execution_id): `status` and `exit_code` are the
    record's, never derived here a second time, so no caller downstream can
    compute a different answer than the one the record holds. `block` is the
    display tail capped at 200 lines, replacing the old unbounded
    subprocess.PIPE read."""
    from execution_observation import observe as observe_execution
    binding = binding or {"owner": None, "requirement": requirement, "revision": None, "scenario": None}
    record = observe_execution(feature_dir, root, binding, command, contract)
    lines = (record.get("displayTail") or "").rstrip("\n").splitlines()
    if len(lines) > 200:
        lines = lines[:200] + ["... (%d more lines)" % (len(lines) - 200)]
    exit_code = record["exitCode"]
    block = "\n".join(lines) or "(no output, exit %s)" % (exit_code if exit_code is not None else "killed")
    return record["status"], exit_code, block, record["executionId"]


def spec_scenario_checks(spec_text):
    """The frontmatter `scenario_checks` map of a v1 spec, {GE-ID/SC-ID: {command,
    executionInputs}} -- the same single-line JSON fill_requirement/normalize_v1_draft
    write and lib/requirements.py's parse_spec validates. verification_run's v1 route
    reads it here (not from parse_spec's return value: the inventory is deliberately
    just requirements/scenarios/obligations, PLAN "Component structure") to bind each
    scenario's command and input contract by stable identity, never document position."""
    from requirements import unique_object
    match = re.search(r"^scenario_checks: *(.*)$", spec_text, re.M)
    if not match:
        return {}
    return json.loads(match.group(1), object_pairs_hook=unique_object)


def _exit_label(exit_code):
    return str(exit_code) if exit_code is not None else "killed"


def verification_run(feature_dir, feat, docs, target, spec, only_row, with_tests):
    """Observe, never assert (task-007/task-008): dispatch to the v1 or legacy route by
    the feature's requirementsContract. Both write the record's status as the row's
    status, the command/exit/execution ID as its evidence, and the record's display
    tail as its block -- the lead supplies no status (port audit 4, items 2, 4), so a
    hand-edited or CLI-supplied PASS has nothing here to land in. Returns the rows
    written."""
    contract = feat.get("requirementsContract")
    if contract and contract.get("format") == "v1":
        return verification_run_v1(feature_dir, feat, target, spec, contract, only_row, with_tests)
    return verification_run_legacy(feature_dir, feat, docs, target, spec, only_row, with_tests)


def _write_verification_row(text, target, row_key, heading_key, criterion_text, status, evidence, block):
    """Insert or replace one `## Acceptance criteria` row (keyed `row_key`: a legacy
    `GE-NNN` or a v1 `GE-ID/SC-ID` pair) and its `### Criterion <heading_key>` output
    block. The two keys differ on the legacy route -- its skeleton numbers sections by
    document position (`Criterion 1`) while the row itself already carries the
    criterion's `GE-NNN` label -- and are the same value on the v1 route. Shared by
    verification_run_v1 and verification_run_legacy so this table/section insertion
    shape (an existing key replaces in place; a new one joins the table after its last
    row, port audit 5, R1) exists once."""
    cell = re.compile(r"^\| %s \| .* \|$" % re.escape(row_key), re.M)
    row_text = "| %s | %s | %s | %s |" % (row_key, criterion_text.replace("|", "\\|"), status, evidence)
    if cell.search(text):
        text = cell.sub(lambda mm: row_text, text, count=1)
    else:
        # A criterion added after the skeleton: the driver owns the shape, so the row
        # joins the table (after its last row) rather than failing the run.
        table = section_span(text, "Acceptance criteria")
        if table is None:
            raise Die("verification run: %s has no ## Acceptance criteria section" % target)
        rows_end = table[0]
        for mm in re.finditer(r"^\|.*\|$", text[table[0]:table[1]], flags=re.M):
            rows_end = table[0] + mm.end()
        text = text[:rows_end] + "\n" + row_text + text[rows_end:]
    heading = "Criterion %s" % heading_key
    span = section_span(text, heading)
    if span is not None:
        return text[:span[0]] + "\n```\n" + block + "\n```\n\n" + text[span[1]:]
    anchor = text.find("\n## Code review")
    if anchor < 0:
        raise Die("verification run: %s has no ## Code review section to place ### %s before" % (target, heading), 2)
    return text[:anchor] + "\n### %s\n\n```\n%s\n```\n" % (heading, block) + text[anchor:]


def _write_final_test_suite(feature_dir, feat, root, target, text, observed=None):
    """Write the `## Final test suite` block and its row entry, shared by both routes.
    `observed` is the legacy route's {command: (label, status, code, block,
    executionId)} dedup cache; the v1 route passes None because a shared execution
    would bind only one requirement/scenario (see verification_run_v1's own comment on
    why it never dedups). Returns (text, entry)."""
    test_cmd = ((feat.get("commands") or {}).get("test") or "").strip()
    span = section_span(text, "Final test suite")
    if span is None:
        raise Die("verification run: %s has no ## Final test suite section" % target)
    if test_cmd:
        if observed is not None and test_cmd in observed:
            source, status, code, _, execution_id = observed[test_cmd]
            block = "Same command and result as %s (exit %s)." % (source, _exit_label(code))
        else:
            binding = {"owner": None, "requirement": "tests", "revision": None, "scenario": None}
            status, code, out_block, execution_id = observe_command(feature_dir, root, "tests", test_cmd, binding=binding)
            block = "$ %s\n%s\n(exit %s) (execution:%s)" % (test_cmd, out_block, _exit_label(code), execution_id)
        entry = {"row": "tests", "status": status, "exit": code, "execution": execution_id}
    else:
        block = "(no commands.test is configured for this feature)"
        entry = {"row": "tests", "status": "N/A", "exit": None, "execution": None}
    return text[:span[0]] + "\n```\n" + block + "\n```\n" + text[span[1]:], entry


def verification_run_v1(feature_dir, feat, target, spec, contract, only_row, with_tests):
    """v1 sibling of verification_run_legacy: rows are keyed by the stable GE-ID/SC-ID
    pair scenario_checks names, bound from lib/requirements.py's live inventory every
    run -- never a document-order number a SPEC reorder would reattach to the wrong
    scenario (PLAN task-008 AC3: "rows are keyed by stable identity, never by
    position"). Same publish-once contract as the legacy route; only row identity and
    binding differ."""
    from requirements import parse_spec
    root = feature_root(feature_dir, feat)
    text = open(target, encoding="utf-8").read()
    spec_text = open(spec, encoding="utf-8").read()
    inventory = parse_spec(spec_text, spec, contract)
    checks = spec_scenario_checks(spec_text)
    written = []
    for requirement in inventory["requirements"]:
        for scenario in requirement["scenarios"]:
            key = "%s/%s" % (requirement["id"], scenario["id"])
            if only_row and key != only_row:
                continue
            entry = checks.get(key)
            binding = {"owner": contract["owner"], "requirement": requirement["id"],
                       "revision": requirement["revision"], "scenario": scenario["id"]}
            if entry is None:
                # A scenario the driver never bound a command for: a FAIL the row
                # says out loud, the v1 sibling of the legacy "no command on
                # record" row below (port audit 5, R1).
                status, code, execution_id = "FAIL", 1, None
                block = "(no command on record for %s: scenario_checks has no entry for this scenario)" % key
                evidence = "no command on record: `spec fill --row %s --scenario %s ...` writes scenario_checks[%s]" % (
                    requirement["id"], scenario["id"], key)
            else:
                # Never dedup by (command, executionInputs) across scenarios the way the
                # legacy route does: a shared record would bind only ONE requirement/
                # scenario, so every OTHER scenario's row would cite an execution ID
                # whose record names a different binding -- exactly the "row names an
                # execution id" mismatch verification-grounding-lint exists to catch.
                # PLAN's "duplicate commands may share a single execution" allowance
                # requires the record to "explicitly list every covered scenario",
                # which execution_observation's schema-1 record (task-007) does not
                # yet do; until it does, each scenario gets its own fresh observation.
                command = entry.get("command") or ""
                inputs_contract = entry.get("executionInputs")
                status, code, block, execution_id = observe_command(feature_dir, root, requirement["id"],
                                                                     command, binding=binding, contract=inputs_contract)
                evidence = "owner=%s/%s revision=%s scenario=%s `%s` -> exit %s (execution:%s)" % (
                    contract["owner"]["repository"], contract["owner"]["feature"], requirement["revision"],
                    scenario["id"], command.replace("|", "\\|"), _exit_label(code), execution_id)
            text = _write_verification_row(text, target, key, key, scenario["text"] or requirement["text"],
                                            status, evidence, block)
            with open(target, "w", encoding="utf-8") as fh:
                fh.write(text)
            written.append({"row": key, "status": status, "exit": code, "execution": execution_id})
    if with_tests:
        text, entry = _write_final_test_suite(feature_dir, feat, root, target, text)
        written.append(entry)
    with open(target, "w", encoding="utf-8") as fh:
        fh.write(compact_artifact(text))
    return written


def verification_run_legacy(feature_dir, feat, docs, target, spec, only_row, with_tests):
    """Observe, never assert: run each Good Enough criterion's command (the first
    backticked span of its line) through execution_observation.observe (task-007) and
    write the record's status as the row's status, the command/exit/execution ID as
    its evidence, and the record's display tail as its block; then commands.test into
    the Final test suite block. The lead supplies no status (port audit 4, items 2, 4):
    the row's status is copied from the record, never recomputed from a caller
    argument, so a hand-edited or CLI-supplied PASS has nothing here to land in.
    Returns the rows written."""
    root = feature_root(feature_dir, feat)
    text = open(target, encoding="utf-8").read()
    criteria = good_enough_criteria(spec)
    commands = criteria_commands(spec)
    written = []
    observed = {}
    for i, criterion in enumerate(criteria):
        row = "GE-%03d" % (i + 1)
        if only_row and row != only_row:
            continue
        command = commands.get(row)
        execution_id = None
        if command:
            if command in observed:
                source, status, code, _, execution_id = observed[command]
                block = "Same command and result as %s (exit %s)." % (source, _exit_label(code))
            else:
                status, code, block, execution_id = observe_command(feature_dir, root, row, command)
                observed[command] = ("Criterion %d" % (i + 1), status, code, block, execution_id)
            evidence = "`%s` -> exit %s (execution:%s)" % (command.replace("|", "\\|"), _exit_label(code), execution_id)
        else:
            # A criterion the driver never wrote has no command on record: a FAIL the
            # row says out loud, never a crash that leaves every row empty (port audit 5, R1).
            status, code = "FAIL", 1
            block = "(no command on record for this criterion: the frontmatter criteria map has no %s)" % row
            evidence = "no command on record: `spec fill --command --expect --row %s` writes one" % row
        text = _write_verification_row(text, target, row, str(i + 1), criterion, status, evidence, block)
        with open(target, "w", encoding="utf-8") as fh:
            fh.write(text)
        written.append({"row": row, "status": status, "exit": code, "execution": execution_id})
    if with_tests:
        text, entry = _write_final_test_suite(feature_dir, feat, root, target, text, observed=observed)
        written.append(entry)
    with open(target, "w", encoding="utf-8") as fh:
        fh.write(compact_artifact(text))
    return written


def scenario_checks_map(spec_path):
    """The frontmatter `scenario_checks:` map of a v1 spec, {GE-ID/SC-ID: {command,
    executionInputs}} -- the same regex shape as `criteria_commands` above, for the
    one other frontmatter map `spec fill` ever writes (`fill_requirement`)."""
    if not os.path.isfile(spec_path):
        return {}
    fm = re.match(r"^---\n(.*?)^---\n", open(spec_path, encoding="utf-8", errors="replace").read(), flags=re.M | re.S)
    if not fm:
        return {}
    match = re.search(r"^scenario_checks: *(.*)$", fm.group(1), flags=re.M)
    if not match:
        return {}
    try:
        return json.loads(match.group(1))
    except ValueError:
        return {}


def final_candidate_checks(feat, spec_path, ws, shas):
    """The bindings the final-candidate observer must run fresh: one per active v1
    requirement/scenario (from `scenario_checks_map`, owner+revision bound in) when the
    feature's requirementsContract is v1, else the same legacy GE-NNN `criteria:` map
    `verification_run` has always read. Either way, append one mandatory `commands.test`
    binding per bound target -- but only when a command is actually configured: an
    unconfigured test command is `N/A` here exactly as it is in `verification_run`
    (PLAN task-008 AC3 keeps every legacy fixture with no commands.test passing
    unchanged). Returns [(binding, command|None, executionInputs|None, target_name)];
    `command is None` for a v1 scenario with no scenario_checks entry is a real gap
    (a declared requirement nobody bound a check to) and is left in as a FAIL row,
    the same "no command on record" shape verification_run already gives a legacy
    criterion with no command."""
    contract = feat.get("requirementsContract")
    default_target = next(iter(shas))
    checks = []
    owner = None
    if contract and contract.get("format") == "v1":
        from requirements import parse_spec
        inventory = parse_spec(open(spec_path, encoding="utf-8").read(), spec_path, contract)
        declared = scenario_checks_map(spec_path)
        owner = inventory["owner"]
        for requirement in inventory["requirements"]:
            for scenario in requirement["scenarios"]:
                entry = declared.get(requirement["id"] + "/" + scenario["id"])
                binding = {"owner": owner, "requirement": requirement["id"],
                           "revision": requirement["revision"], "scenario": scenario["id"]}
                checks.append((binding, entry.get("command") if entry else None,
                               entry.get("executionInputs") if entry else None, default_target))
    else:
        criteria = good_enough_criteria(spec_path)
        commands = criteria_commands(spec_path)
        for i in range(len(criteria)):
            row = "GE-%03d" % (i + 1)
            binding = {"owner": None, "requirement": row, "revision": None, "scenario": None}
            checks.append((binding, commands.get(row), None, default_target))
    if ws:
        for repo in (ws.get("repos") or []):
            name = repo.get("name")
            if name not in shas:
                continue
            test_command = ((repo.get("commands") or {}).get("test") or "").strip()
            if test_command:
                binding = {"owner": owner, "requirement": "tests:%s" % name, "revision": None, "scenario": None}
                checks.append((binding, test_command, None, name))
    else:
        test_command = ((feat.get("commands") or {}).get("test") or "").strip()
        if test_command:
            binding = {"owner": owner, "requirement": "tests", "revision": None, "scenario": None}
            checks.append((binding, test_command, None, default_target))
    return checks


def final_candidate_docs(feature_dir, feat, root):
    """The tracked SPEC.md/PLAN.md bytes the final candidate binds, resolved from the
    working tree normally or -- when artifact-sink mode already removed the docs from
    it -- from the sink's preserved manifest copy, digest-validated against the store
    first (PLAN "validate that store before running"). Returns (spec_bytes, plan_bytes,
    source) where source names where they came from, for the record's own honesty."""
    docs = docs_dir(feature_dir, feat)
    spec_path, plan_path = os.path.join(docs, "SPEC.md"), os.path.join(docs, "PLAN.md")
    sink = feat.get("artifactSink")
    if not (sink and sink.get("mode") == "store"):
        if not os.path.isfile(spec_path):
            # No requirementsContract and no Good Enough section either: a feature
            # this minimal (an older/plumbing-only fixture) has nothing for
            # final_candidate_checks to bind, and that is a real, honest "nothing
            # required" -- not a reason to refuse the whole final candidate.
            return b"", b"", "absent"
        spec_bytes = open(spec_path, "rb").read()
        plan_bytes = open(plan_path, "rb").read() if os.path.isfile(plan_path) else b""
        return spec_bytes, plan_bytes, "tree"
    if not sink.get("manifest"):
        raise Die("verification run --final-candidate: artifact sink mode declared with no manifest recorded", 2)
    from artifact_sink import layout as sink_layout
    _, _, sink_root, _, _, _, _ = sink_layout(feature_dir, root, os.environ.get("LOOP_SPEC_ARTIFACT_DIR"))
    destination = os.path.join(sink_root, os.path.dirname(sink["manifest"]))
    manifest_path = os.path.join(destination, "manifest.json")
    if not os.path.isfile(manifest_path):
        raise Die("verification run --final-candidate: artifact sink manifest missing at %s" % manifest_path, 2)
    manifest = json.loads(open(manifest_path, encoding="utf-8").read())
    for name, expected in (manifest.get("files") or {}).items():
        path = os.path.join(destination, name)
        if not os.path.isfile(path):
            raise Die("verification run --final-candidate: artifact sink store is missing %s" % name, 2)
        if hashlib.sha256(open(path, "rb").read()).hexdigest() != expected:
            raise Die("verification run --final-candidate: artifact sink file changed since storage: %s" % name, 1)
    if "artifacts/SPEC.md" not in (manifest.get("files") or {}):
        raise Die("verification run --final-candidate: artifact sink manifest has no SPEC.md", 2)
    spec_bytes = open(os.path.join(destination, "artifacts/SPEC.md"), "rb").read()
    plan_bytes = (open(os.path.join(destination, "artifacts/PLAN.md"), "rb").read()
                  if "artifacts/PLAN.md" in manifest["files"] else b"")
    return spec_bytes, plan_bytes, "sink:" + sink["manifest"]


def render_final_projection(candidate, shas, rows):
    """The durable observations/final/<digest>/VERIFICATION.md projection: a plain
    record of what the final candidate observer ran, never the tracked VERIFICATION.md
    (PLAN: "do not rewrite it after the final candidate is formed")."""
    lines = ["# Final candidate verification\n", "\n",
             "Candidate: `%s`\n" % candidate, "\n",
             "| Target | SHA |", "| --- | --- |"]
    for name, sha in sorted(shas.items()):
        lines.append("| %s | `%s` |" % (name, sha))
    lines += ["", "| Requirement | Scenario | Status | Evidence |", "| --- | --- | --- | --- |"]
    for row in rows:
        lines.append("| %s | %s | %s | %s |" % (
            row["requirement"], row["scenario"] or "-", row["status"], row["evidence"]))
    return "\n".join(lines) + "\n"


def cmd_verification_final(o):
    """`verification run --final-candidate SHA` (single repo) or `--final-candidates
    PATH` ({name: sha} JSON, workspace or single) -- task-008's final-candidate
    observer (PLAN "Final candidate observations"). Verifies every named root is
    already at its declared SHA (never checks out), runs every required v1 scenario
    or legacy criterion command plus the mandatory commands.test fresh through
    execution_observation.observe, and writes the projection only under durable
    `observations/final/<candidate-digest>/` -- never onto the branch, never through
    publication_participant (these files are driver-owned runtime state, the same
    home as `observations/<id>.json` itself, so no CAS token is needed to write them).
    Always executes fresh: a newly selected candidate (or a retry of the same one)
    gets its own real run every time, never a cached reuse -- the laziness ladder
    stops here because nothing in this task's acceptance criteria asks for one, and
    a hand-rolled staleness cache is exactly the kind of speculative extraction
    CLAUDE.md's "seams, not speculation" warns against."""
    feature_dir = o.get("feature_dir") or ""
    if not feature_dir or not os.path.isfile(os.path.join(feature_dir, "feature.json")):
        usage()
    feature_dir = os.path.realpath(feature_dir)
    feat = state(feature_dir)
    ws = workspace_of(feat)
    single_sha, candidates_path = o.get("final_candidate"), o.get("final_candidates")
    if bool(single_sha) == bool(candidates_path):
        raise Die("verification run needs exactly one of --final-candidate SHA or --final-candidates PATH", 2)
    if single_sha:
        if ws is not None:
            raise Die("verification run --final-candidate is single-repo only; a workspace feature names each target with --final-candidates", 2)
        shas = {feat.get("slug") or "root": single_sha}
    else:
        try:
            shas = json.loads(open(candidates_path, encoding="utf-8").read())
        except (OSError, ValueError) as exc:
            raise Die("verification run --final-candidates %s: %s" % (candidates_path, exc), 2)
        if not isinstance(shas, dict) or not shas or not all(isinstance(v, str) and v for v in shas.values()):
            raise Die("verification run --final-candidates %s must hold a non-empty {name: sha} object" % candidates_path, 2)
        if ws is None and len(shas) != 1:
            raise Die("verification run --final-candidates: a single-repo feature has exactly one target", 2)

    root = feature_root(feature_dir, feat)
    roots = {}
    for name in shas:
        if ws is None:
            roots[name] = root
            continue
        repo = next((r for r in (ws.get("repos") or []) if r.get("name") == name), None)
        if repo is None:
            raise Die("verification run --final-candidates: unknown workspace target '%s'" % name, 2)
        roots[name] = os.path.join(ws["root"], repo["path"])
    for name, sha in shas.items():
        actual = run(["git", "-C", roots[name], "rev-parse", "HEAD"], quiet=True).stdout
        if actual != sha:
            raise Die("verification run: %s HEAD is %s, not the candidate %s -- no checkout performed" % (
                name, actual or "unknown", sha), 1)

    spec_bytes, plan_bytes, docs_source = final_candidate_docs(feature_dir, feat, root)
    spec_read_path = os.path.join(docs_dir(feature_dir, feat), "SPEC.md")
    tmp_spec = None
    if not os.path.isfile(spec_read_path):
        import tempfile
        fd, tmp_spec = tempfile.mkstemp(prefix="loop-spec-final-spec-", suffix=".md")
        with os.fdopen(fd, "wb") as fh:
            fh.write(spec_bytes)
        spec_read_path = tmp_spec
    try:
        checks = final_candidate_checks(feat, spec_read_path, ws, shas)
    finally:
        if tmp_spec:
            os.unlink(tmp_spec)

    from execution_observation import observe as observe_execution
    publication = feat.get("artifactPublication") or {}
    executions, rows, ok = [], [], True
    for binding, command, contract, target_name in checks:
        if not command:
            ok = False
            rows.append({"requirement": binding["requirement"], "scenario": binding.get("scenario"),
                         "status": "FAIL", "evidence": "no command on record for this scenario/criterion"})
            continue
        record = observe_execution(feature_dir, roots[target_name], binding, command, contract)
        executions.append(record["executionId"])
        if record["status"] != "PASS":
            ok = False
        rows.append({"requirement": binding["requirement"], "scenario": binding.get("scenario"),
                     "status": record["status"],
                     "evidence": "`%s` -> exit %s (execution:%s)" % (
                         command.replace("|", "\\|"), record["exitCode"], record["executionId"])})

    candidate = hashlib.sha256(json.dumps(sorted(shas.items()), separators=(",", ":")).encode("utf-8")).hexdigest()
    final_dir = Path(feature_dir) / "observations" / "final" / candidate
    record_doc = {
        "schema": 1, "candidate": candidate, "shas": shas, "executions": executions,
        "authoritativeHashes": {"spec": hashlib.sha256(spec_bytes).hexdigest() if spec_bytes else None,
                                 "plan": hashlib.sha256(plan_bytes).hexdigest() if plan_bytes else None,
                                 "source": docs_source},
        "evidenceEpoch": publication.get("evidenceEpoch", 0),
        "generationAtCapture": publication.get("generation", 0),
        "createdAt": now(), "ok": ok,
    }
    from feature_write import publish
    final_dir.mkdir(parents=True, exist_ok=True)
    publish(final_dir / "record.json", (json.dumps(record_doc, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8"))
    publish(final_dir / "VERIFICATION.md", render_final_projection(candidate, shas, rows).encode("utf-8"))
    print(json.dumps(record_doc, sort_keys=True, ensure_ascii=False))
    return 0 if ok else 1


FINDING_RE = re.compile(r"^\s*[-*]\s+(\S+:\d+)\s*(?:—|--|-|:)\s*(.+?)\s*$")


def verification_review(target, report, model):
    """The Code review section from the reviewer's report file, never from the lead's
    transcription: one bullet per `- <file>:<line> — <claim>` line with `verdict:
    pending`, or `none` when the report holds no finding. The d17da82 bug-fix run
    carried an invented finding because the lead thought the lint wanted one
    (port audit 4, item 3). Returns the findings written."""
    text = open(target, encoding="utf-8").read()
    span = section_span(text, "Findings")
    if span is None:
        raise Die("verification review: %s has no ### Findings section" % target)
    findings = []
    verdict = ""
    for line in open(report, encoding="utf-8", errors="replace"):
        m = FINDING_RE.match(line)
        if m and not m.group(1).startswith("verdict"):
            findings.append((m.group(1), m.group(2).rstrip(".")))
        mv = re.search(r"\b(PASS_WITH_MINOR|PASS|BLOCK)\b", line)
        if mv and not verdict:
            verdict = mv.group(1)
    body = "\n".join("- %s — %s | verdict: pending" % f for f in findings) or "none"
    text = text[:span[0]] + "\n" + body + "\n\n" + text[span[1]:]
    text = re.sub(r"^\*\*Reviewer:\*\* code-reviewer \(.*\)(?::.*)?$",
                  "**Reviewer:** code-reviewer (%s)%s" % (model, (": " + verdict) if verdict else ""), text, count=1, flags=re.M)
    with open(target, "w", encoding="utf-8") as fh:
        fh.write(compact_artifact(text))
    return [{"finding": f[0], "claim": f[1]} for f in findings], verdict


def verification_paths(o, what):
    """The feature and its two artifacts for a `verification` subcommand: (feature_dir,
    feat, docs, a private staged copy of VERIFICATION.md to author against, SPEC.md,
    root, VERIFICATION.md's real registered path). The skeleton must exist: phase-begin
    oneshot writes it. Every subcommand is one publication operation (task-004): begin
    here, author against the staged copy, and publish_artifact the result once."""
    import uuid
    feature_dir = o.get("feature_dir") or ""
    if not feature_dir or not os.path.isfile(os.path.join(feature_dir, "feature.json")):
        usage()
    feature_dir = os.path.realpath(feature_dir)
    pub.begin(feature_dir)
    feat = state(feature_dir)
    docs = docs_dir(feature_dir, feat)
    real_target, spec = os.path.join(docs, "VERIFICATION.md"), os.path.join(docs, "SPEC.md")
    if not os.path.isfile(real_target):
        raise Die("verification %s: no VERIFICATION.md at %s (phase-begin oneshot writes the skeleton)" % (what, real_target), 2)
    target = os.path.join(feature_dir, "publication-staging", "verification-" + uuid.uuid4().hex)
    os.makedirs(os.path.dirname(target), exist_ok=True)
    shutil.copyfile(real_target, target)
    return feature_dir, feat, docs, target, spec, feature_root(feature_dir, feat), real_target


def cmd_verification(argv):
    if not argv or argv[0] not in ("fill", "run", "review", "verdict"):
        usage()
    if argv[0] in ("review", "verdict"):
        o = parse_pairs(argv[1:], ("--feature-dir", "--report", "--reviewer-model", "--finding", "--verdict", "--reason", "--routing"))
        feature_dir, feat, docs, target, spec, root, real_target = verification_paths(o, argv[0])
        if argv[0] == "review":
            report = o.get("report") or os.path.join(feature_dir, "dispatch", "oneshot.review.md")
            if not os.path.isfile(report):
                raise Die("verification review: no report at %s (the reviewer writes it; in-harness, save the reviewer's result there first)" % report, 2)
            model = o.get("reviewer_model") or (feat.get("models") or {}).get("codeReviewer") or "inherit"
            findings, verdict = verification_review(target, report, model)
            publish_artifact(feature_dir, "verification", Path(target).read_bytes())
            print(json.dumps({"verification": real_target, "report": report, "reviewerVerdict": verdict or None,
                              "findings": findings,
                              "routingInstructions": str(Path(instruction_record(feature_dir, feat.get("currentPhase") or "oneshot")["manifest"]).parent / "skills/shared/review-routing.md") if findings else None,
                              "flags": verification_lint_flags(feature_dir, root, target, spec)}))
            return 0
        finding, verdict, reason = o.get("finding") or "", o.get("verdict") or "", (o.get("reason") or "").strip()
        if verdict not in ("true", "false") or not finding or not reason:
            raise Die("verification verdict needs --finding FILE:LINE --verdict true|false --reason TEXT "
                      "(false: the disproof, what shows the finding wrong)", 2)
        routing = ""
        if verdict == "true":
            from review_routes import validate
            try:
                routing = " | routing: " + json.dumps(validate(json.loads(o.get("routing") or "null")), sort_keys=True)
            except ValueError as exc:
                raise Die("verification verdict: " + str(exc), 2)
        text = open(target, encoding="utf-8").read()
        line = re.compile(r"^(- %s — .*?) \| verdict: pending$" % re.escape(finding), re.M)
        if not line.search(text):
            raise Die("verification verdict: no pending finding at %s in %s (verification review writes them from the report)" % (finding, real_target))
        text = line.sub(lambda m: "%s | verdict: %s — %s%s" % (m.group(1), verdict, reason, routing), text, count=1)
        with open(target, "w", encoding="utf-8") as fh:
            fh.write(text)
        publish_artifact(feature_dir, "verification", Path(target).read_bytes())
        print(json.dumps({"verification": real_target, "finding": finding, "verdict": verdict,
                          "flags": verification_lint_flags(feature_dir, root, target, spec)}))
        return 0
    if argv[0] == "run":
        o = parse_pairs(argv[1:], ("--feature-dir", "--row", "--final-candidate", "--final-candidates"))
        if o.get("final_candidate") or o.get("final_candidates"):
            if o.get("row"):
                raise Die("verification run --final-candidate(s) does not take --row", 2)
            return cmd_verification_final(o)
        feature_dir, feat, docs, target, spec, root, real_target = verification_paths(o, "run")
        try:
            # verification_run writes the staged copy after every criterion, never the
            # registered VERIFICATION.md itself: this publishes the final bytes once,
            # however the run ends (task-004), the same shape as the oneshot boundary.
            rows = verification_run(feature_dir, feat, docs, target, spec, o.get("row"), not o.get("row"))
        finally:
            publish_artifact(feature_dir, "verification", Path(target).read_bytes())
        print(json.dumps({"verification": real_target, "ran": rows, "flags": verification_lint_flags(feature_dir, root, target, spec)}))
        return 0 if all(r["status"] != "FAIL" for r in rows) else 1
    o = parse_pairs(argv[1:], ("--feature-dir", "--row", "--implementation", "--proof", "--integration",
                               "--integration-proof"))
    feature_dir, feat, docs, target, spec, root, real_target = verification_paths(o, "fill")
    text = open(target, encoding="utf-8").read()
    filled = []
    row = o.get("row")
    if row:
        if not re.match(r"^GE-\d{3}$", row):
            raise Die("verification fill: --row names a criterion as GE-NNN", 2)
        number = int(row[3:])
        if o.get("implementation"):
            if not o.get("proof"):
                raise Die("verification fill: --implementation FILE:LINE goes with --proof TEXT", 2)
            integ = o.get("integration") or "none"
            iproof = o.get("integration_proof") or ("the criterion's own check command exercises the change end to end" if integ == "none" else "")
            if integ != "none" and not iproof:
                raise Die("verification fill: --integration FILE:LINE goes with --integration-proof TEXT", 2)
            line = re.compile(r"^- criterion: %s \|.*$" % re.escape(row), re.M)
            if not line.search(text):
                raise Die("verification fill: %s has no grounding row for %s" % (real_target, row))
            text = line.sub(lambda _: "- criterion: %s | implementation: %s - %s | integration: %s - %s" % (
                row, o["implementation"], o["proof"].strip(), integ, iproof.strip()), text, count=1)
            filled.append("grounding:" + row)
    if not filled:
        raise Die("verification fill: nothing to fill", 2)
    with open(target, "w", encoding="utf-8") as fh:
        fh.write(text)
    publish_artifact(feature_dir, "verification", Path(target).read_bytes())
    print(json.dumps({"verification": real_target, "filled": filled, "flags": verification_lint_flags(feature_dir, root, target, spec)}))
    return 0


def cmd_oneshot(argv):
    if not argv or argv[0] != "review":
        usage()
    o = parse_pairs(argv[1:], ("--feature-dir",))
    feature_dir = o.get("feature_dir") or ""
    if not feature_dir or not os.path.isfile(os.path.join(feature_dir, "feature.json")):
        usage()
    feature_dir = os.path.realpath(feature_dir)
    pub.begin(feature_dir, read_only=True)  # oneshot review emits an event; never writes feature.json
    feat = state(feature_dir)
    if lib("harness", "session-layer") != "session":
        print(json.dumps({"action": "in-harness", "reason": lib("harness", "session-layer-reason")}))
        return 0
    root = feature_root(feature_dir, feat)
    head = run(["git", "-C", root, "rev-parse", "HEAD"], quiet=True).stdout
    package = lib("dispatch-files", "package", "--repo", root, "--base", feat.get("baseSha") or "", "--head", head)
    spec = (feat.get("artifacts") or {}).get("spec") or os.path.join(docs_dir(feature_dir, feat), "SPEC.md")
    if not os.path.isabs(spec):
        spec = os.path.join(root, spec)
    dispatch = os.path.join(feature_dir, "dispatch")
    os.makedirs(os.path.join(dispatch, "sessions"), exist_ok=True)
    report = os.path.join(dispatch, "oneshot.review.md")
    prompt = os.path.join(dispatch, "oneshot.reviewer.md")
    with open(prompt, "w", encoding="utf-8") as fh:
        fh.write("Review the package in %s against the spec %s. Write your verdict (PASS, PASS_WITH_MINOR, or BLOCK) "
                 "and every finding as `- <file>:<line> — <claim>` to %s.\n" % (package, spec, report))
    model = (feat.get("models") or {}).get("codeReviewer") or "inherit"
    argv_run = ["python3", str(REPO_ROOT / "extensions" / "sessions" / "session_run.py"), "--profile", lib("harness", "cli"),
                "--cwd", root, "--prompt-file", prompt, "--model", model, "--seed-from", root,
                "--log-dir", os.path.join(dispatch, "sessions")]
    proc = subprocess.run(argv_run, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
    if proc.returncode in (4, 5):
        proc = subprocess.run(argv_run, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
    if proc.returncode not in (0, 1, 4, 5):
        raise Die("the session runner refused the reviewer launch (exit %d): %s" % (proc.returncode, proc.stderr.strip()), 2)
    line = json.loads(proc.stdout.strip() or "{}")
    line.update({"report": report, "package": package})
    # A durable log next to the report: the run that gave up on three failed reviewer
    # sessions took their stderr with it when the feature directory went (port audit 5, R6).
    log = os.path.join(dispatch, "oneshot.reviewer.log")
    tail = ""
    for key in ("stdout", "stderr"):
        path = line.get(key) or ""
        if path and os.path.isfile(path):
            body = open(path, encoding="utf-8", errors="replace").read()
            with open(log, "a", encoding="utf-8") as fh:
                fh.write("=== %s %s (%s)\n%s\n" % (now(), key, line.get("status") or "?", body))
            if key == "stderr" and body.strip():
                tail = body.strip().splitlines()[-1]
    line["log"] = log
    if tail:
        line["lastStderrLine"] = tail[:200]
    # The event is the exit gate's proof that the review ran, so a session that ended
    # any other way, or completed without writing its report, leaves no event: the gate
    # then names the missing review instead of passing on a reviewer that never spoke
    # (port audit 3, N5).
    if proc.returncode == 0 and (line.get("status") or "") == "completed" and os.path.isfile(report):
        lib("events", "emit", feature_dir, "dispatch", "--phase", "oneshot",
            "--data", json.dumps({"role": "code-reviewer", "model": model, "rung": "session", "launchedBy": "driver"}))
    else:
        line["dispatchEvent"] = "withheld: the reviewer session did not complete with a report"
    print(json.dumps(line))
    return 0 if proc.returncode == 0 else 1


# ------------------------------------------------------------ phase-begin ----
def cmd_phase_begin(argv):
    phase = argv[0] if argv else ""
    o = parse_pairs(argv[1:], ("--feature-dir",))
    feature_dir = o.get("feature_dir") or ""
    if lib_run("graph/phases", "validate", phase, quiet=True).returncode != 0:
        usage()
    if not feature_dir or not os.path.isfile(os.path.join(feature_dir, "feature.json")):
        usage()
    feature_dir = os.path.realpath(feature_dir)
    pub.begin(feature_dir)
    handed = handed_off_here(state(feature_dir))
    if handed is not None and phase != (handed.get("from") or ""):
        print("cycle-driver: this session is finished: it handed off after %s. End the turn now; the caller starts a fresh session for %s (%s)"
              % (handed.get("from"), phase, handoff_answer(feature_dir, handed)), file=sys.stderr)
        return 4
    node = next((n for n in (read_json(GRAPH, {}) or {}).get("nodes", []) if n.get("id") == phase), {})
    instructions = instruction_record(feature_dir, phase)
    skeletons = write_skeletons(feature_dir, state(feature_dir), node)
    child_env, received = child_call(None)
    entry = subprocess.run(["bash", str(LIB_DIR / "phase-entry.sh"), phase, "--feature-dir", feature_dir],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True,
                           env=child_env)
    pub.adopt(received)  # phase-entry.sh is read-only; nothing to adopt today
    if entry.returncode > 1:
        print(entry.stdout, file=sys.stderr)
        return 2
    fields, reads, flags = {}, [], []
    for line in entry.stdout.splitlines():
        if line.startswith("fields="):
            try:
                fields = json.loads(line[7:])
            except ValueError:
                fields = {"raw": line[7:]}
        elif line.startswith("read="):
            reads.append(line[5:])
        elif line.startswith("FLAG"):
            flags.append(line)
    mode = {}
    if phase in ("spec", "discuss", "plan", "verify"):
        # `key=value key2=value with spaces`: the mode line ends in a free-text reason,
        # so a value runs until the next ` key=`.
        line = lib("phase-mode", phase, "--feature-dir", feature_dir).strip()
        mode = {m.group(1): m.group(2) for m in re.finditer(r"(\w+)=(.*?)(?=\s+\w+=|$)", line)}
    extra, extra_rc = {}, 0
    if entry.returncode == 0 and phase in ("execute", "verify"):
        prepared = lib_run(phase + "-prepare", "run", "--feature-dir", feature_dir)
        extra_rc = prepared.returncode
        extra = json.loads(prepared.stdout) if prepared.stdout else {}
    packet = {"phase": phase, "instructions": instructions, "entry": {"fields": fields, "read": reads, "flags": flags}, "mode": mode}
    if skeletons:
        packet["skeletons"] = skeletons
    if phase in ("execute", "verify"):
        packet[phase] = extra
    print(json.dumps(packet))
    if entry.returncode != 0:
        return 1
    return extra_rc


# ------------------------------------------------------------------- main ----
def delegate(script, argv):
    """The per-step contracts stay in their own scripts; this is a pass-through."""
    os.execv("/usr/bin/env", ["/usr/bin/env", "bash", str(LIB_DIR / script)] + argv)


def main(argv):
    if not argv:
        usage()
    command, rest = argv[0], argv[1:]
    if command == "task":
        delegate("execute-step.sh", rest)
    if command == "critique":
        delegate("critique-step.sh", rest)
    if command == "verify":
        if rest[:1] == ["gate"]:
            delegate("verify-gate.sh", ["run"] + rest[1:])
        if rest[:1] == ["passes"]:
            delegate("verify-passes.sh", ["run"] + rest[1:])
        usage()
    if command == "iterate":
        delegate("iterate-judged.sh", rest)
    handlers = {
        "deliver": cmd_deliver, "begin": cmd_begin, "phase-begin": cmd_phase_begin, "start": cmd_start,
        "init": cmd_init, "resume": cmd_resume, "next": cmd_next, "finish": cmd_finish,
        "escalate": cmd_escalate, "spec": cmd_spec, "plan": cmd_plan, "oneshot": cmd_oneshot,
        "verification": cmd_verification, "decline": cmd_decline,
    }
    if command not in handlers:
        usage()
    return handlers[command](rest)


if __name__ == "__main__":
    try:
        code = main(sys.argv[1:])
    except Die as die:
        if die.message:
            print("cycle-driver: %s" % die.message, file=sys.stderr)
        code = die.code
    except ValueError as exc:
        # begin_operation/write_operation refuse with ValueError (stale token, an
        # active migration, an unfinished publication): the same clean report
        # feature_write.py's and artifact_publication.py's own CLIs give it, not a
        # traceback that still names the reason but buries it under a stack.
        print("cycle-driver: %s" % exc, file=sys.stderr)
        code = 1
    finally:
        # Whatever this operation's current token is -- accepted, or never begun --
        # goes back to our own parent's LOOP_SPEC_PUBLICATION_TOKEN_OUTPUT, on every exit
        # path including Die and delegate()'s pre-begin commands (finish() is a no-op
        # when begin() was never called).
        pub.finish()
    sys.exit(code)
