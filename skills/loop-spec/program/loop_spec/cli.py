"""Command-line entry point: argparse wiring, dispatch, and the LoopSpecError boundary.

Every subcommand not yet implemented in this wave still registers so `--help` lists
the whole surface; running one raises a "lands in a later wave" error instead of
argparse's own "unrecognized command", so the CLI is honest about what exists.
"""
import argparse
import json
import os
import re
import shlex
from pathlib import Path

from loop_spec import VERSION, attest, contract, controller, log, questions, steps
from loop_spec.entries import ENTRIES, RESUME_PHASES
from loop_spec.errors import LoopSpecError
from loop_spec.events import emit as emit_event
from loop_spec.events import marker_next, marker_wait
from loop_spec.contract import subagent_type
from loop_spec.jsonio import read_json
from loop_spec.paths import FeaturePaths, feature_dir, repo_id, state_home
from loop_spec.postconditions import retry_limit
from loop_spec.state import StateStore

# Every run-starting entry (the registry) plus the phases a run resumes at by name.
_CONTROLLER_ENTRIES = (*ENTRIES, *RESUME_PHASES)


def _add_common(parser: argparse.ArgumentParser, require_root: bool = True) -> None:
    parser.add_argument("--project-root", required=require_root)
    parser.add_argument("--state-home")
    parser.add_argument("--slug")
    parser.add_argument("--answer-policy", choices=["default"], default=None)


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="loop-spec")
    parser.add_argument("--version", action="version", version=VERSION)
    sub = parser.add_subparsers(dest="command", required=True)

    for name in _CONTROLLER_ENTRIES:
        p = sub.add_parser(name)
        _add_common(p)
        takes = ENTRIES[name].takes if name in ENTRIES else None
        if takes == "request":
            p.add_argument("--request")
            p.add_argument("--request-file")
        elif takes == "pr":
            p.add_argument("--pr")

    _add_common(sub.add_parser("status"))

    p = sub.add_parser("phase")
    p.add_argument("name")
    p.add_argument("--context", required=True)
    p.add_argument("--product", required=True)
    _add_common(p, require_root=False)

    p = sub.add_parser("submit")
    p.add_argument("--step", required=True)
    p.add_argument("--dispatch")
    p.add_argument("--result-file")
    _add_common(p)

    p = sub.add_parser("answer")
    p.add_argument("--question", required=True)
    p.add_argument("--answer", required=True)
    p.add_argument("--scope", choices=["question", "run"], default="question")
    _add_common(p)

    p = sub.add_parser("emit")
    p.add_argument("--state-dir", required=True)
    p.add_argument("--event", required=True)
    p.add_argument("--data")

    return parser


def _cmd_emit(args: argparse.Namespace) -> int:
    if args.data:
        try:
            data = json.loads(args.data)
        except json.JSONDecodeError as exc:
            raise LoopSpecError(
                f"--data is not valid JSON: {exc}",
                repair='pass a JSON object string, e.g. --data \'{"summary":"..."}\'',
            ) from exc
    else:
        data = None
    paths = FeaturePaths(root=Path(args.state_dir))
    emit_event(paths, args.event, data, source="implementation")
    return 0


def _print_summary(state: dict, paths: FeaturePaths) -> None:
    run, phase, budget = state["run"], state["phase"], state["budget"]
    log.stdout.info(f"run: {run['id']} entry: {run['entry']}")
    log.stdout.info(f"phase: {phase['current']} attempt: {phase['attemptId']}")
    log.stdout.info(f"revisions: requirements={state['revisions']['requirements']} plan={state['revisions']['plan']}")
    log.stdout.info(f"budget: {budget['spent']}/{budget['limit']}")
    for entry in state.get("closeOuts") or []:
        if entry["status"] == "active":
            source = entry["source"]
            log.stdout.info(f"close-out: {entry['id']} {entry['repo']} (iterate {source['attemptId']} gap {source['gapIndex']})")

    open_question = state["questions"]["open"]
    if open_question is None:
        log.stdout.info("open question: None")
    else:
        try:
            record = read_json(Path(open_question["path"]))
            text, options = record["text"], [o["value"] for o in record["options"]]
        except (OSError, ValueError, KeyError):
            text, options = None, []
        log.stdout.info(f"open question: {open_question['questionId']}: {text}")
        log.stdout.info(f"  options: {options}")

    open_steps = state["steps"]["open"]
    if not open_steps:
        log.stdout.info("open steps: []")
    for s in open_steps:
        step_path = paths.steps_dir / s["stepAttemptId"] / "step.json"
        log.stdout.info(f"open step: {s['stepAttemptId']}: {step_path}")
        log.stdout.info(f"  kind: {s.get('kind')} role: {s.get('role')}")
        try:
            dispatch = read_json(step_path).get("dispatchPrompt")
        except (OSError, ValueError):
            dispatch = None
        if dispatch:
            log.stdout.info(f"  dispatch prompt: {dispatch!r}")

    result = state.get("result")
    log.stdout.info(f"result: {result.get('classification') if result else None}")


def _cmd_status(args: argparse.Namespace) -> int:
    root = Path(args.project_root)
    home = state_home(args.state_home)
    rid = repo_id(root)
    repo_home = home / rid

    if args.slug:
        paths = FeaturePaths(root=feature_dir(home, rid, args.slug))
        if not paths.state_json.exists():
            log.stdout.info(f"no loop-spec state for {root}")
            return 0
        _print_summary(StateStore.open(paths).state, paths)
        return 0

    if not repo_home.exists():
        log.stdout.info(f"no loop-spec state for {root}")
        return 0
    slugs = sorted(p.name for p in repo_home.iterdir() if p.is_dir())
    if not slugs:
        log.stdout.info(f"no loop-spec state for {root}")
        return 0
    for slug in slugs:
        log.stdout.info(slug)
    return 0


