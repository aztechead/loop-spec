"""The revise entry's phase module (M5): turn a PR's review comments into gaps, then
one lead step (role `reviser`) turns those gaps into a compact SPEC and PLAN.

Use `gaps_from_pr` once at entry (the controller's job, not this module's) to collect
review comments off an adopted PR; `step`/`on_submit` the same way `debug.py` does;
`adopted_range` wherever the adopted range's base/head SHAs are needed. Module state
lives under `store.state["revise"]` (`gaps`, `product`); the PR identity the range and
the reviser's inputs read comes from `store.state["adoption"]`, which the controller's
own `run_entry("revise", pr=...)` populates.
"""
import json
from pathlib import Path

from loop_spec import repo as repo_module
from loop_spec.contract import resolve_role, validate_request
from loop_spec.errors import LoopSpecError
from loop_spec.steps import IssueStep, Product
from loop_spec.paths import ensure_results_dir
from loop_spec.roles import compose_prompt, load_role, repo_map, resolve_model

_DIFF_CAP = 200_000  # ponytail: same flat cap as execute.py's review diff


def gaps_from_pr(repo_path: Path, number: int) -> list[dict]:
    code, out, err = repo_module.run_gh(repo_path, "pr", "view", str(number), "--json", "comments,reviews")
    if code != 0:
        raise LoopSpecError(f"gh pr view failed for PR #{number}: {err.strip()}",
                             repair="check gh auth and that the PR number exists")
    data = json.loads(out)

    gaps = []
    for comment in data.get("comments", []) + data.get("reviews", []):
        body = (comment.get("body") or "").strip()
        if not body:
            continue
        gaps.append({"id": f"G-{len(gaps) + 1}", "author": (comment.get("author") or {}).get("login", "unknown"),
                     "body": body, "path": None, "line": None, "url": comment.get("url"),
                     "createdAt": comment.get("createdAt") or comment.get("submittedAt")})

    code, out, err = repo_module.run_gh(repo_path, "api", f"repos/{{owner}}/{{repo}}/pulls/{number}/comments")
    if code != 0:
        raise LoopSpecError(f"gh api pull comments failed for PR #{number}: {err.strip()}", repair="check gh auth")
    for inline in json.loads(out):
        body = (inline.get("body") or "").strip()
        if not body:
            continue
        gaps.append({"id": f"G-{len(gaps) + 1}", "author": (inline.get("user") or {}).get("login", "unknown"),
                     "body": body, "path": inline.get("path"), "line": inline.get("line"), "url": inline.get("html_url"),
                     "createdAt": inline.get("created_at")})
    return gaps


def adopted_range(store) -> tuple[str, str]:
    adoption = store.state["adoption"]
    return adoption["baseSha"], adoption["headSha"]


def _reviser_request(store, paths, ctx) -> dict:
    project_root = Path(ctx["paths"]["projectRoot"])
    role = load_role("reviser", project_root, resolve_role(project_root, "reviser"))
    adoption = store.state["adoption"]
    repo_path = Path(store.state["repos"][adoption["repo"]]["path"])
    base_sha, head_sha = adopted_range(store)
    # LF-27: under the project root (paths.results_dir), not the state home -- a
    # live lead step, under Claude Code's default permission mode, cannot write
    # under ~/.claude/... even with the Write tool allow-listed.
    ensure_results_dir(paths)
    result_path = paths.results_dir / f"revise-{ctx['attempt']['id']}.json"

    diff = repo_module.review_diff(repo_path, f"{base_sha}..{head_sha}")
    if len(diff) > _DIFF_CAP:
        diff = diff[:_DIFF_CAP] + "\n...(truncated)"

    inputs = {
        "gaps": store.state["revise"]["gaps"],
        "pr": {"number": adoption["number"], "url": adoption["url"], "headRef": adoption["headRef"],
               "baseBranch": adoption["baseBranch"]},
        "diff": diff,
        # LF-37: the delivering run's SPEC/PLAN products, found by the program in
        # its state home (controller._find_delivering_run_products); null when no
        # prior run matched this PR, so the reviser derives from the PR body/diff.
        "prior": store.state["revise"].get("prior"),
        "repos": repo_map(store.state["repos"]),
        "probes": ctx.get("probes", {}),
    }
    prompt = compose_prompt(role, inputs=inputs, result_path=result_path, cwd=repo_path, phase="revise")
    request = {
        # "revise" is not one of the seven ROUTES phases (it re-enters through SPEC's
        # own approval flow); step.json's own schema does not restrict "phase" to an
        # enum, so this is the run's actual stage, not a postcondition lookup key.
        "kind": "lead", "role": "reviser", "phase": "revise", "cwd": str(repo_path), "prompt": prompt,
        "resultPath": str(result_path), "schema": role.schema, "postconditions": [],
        "attempt": ctx["attempt"]["id"], "inputsDigest": ctx["inputs"]["digest"], "retryOf": None, "reason": None,
        "model": resolve_model(project_root, "reviser"),
    }
    errors = validate_request("step", request)
    if errors:
        raise LoopSpecError("revise built an invalid lead step request: " + "; ".join(errors),
                             repair="fix _reviser_request in revise.py")
    return request


def step(store, paths, ctx):
    revise_state = store.state.setdefault("revise", {"gaps": [], "product": None})
    if revise_state.get("product") is not None:
        return Product(revise_state["product"])
    return IssueStep(_reviser_request(store, paths, ctx))


def on_submit(store, paths, step, result: dict) -> None:
    store.state.setdefault("revise", {"gaps": [], "product": None})["product"] = result
    store.save()
