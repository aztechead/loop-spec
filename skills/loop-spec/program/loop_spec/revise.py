"""The revise entry's phase module (M5): turn a PR's review comments into gaps, then
one lead step (role `reviser`) turns those gaps into a compact SPEC and PLAN.

`step` fetches the adopted PR's review comments (`gaps_from_pr`) once, on its first
call, then issues the reviser; `on_submit` the same way `debug.py` does; `compact` is
the registry hook the core calls on acceptance; `adopted_range` wherever the adopted
range's base/head SHAs are needed. Module state lives under `store.state["revise"]`
(`gaps`, `product`); the PR identity and the delivering run's products (`prior`) come
from `store.state["adoption"]`, which the core's revise entry populates.
"""
import json
from pathlib import Path

from loop_spec import repo as repo_module
from loop_spec.errors import LoopSpecError
from loop_spec.steps import IssueStep, Product
from loop_spec.paths import ensure_results_dir
from loop_spec.roles import compose_prompt, load_role, repo_map, step_request



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

    # The REST default page is 30 comments; --slurp wraps every page's array in one array.
    code, out, err = repo_module.run_gh(repo_path, "api", "--paginate", "--slurp",
                                        f"repos/{{owner}}/{{repo}}/pulls/{number}/comments")
    if code != 0:
        raise LoopSpecError(f"gh api pull comments failed for PR #{number}: {err.strip()}", repair="check gh auth")
    for inline in (comment for page in json.loads(out) for comment in page):
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
    role = load_role("reviser", project_root)
    adoption = store.state["adoption"]
    repo_path = Path(store.state["repos"][adoption["repo"]]["path"])
    base_sha, head_sha = adopted_range(store)
    # LF-27: under the project root (paths.results_dir), not the state home -- a
    # live lead step, under Claude Code's default permission mode, cannot write
    # under ~/.claude/... even with the Write tool allow-listed.
    ensure_results_dir(paths)
    result_path = paths.results_dir / f"revise-{ctx['attempt']['id']}.json"

    diff = repo_module.review_diff(repo_path, f"{base_sha}..{head_sha}")

    gaps = store.state["revise"]["gaps"]
    inputs = {
        # LF-63 for the reviser: each gap's body is its own top-level string input, so
        # it renders as real lines. Nested in `gaps`, JSON put a whole comment (a pasted
        # CI log, say) on one escaped line, over the read budget.
        "gaps": [{k: v for k, v in gap.items() if k != "body"} | {"body": f"see input gap:{gap['id']}"}
                 for gap in gaps],
        **{f"gap:{gap['id']}": gap["body"] for gap in gaps},
        "pr": {"number": adoption["number"], "url": adoption["url"], "headRef": adoption["headRef"],
               "baseBranch": adoption["baseBranch"]},
        "diff": diff,
        # LF-37: the delivering run's SPEC/PLAN products, found by the program in
        # its state home (controller._find_delivering_run_products); null when no
        # prior run matched this PR, so the reviser derives from the PR body/diff.
        "prior": store.state["adoption"].get("prior"),
        "repos": repo_map(store.state["repos"]),
        "probes": ctx.get("probes", {}),
    }
    # 7.4.2: the reviser reads and runs in the code checkout at the PR head.
    code_path = Path((store.state["repos"][adoption["repo"]].get("codeCheckout") or {}).get("path") or repo_path)
    prompt = compose_prompt(role, inputs=inputs, result_path=result_path, cwd=code_path, phase="revise")
    # "revise" is not one of the seven ROUTES phases (it re-enters through SPEC's
    # own approval flow); step.json's own schema does not restrict "phase" to an
    # enum, so this is the run's actual stage, not a postcondition lookup key.
    return step_request("lead", "reviser", "revise", project_root=project_root, ctx=ctx, cwd=code_path, prompt=prompt,
                        result_path=result_path, schema=role.schema)


def step(store, paths, ctx):
    revise_state = store.state.setdefault("revise", {"product": None})
    if revise_state.get("product") is not None:
        return Product(revise_state["product"])
    if "gaps" not in revise_state:
        # Fetched once, into this module's own bucket (D4); an empty list is a PR
        # with no comments, never a reason to fetch again.
        adoption = store.state["adoption"]
        revise_state["gaps"] = gaps_from_pr(Path(store.state["repos"][adoption["repo"]]["path"]), adoption["number"])
        store.save()
    return IssueStep(_reviser_request(store, paths, ctx))


def compact(product: dict) -> tuple[dict, dict]:
    """The registry hook the core calls after accepting a revise product: its SPEC and
    PLAN halves, re-entering through SPEC's approval flow as debug's do."""
    return product["spec"], product["plan"]


def on_submit(store, paths, step, result: dict) -> None:
    store.state.setdefault("revise", {"product": None})["product"] = result
    store.save()