def _feature_paths(args: argparse.Namespace, slug: str) -> FeaturePaths:
    home = state_home(args.state_home)
    rid = repo_id(Path(args.project_root))
    return FeaturePaths(root=feature_dir(home, rid, slug))


def _open_store(args: argparse.Namespace) -> tuple[StateStore, FeaturePaths]:
    if not args.slug:
        raise LoopSpecError("--slug is required", repair="pass --slug <slug>, see `loop-spec status`")
    paths = _feature_paths(args, args.slug)
    store = StateStore.open(paths)
    controller.check_compatible(store)  # before submit or answer writes anything (7.1.0)
    return store, paths


def _invocation(args: argparse.Namespace) -> dict:
    """What every follow-up command needs, carried on the markers (7.4.0, D5)."""
    return {"program": str(Path(__file__).resolve().parents[1] / "loop-spec"),
            "stateHome": str(state_home(args.state_home)), "projectRoot": str(Path(args.project_root))}


def _print_next(paths: FeaturePaths, next_, args: argparse.Namespace) -> None:
    # A "wait" Next means the run is waiting on steps a caller already
    # dispatched: LOOP_SPEC_WAIT, never a LOOP_SPEC_NEXT (there is nothing new
    # to act on). Otherwise print one LOOP_SPEC_NEXT per step a wave issued at
    # once (the primary Next plus its `also` siblings).
    if next_.kind == "wait":
        marker_wait(paths, read_json(next_.path)["open"], _invocation(args))
        return
    for n in [next_, *next_.also]:
        marker_next(n.kind, str(n.path), n.slug, _invocation(args))


def _request_text(args: argparse.Namespace) -> str | None:
    request_file = getattr(args, "request_file", None)
    if request_file:
        return Path(request_file).read_text(encoding="utf-8")
    return getattr(args, "request", None)


_REPAIR_COMMAND = re.compile(r"`loop-spec (" + "|".join(("status", *_CONTROLLER_ENTRIES, "submit", "answer")) + r")\b")


def _runnable_repair(repair: str, args: argparse.Namespace) -> str:
    """7.2.0: a repair names `loop-spec <command>`, which is not on PATH in a consumer
    repo and would read the default state home; name this launcher and this call's
    project root and state home instead, so the hint runs as printed."""
    project_root = getattr(args, "project_root", None)
    if not project_root:
        return repair
    prefix = shlex.quote(str(Path(__file__).resolve().parents[1] / "loop-spec"))
    flags = f"--project-root {shlex.quote(str(project_root))} --state-home {shlex.quote(str(state_home(args.state_home)))}"
    return _REPAIR_COMMAND.sub(lambda m: f"`{prefix} {m.group(1)} {flags}", repair)


def main(argv: list[str] | None = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    try:
        if args.command == "emit":
            return _cmd_emit(args)
        if args.command == "status":
            return _cmd_status(args)
        if args.command == "phase":
            return contract.run_phase(args.name, Path(args.context), Path(args.product))
        if args.command in _CONTROLLER_ENTRIES:
            next_ = controller.run_entry(
                args.command, project_root=Path(args.project_root), request_text=_request_text(args),
                slug=args.slug, state_home=args.state_home, answer_policy=args.answer_policy,
                pr=getattr(args, "pr", None),
            )
            _print_next(_feature_paths(args, next_.slug), next_, args)
            return 0
        if args.command == "submit":
            store, paths = _open_store(args)
            host = attest.ClaudeCodeAttestor() if os.environ.get("CLAUDE_CODE_SESSION_ID") else None
            submission = steps.submit(store, paths, step_id=args.step, dispatch_name=args.dispatch, host=host,
                                       result_file=args.result_file, project_root=Path(args.project_root))
            if submission.refused is not None:
                # LF-60: nothing was accepted; continue_run raises the blocked question.
                log.stderr.info(f"[{submission.step['phase'].upper()}] step {args.step} refused: {submission.refused}; "
                                "nothing was accepted from it")
                _print_next(paths, controller.continue_run(store, paths, project_root=Path(args.project_root)), args)
                return 0
            if submission.redispatch is not None:
                step_path = paths.steps_dir / submission.step["stepAttemptId"] / "step.json"
                tag = submission.step["phase"].upper()
                attempts = submission.step["attestationAttempts"]
                log.stdout.info(f"[{tag}] step {args.step} unattested ({attempts}/{retry_limit()}): "
                                f"{submission.step['reason']}; dispatch a fresh worker named {submission.redispatch} "
                                f"with subagent_type {subagent_type(submission.step.get('effort'))} "
                                f"and the same dispatchPrompt (or prompt, for a step without one) and submit again with --dispatch {submission.redispatch}")
                marker_next("step", str(step_path), args.slug, _invocation(args))
                return 0
            controller.route_submission(store, paths, submission.step, submission.result)
            next_ = controller.continue_run(store, paths, project_root=Path(args.project_root))
            _print_next(paths, next_, args)
            return 0
        if args.command == "answer":
            store, paths = _open_store(args)
            questions.answer(store, paths, question_id=args.question, value=args.answer, scope=args.scope, by="human")
            next_ = controller.continue_run(store, paths, project_root=Path(args.project_root))
            _print_next(paths, next_, args)
            return 0
        raise LoopSpecError(f"{args.command} lands in a later wave", repair="wait for the wave")
    except LoopSpecError as exc:
        log.stderr.error(f"loop-spec: {exc.message}")
        log.stderr.error(f"  repair: {_runnable_repair(exc.repair, args)}")
        return 1
