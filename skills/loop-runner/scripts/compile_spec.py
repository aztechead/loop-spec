#!/usr/bin/env python3
"""
compile_spec.py — spec → plan. Layer 2 of loop-runner, and the bridge this whole
skill exists for: you write a goal or spec the way you normally would; this turns
it into loops Claude Code will run.

A spec is a bundle of testable claims. Compilation makes that explicit:
  1. Read the spec (plus a look at the repo for context).
  2. Decompose into small, independently-verifiable tasks with minimal dependencies.
  3. For EACH task, synthesize a verifier — a shell command that exits 0 only when
     that task is genuinely done. The verifier is the product; a task the compiler
     cannot find a verifier for gets flagged, not silently passed through.
  4. Emit plan/tasks.json (schema in planlib.py), validated before it's written —
     a plan that compiles is a plan the supervisor can run.

Compilation itself is one bounded `claude -p` invocation (read-only tools, its own
budget cap via --max-turns), so the compiler is subject to the same discipline as
the loops it produces. On schema/validation failure it retries once, feeding the
errors back — the compiler eats its own dogfood: act, verify, correct.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from planlib import validate_plan  # noqa: E402
from loop import LoopConfig, run_claude  # noqa: E402

PLAN_SCHEMA_DOC = """{
  "spec": "<path to the spec file>",
  "fleet_budget_usd": <number, total ceiling across all tasks>,
  "tasks": [
    {
      "id": "<unique slug, [a-z0-9-]>",
      "prompt": "<self-contained task prompt: the goal, the files in scope, what NOT
                  to touch, and the relevant acceptance criteria quoted from the spec.
                  The agent running this cannot ask questions — write accordingly.>",
      "verify": "<shell command that exits 0 ONLY when this task is truly done.
                  Prefer real checks: scoped test runs, build steps, grep-able
                  invariants, scripts you instruct the task to create FIRST.>",
      "protected": ["<paths the agent must not modify — always include the spec file
                     and any test/verifier files, so the loop's integrity check can
                     prove the exam wasn't edited>"],
      "budget_usd": <number>,
      "max_iterations": <int>,
      "deps": ["<ids of tasks whose merged output this task needs>"],
      "mode": "fresh",
      "allowed_tools": "Read,Edit,Bash"
    }
  ]
}"""

COMPILER_RULES = """Rules for a good plan:
- 2–8 tasks. Each small enough to finish in a handful of iterations; split anything
  that needs more. Tasks run in isolated git worktrees and are merged when complete,
  so deps must reflect REAL build-on relationships only.
- Every acceptance criterion in the spec must be covered by at least one task's
  verifier. If a criterion is not mechanically checkable, create a dedicated task
  whose first step is to WRITE the check (a test or script), list that check's path
  in 'protected', and have 'verify' run it. Do not hand-wave verification.
- Verifiers must be fast (they run every iteration), deterministic, and informative
  on failure. Scope them to the task (one test file, not the whole suite).
- 'protected' must include the spec file and every file the verify command reads as
  its source of truth.
- Prompts must be self-contained: include the relevant spec excerpts verbatim. The
  worker will NOT be shown the rest of the plan or the spec.
- Budgets: small tasks 2–4 USD, larger 4–8. The fleet budget should be ~1.3x the sum.
If any part of the spec is too ambiguous to compile into a verifiable task, include a
top-level "warnings" list in the JSON explaining what needs the human's clarification
— do not invent requirements."""


def strip_fences(text: str) -> str:
    text = text.strip()
    m = re.search(r"```(?:json)?\s*(.*?)```", text, re.DOTALL)
    if m:
        return m.group(1).strip()
    # fall back to the outermost JSON object
    start, end = text.find("{"), text.rfind("}")
    return text[start:end + 1] if start != -1 and end > start else text


def compile_spec(spec_path: Path, *, claude_bin: str, model: str,
                 fleet_budget: float, out_path: Path) -> dict:
    spec_text = spec_path.read_text()
    base_prompt = (
        "You are a plan compiler for autonomous coding loops. Read the spec below and "
        "the repository you are in, then output ONLY a JSON object (no prose, no "
        "markdown fences) matching this schema:\n\n"
        f"{PLAN_SCHEMA_DOC}\n\n{COMPILER_RULES}\n\n"
        f"Set \"spec\" to \"{spec_path}\" and \"fleet_budget_usd\" to at most "
        f"{fleet_budget}.\n\n--- SPEC ({spec_path}) ---\n{spec_text}"
    )
    cfg = LoopConfig(task="", claude_bin=claude_bin, model=model,
                     allowed_tools="Read,Glob,Grep", max_turns=20)

    feedback = ""
    for attempt in (1, 2):
        print(f"⚙  Compiling spec → plan (attempt {attempt}/2)…")
        res = run_claude(base_prompt + feedback, cfg, resume=None, permission_mode="plan")
        if not res["ok"]:
            feedback = f"\n\nYour previous attempt failed to run: {res['error']}. Try again."
            continue
        try:
            plan = json.loads(strip_fences(res["result"]))
        except json.JSONDecodeError as e:
            feedback = (f"\n\nYour previous output was not valid JSON ({e}). "
                        f"Output ONLY the JSON object.")
            continue
        errs = validate_plan(plan)
        # enforce that the spec itself is protected in every task
        for t in plan.get("tasks", []):
            prot = t.setdefault("protected", [])
            if str(spec_path) not in prot:
                prot.append(str(spec_path))
        if errs:
            feedback = ("\n\nYour previous plan failed validation:\n- "
                        + "\n- ".join(errs) + "\nFix these and output the JSON again.")
            print("   validation failed:\n   - " + "\n   - ".join(errs))
            continue
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(json.dumps(plan, indent=2))
        return plan
    raise SystemExit("✗ Could not compile a valid plan in 2 attempts. The validation "
                     "errors above usually mean the spec is too ambiguous to verify — "
                     "tighten the acceptance criteria and recompile.")


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("spec", help="Path to the spec / goal file (markdown or text).")
    p.add_argument("--out", default="plan/tasks.json")
    p.add_argument("--fleet-budget", type=float, default=20.0)
    p.add_argument("--model", default="", help="Model for the compiler pass.")
    p.add_argument("--claude-bin", default="claude")
    args = p.parse_args()

    plan = compile_spec(Path(args.spec), claude_bin=args.claude_bin, model=args.model,
                        fleet_budget=args.fleet_budget, out_path=Path(args.out))

    print(f"\n✓ Plan written to {args.out}")
    print(f"  fleet budget : ${plan.get('fleet_budget_usd', 0):.2f}")
    for t in plan["tasks"]:
        deps = f"  ⇠ {', '.join(t['deps'])}" if t.get("deps") else ""
        print(f"  • {t['id']:<24} ${t.get('budget_usd', 0):.2f}  verify: {t['verify'][:60]}{deps}")
    for w in plan.get("warnings", []):
        print(f"  ⚠ needs human input: {w}")
    print(f"\nReview the plan (especially the verifiers — they are the contract), then:\n"
          f"  python3 {Path(__file__).parent / 'supervisor.py'} --plan {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
