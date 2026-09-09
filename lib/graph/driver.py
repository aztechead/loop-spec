#!/usr/bin/env python3
"""driver.py - The cycle's mechanical loop, in one program with one-line answers.

Why: the orchestration between phases (preflight, invocation parsing, feature init,
resume adoption, watchdog, journaling, state commits, checkpoint PRs, graph stepping,
model-map activation, completion, escalation) was two thousand lines of prose with
embedded shell that the lead model re-executed by hand at every boundary, then a Bash
script that called the graph engine as a subprocess at every step. This module IS
that loop, in the same process as the engine (lib/graph/engine.py), so the cycle's
loop and the graph's loop are one program (orchestrator-port-plan.md, WP4). The
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
        New feature: adopt-PR probe, clean guard, base, execution root, bootstrap.
        Prints {featureDir, slug, executionRoot, enterWorktree, branch, baseBranch,
        baseSha, greenfield}. `enterWorktree` non-null means the caller must call
        EnterWorktree({path}) before anything else. Exit 0/1/2.

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
        self-reported (orchestrator-port-principles.md, rule 6). Prints the runner's
        JSON line plus {report, package}. In-harness (an attended session, no profile)
        it prints {action: "in-harness"} and the lead dispatches the reviewer through
        the harness tool. Exit 0; 1 the session failed; 2 bad invocation.

    cycle-driver.sh spec write --feature-dir DIR --file PATH
        Copy PATH (or stdin for `-`) to {docs}/SPEC.md, the only target this command
        accepts, and print the path. The lead never resolves the docs directory itself:
        a spec written next to the lead in the main checkout while the feature lived in
        a worktree was the misplaced-artifact REDO on two runs. Exit 0; 2 bad invocation.

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
        Then post-phase bookkeeping and the graph step. Prints exactly ONE answer line:
          NEXT phase=<id> label="<label>" effort=<system1|system2>
          PAUSED node=<id>            (human gate; re-invoke the cycle to continue)
          HANDOFF next=<phase> model=<selector>   (one phase per session; relaunch)
          REWIND next=<phase>         (the graph lists <phase> before the returned one; relaunch)
          DONE status=<completed|escalated|paused> [reason=<r>]
          ABORT reason=<r>            (exit 1; diagnostics on stderr)
        followed by zero or more `EXT <instruction or fact=path>` lines for NEXT.
        A phase that returns hands off: the next phase starts in a fresh session
        (`/loop-spec:cycle`), whose first call is `next` without --returned-from.
        Exit 0 answered; 1 graph abort or failure.

    cycle-driver.sh finish --feature-dir DIR [--completed N]
        Terminal result + chain verdict. Prints {status, prUrl, targets, warnings,
        feedback, chain, backlogCount, exitWorktree}. Exit 0; 1 delivery incomplete.

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
    proc = subprocess.run([str(a) for a in args], cwd=cwd, input=stdin_text, stdout=stdout,
                          stderr=stderr, universal_newlines=True, env=env)
    if check and proc.returncode != 0:
        raise Die("", proc.returncode)
    return (proc.stdout or "").rstrip("\n") if not passthrough else ""


def run(args, cwd=None, quiet=False, stdin_text=None):
    """sh without check: the CompletedProcess, for callers that read the code."""
    proc = subprocess.run([str(a) for a in args], cwd=cwd, input=stdin_text,
                          stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL if quiet else None, universal_newlines=True)
    proc.stdout = (proc.stdout or "").rstrip("\n")
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


def fset(feature_dir, key, value):
    lib("feature-write", "set", feature_dir, key, json.dumps(value), passthrough=False)


def fappend(feature_dir, key, value):
    lib("feature-write", "append", feature_dir, key, json.dumps(value))


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
    sid = session_id()
    if isinstance(rec, dict) and sid and rec.get("id") == sid:
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
            fset(fdir, "currentTeamName", None)
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
                    raise Die("this session handed off after %s; %s starts in a fresh invocation (%s)"
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
             "--greenfield", "--spec-file", "--commands", "--repos", "--backlog-entry")


def cmd_init(argv):
    o = parse_pairs(argv, INIT_OPTS)
    slug, title = o.get("slug", ""), o.get("title", "")
    if not slug or not title:
        usage()
    directory = os.path.realpath(o.get("dir") or os.getcwd())
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
    lib("feature-write", feature_dir, json.dumps(fj))
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


def cmd_next(argv):
    o = parse_pairs(argv, ("--feature-dir", "--returned-from", "--note"))
    feature_dir = o.get("feature_dir") or ""
    returned = o.get("returned_from") or ""
    note = o.get("note") or ""
    if not feature_dir or not os.path.isfile(os.path.join(feature_dir, "feature.json")):
        usage()
    feature_dir = os.path.realpath(feature_dir)
    feat = state(feature_dir)
    slug = feat.get("slug")
    ws_mode = "workspace" if workspace_of(feat) is not None else "single"
    repo_root = lib("cycle-result", "resolve-root", os.path.join(feature_dir, "..", "..", ".."))
    os.chdir(repo_root)

    handed = handed_off_here(feat)
    if handed is not None and returned != (handed.get("from") or ""):
        print(handoff_answer(feature_dir, handed))
        return 0

    if returned:
        answer = returned_checks(feature_dir, returned)
        if answer is not None:
            print(answer)
            return 0
        answer = boundary_review(feature_dir, returned)
        if answer is not None:
            print(answer)
            return 0
        # The phase's exit gates run here, once, whatever the phase skill did: a lead that
        # skipped them or ran them from the wrong directory was every second eval finding.
        completed = feat.get("completedPhases") or []
        if returned != "deliver" and (completed[-1] if completed else "") != returned:
            exit_args = [returned, "--feature-dir", feature_dir]
            if returned == "iterate" and iterate_is_terminal(feature_dir):
                exit_args.append("--terminal")
            exit_proc = subprocess.run(["bash", str(LIB_DIR / "phase-exit.sh")] + exit_args,
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
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
                    cmd_escalate(["--feature-dir", feature_dir, "--reason", reason], silent=True)
                    print("DONE status=escalated reason=%s" % reason)
                    return 0
                print("REDO phase=%s flags=%d attempt=%d" % (returned, len(flags), redo_count))
                for flag in flags:
                    print(flag)
                return 0
            if exit_proc.returncode != 0:
                print("ABORT reason=phase-exit-failed exit=%d" % exit_proc.returncode)
                print(exit_out, file=sys.stderr)
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
    # preset, tier, and phaseHandoff predate this schema; they are strays the reader keeps
    # out of every typed view, so the one place that drops them reads the strays on purpose.
    strays = json.loads(lib("feature-read", feature_dir, "--strays"))
    if any(key in strays for key in ("preset", "tier", "phaseHandoff")):
        merged = dict(json.loads(lib("feature-read", feature_dir, "--all", "--drop-strays")))
        merged.update({k: v for k, v in strays.items() if k not in ("preset", "tier", "phaseHandoff")})
        lib("feature-write", feature_dir, json.dumps(merged))
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
    fset(feature_dir, "driverNext", {"phase": nxt, "at": now()})
    print('NEXT phase=%s label="%s" effort=%s' % (nxt, label, effort))
    ext = lib_run("extension-points", "instructions", nxt, "prepend", quiet=True).stdout
    ext += "\n" + lib_run("extension-points", "facts", quiet=True).stdout
    for line in ext.splitlines():
        if line:
            print("EXT " + line)
    return 0


def reviewer_dispatched(feature_dir, phase):
    events = os.path.join(feature_dir, "events.jsonl")
    if not os.path.isfile(events):
        return False
    for line in open(events, encoding="utf-8", errors="replace"):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        if e.get("event") == "dispatch" and e.get("phase") == phase \
                and "code-reviewer" in str((e.get("data") or {}).get("role") or ""):
            return True
    return False


def boundary_review(feature_dir, phase):
    """ONESHOT's one review pass, run by the driver at the phase boundary when the
    session layer answers and no reviewer dispatch is on record. The live followup-haiku
    run implemented the fix, wrote a dispatch event by hand in the wrong shape, and
    escalated on the gate that could not find it: the lead's step was the failure, so
    the step is the driver's (orchestrator-port-principles.md, rules 6 and 12). Returns
    the one REDO that hands the lead the report, or None."""
    if phase != "oneshot" or reviewer_dispatched(feature_dir, phase):
        return None
    if lib("harness", "session-layer") != "session":
        return None
    out = capture(cmd_oneshot, ["review", "--feature-dir", feature_dir])
    rec = json.loads(out.strip() or "{}")
    status = rec.get("status") or "failed"
    if status != "completed":
        return ("REDO phase=oneshot flags=1\nFLAG [review] the driver-launched reviewer session ended %s (%s): "
                "read %s, then return again" % (status, rec.get("stderr") or rec.get("envFault") or "no detail", rec.get("stdout") or "its log"))
    return ("REDO phase=oneshot flags=1\nFLAG [review] the driver ran the one review pass; its verdict and findings are in %s: "
            "record each finding under ## Code review with your verdict (skills/oneshot/SKILL.md, One review pass), "
            "fix what needs fixing, then return" % rec.get("report"))


def returned_checks(feature_dir, phase):
    """What a returned phase may have left behind that ends the loop before any
    routing. Returns the answer line, or None to continue."""
    result = read_json(os.path.join(feature_dir, "result.json"), {}) or {}
    if result.get("status") == "paused" and result.get("reason") in (
            "spec-confirmation-declined", "spec-override-declined"):
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
    # driver had edited the project's .gitignore to make them (orchestrator-port-plan.md,
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
            subprocess.run(["bash", str(LIB_DIR / "checkpoint-pr.sh"), "create", feature_dir,
                            "--reason", "autonomous phase checkpoint: " + nxt], stdout=sys.stderr)

    if nxt == "completed" or nxt.startswith("human.") or nxt == phase:
        return None
    # The graph names the one exception to one phase per session: an edge carrying
    # sameSession (spec -> oneshot, oneshot -> deliver: the short route is one session end
    # to end). It paid a session's fixed cost per phase for a two-line fix, and each session
    # loaded its whole context (orchestrator-port-followup.md, F2; live run 2 paid the DELIVER
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
    print(json.dumps({
        "status": status, "prUrl": pr_url or None, "summary": summary,
        "targets": delivery.get("targets") or [], "feedback": delivery.get("feedback"),
        "warnings": feat.get("warnings") or [], "chain": chain, "backlogCount": int(backlog_count),
        "exitWorktree": is_claude_worktree_feature(feat),
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
    fset(feature_dir, "currentTeamName", None)
    fset(feature_dir, "currentTeammates", [])
    feat = state(feature_dir)
    phase = feat.get("currentPhase")
    lib_run("cycle-result", "write", feature_dir, "--status", "escalated", "--reason", reason,
            "--summary", "Cycle stopped during %s: %s" % (phase, reason))
    subprocess.run(["bash", str(LIB_DIR / "checkpoint-pr.sh"), "create", feature_dir, "--reason", reason],
                   stdout=sys.stderr)
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
def cmd_begin(argv):
    directory, args = split_dir_args(argv)
    st = json.loads(capture(cmd_start, ["--dir", directory, "--"] + args))
    if st.get("decisions"):
        print(json.dumps(dict(st, action="decisions")))
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
    """Run a subcommand in this process and return what it printed."""
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
    deliver = subprocess.run(["bash", str(LIB_DIR / "deliver.sh"), "run", feature_dir],
                             stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, universal_newlines=True)
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


def render_skeleton(template, feat, footprint=None, spec_path=None, read_only=None):
    """A template with the facts the driver holds filled in and every value the lead
    owns left as a {placeholder}. The shape is the gates' business, so it is written
    here once instead of retyped by the lead per run (six REDO rounds on the dda2cca
    bug fix were format rounds; orchestrator-port-followup.md, F4)."""
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
        if criteria:
            text = text.replace(
                "- criterion: GE-001 | implementation: {path}:{line} - {what it proves} | integration: {path}:{line} - {what it proves}\n",
                "".join("- criterion: GE-%03d | implementation: {path}:{line} - {what it proves} | integration: {path}:{line} - {what it proves}\n" % (i + 1)
                        for i in range(len(criteria))))
            # A criterion is often a shell pipeline; a bare `|` splits the table row
            # and lib/converged-floor.sh reads its status from the wrong cell (live
            # run 3 paid a REDO and ten edits for one).
            text = text.replace(
                "| 1 | {from SPEC} | PASS / FAIL / BLOCKED / N/A | `{verify command}` -> {output summary} |\n",
                "".join("| GE-%03d | %s | PASS | `{verify command}` -> {output summary} |\n" % (i + 1, c.replace("|", "\\|"))
                        for i, c in enumerate(criteria)))
            text = text.replace(
                "### Criterion 1\n\n```\n{full output of verify command}\n```\n\n(repeat per criterion)\n",
                "".join("### Criterion %d\n\n```\n{full output of verify command}\n```\n\n" % (i + 1) for i in range(len(criteria))))
    return text


def write_skeletons(feature_dir, feat, node):
    """Each absent file the node's ingress lists under `skeletons`, written from its
    template. Returns the paths written."""
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
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "w", encoding="utf-8") as fh:
            fh.write(render_skeleton(str(template), feat, spec_path=spec))
        written.append(target)
    return written


def cmd_spec(argv):
    sub = argv[0] if argv else ""
    if sub not in ("skeleton", "write"):
        usage()
    o = parse_pairs(argv[1:], ("--feature-dir", "--file") if sub == "write" else ("--feature-dir",))
    feature_dir = o.get("feature_dir") or ""
    source = o.get("file")
    if not feature_dir or not os.path.isfile(os.path.join(feature_dir, "feature.json")):
        usage()
    feature_dir = os.path.realpath(feature_dir)
    feat = state(feature_dir)
    target = os.path.join(docs_dir(feature_dir, feat), "SPEC.md")
    if sub == "skeleton":
        # The route is a function of the scout's record, and the model may lengthen it,
        # never shorten it (orchestrator-port-principles.md, rule 1). The probe reads the
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
                                             footprint=footprint, read_only=read_only))
            spec = target
        print(json.dumps({"route": route, "reason": reason, "footprint": footprint, "readOnly": read_only, "spec": spec}))
        return 0
    if not source:
        raise Die("spec write needs --file PATH (or - for stdin)", 2)
    if source == "-":
        body = sys.stdin.read()
    else:
        if os.path.realpath(source) == os.path.realpath(target):
            print(target)
            return 0
        if not os.path.isfile(source):
            raise Die("spec write: no such file: %s" % source, 2)
        body = open(source, encoding="utf-8", errors="replace").read()
    os.makedirs(os.path.dirname(target), exist_ok=True)
    with open(target, "w", encoding="utf-8") as fh:
        fh.write(body)
    print(target)
    return 0


def cmd_oneshot(argv):
    if not argv or argv[0] != "review":
        usage()
    o = parse_pairs(argv[1:], ("--feature-dir",))
    feature_dir = o.get("feature_dir") or ""
    if not feature_dir or not os.path.isfile(os.path.join(feature_dir, "feature.json")):
        usage()
    feature_dir = os.path.realpath(feature_dir)
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
    # The event is the exit gate's proof that the review ran, so a session that ended
    # any other way, or completed without writing its report, leaves no event: the gate
    # then names the missing review instead of passing on a reviewer that never spoke
    # (orchestrator-port-followup-3.md, N5).
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
    handed = handed_off_here(state(feature_dir))
    if handed is not None and phase != (handed.get("from") or ""):
        print("cycle-driver: this session handed off after %s; %s starts in a fresh invocation (%s)"
              % (handed.get("from"), phase, handoff_answer(feature_dir, handed)), file=sys.stderr)
        return 4
    node = next((n for n in (read_json(GRAPH, {}) or {}).get("nodes", []) if n.get("id") == phase), {})
    skeletons = write_skeletons(feature_dir, state(feature_dir), node)
    entry = subprocess.run(["bash", str(LIB_DIR / "phase-entry.sh"), phase, "--feature-dir", feature_dir],
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
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
    packet = {"phase": phase, "entry": {"fields": fields, "read": reads, "flags": flags}, "mode": mode}
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
        "escalate": cmd_escalate, "spec": cmd_spec, "oneshot": cmd_oneshot,
    }
    if command not in handlers:
        usage()
    return handlers[command](rest)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Die as die:
        if die.message:
            print("cycle-driver: %s" % die.message, file=sys.stderr)
        sys.exit(die.code)
