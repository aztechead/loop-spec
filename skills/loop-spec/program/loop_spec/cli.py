"""Command-line entry point: argparse wiring, dispatch, and the LoopSpecError boundary.

Every subcommand not yet implemented in this wave still registers so `--help` lists
the whole surface; running one raises a "lands in a later wave" error instead of
argparse's own "unrecognized command", so the CLI is honest about what exists.
"""
import argparse
import json
import os
import sys
from pathlib import Path

from . import VERSION, attest, contract, controller, questions, steps
from .errors import LoopSpecError
from .events import emit as emit_event
from .events import marker_next
from .jsonio import read_json
from .paths import FeaturePaths, feature_dir, repo_id, state_home
from .state import StateStore

# Full-cycle and single-phase controller entries: same later-wave behavior for now.
_CONTROLLER_ENTRIES = ("cycle", "micro", "debug", "revise",
                       "spec", "plan", "execute", "verify", "iterate", "deliver")


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
        if name in ("cycle", "micro"):
            p.add_argument("--request")
            p.add_argument("--request-file")
        elif name == "debug":
            p.add_argument("--request")
        elif name == "revise":
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
    print(f"run: {run['id']} entry: {run['entry']}")
    print(f"phase: {phase['current']} attempt: {phase['attemptId']}")
    print(f"revisions: requirements={state['revisions']['requirements']} plan={state['revisions']['plan']}")
    print(f"budget: {budget['spent']}/{budget['limit']}")

    open_question = state["questions"]["open"]
    if open_question is None:
        print("open question: None")
    else:
        try:
            text = read_json(Path(open_question["path"]))["text"]
        except (OSError, ValueError, KeyError):
            text = None
        print(f"open question: {open_question['questionId']}: {text}")

    open_steps = state["steps"]["open"]
    if not open_steps:
        print("open steps: []")
    for s in open_steps:
        print(f"open step: {s['stepAttemptId']}: {paths.steps_dir / s['stepAttemptId'] / 'step.json'}")

    result = state.get("result")
    print(f"result: {result.get('classification') if result else None}")


def _cmd_status(args: argparse.Namespace) -> int:
    root = Path(args.project_root)
    home = state_home(args.state_home)
    rid = repo_id(root)
    repo_home = home / rid

    if args.slug:
        paths = FeaturePaths(root=feature_dir(home, rid, args.slug))
        if not paths.state_json.exists():
            print(f"no loop-spec state for {root}")
            return 0
        _print_summary(StateStore.open(paths).state, paths)
        return 0

    if not repo_home.exists():
        print(f"no loop-spec state for {root}")
        return 0
    slugs = sorted(p.name for p in repo_home.iterdir() if p.is_dir())
    if not slugs:
        print(f"no loop-spec state for {root}")
        return 0
    for slug in slugs:
        print(slug)
    return 0


def _open_store(args: argparse.Namespace) -> tuple[StateStore, FeaturePaths]:
    if not args.slug:
        raise LoopSpecError("--slug is required", repair="pass --slug <slug>, see `loop-spec status`")
    home = state_home(args.state_home)
    rid = repo_id(Path(args.project_root))
    paths = FeaturePaths(root=feature_dir(home, rid, args.slug))
    return StateStore.open(paths), paths


def _request_text(args: argparse.Namespace) -> str | None:
    request_file = getattr(args, "request_file", None)
    if request_file:
        return Path(request_file).read_text(encoding="utf-8")
    return getattr(args, "request", None)


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
            marker_next(next_.kind, str(next_.path))
            return 0
        if args.command == "submit":
            store, paths = _open_store(args)
            host = attest.ClaudeCodeAttestor() if os.environ.get("CLAUDE_CODE_SESSION_ID") else None
            steps.submit(store, paths, step_id=args.step, dispatch_name=args.dispatch, host=host)
            next_ = controller.continue_run(store, paths, project_root=Path(args.project_root))
            marker_next(next_.kind, str(next_.path))
            return 0
        if args.command == "answer":
            store, paths = _open_store(args)
            questions.answer(store, paths, question_id=args.question, value=args.answer, scope=args.scope, by="human")
            next_ = controller.continue_run(store, paths, project_root=Path(args.project_root))
            marker_next(next_.kind, str(next_.path))
            return 0
        raise LoopSpecError(f"{args.command} lands in a later wave", repair="wait for the wave")
    except LoopSpecError as exc:
        print(f"loop-spec: {exc.message}", file=sys.stderr)
        print(f"  repair: {exc.repair}", file=sys.stderr)
        return 1
